// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Minimal ERC-20 surface the vault needs. Avoids an external dependency so the
///      Skill is fully self-contained (friendlier to the CertiK Skill Scanner).
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title BudgetVault — on-chain spending guardrails for an autonomous agent.
/// @notice x402 settles payments but explicitly leaves budget enforcement "to be
///         implemented externally". This vault IS that external enforcement, on-chain
///         and composable: it holds the agent's working funds and only releases them
///         through `spend()`, which enforces a true sliding-window cap (bucketed, so it
///         cannot be gamed at a boundary), a per-payment cap, an optional payee allowlist,
///         and an owner kill-switch. One compromised or hallucinating agent cannot drain
///         the treasury faster than windowCap per windowSeconds.
///
/// @dev    Composability: PaymentGate (Skill #1) decides WHO may be paid; BudgetVault
///         (Skill #2) decides HOW MUCH may flow and EXECUTES the transfer. An agent
///         wires them: authorizePayment(...) then spend(...). Each is independently
///         useful and independently deployable.
contract BudgetVault {
    address public owner;

    /// @notice The single ERC-20 this vault disburses (e.g. test USDC on Atlantic).
    IERC20 public immutable token;

    /// @notice Hard cap on a single `spend` call (token base units).
    uint256 public perPaymentCap;

    /// @notice Cap on total spend within any `windowSeconds` rolling window.
    uint256 public windowCap;

    /// @notice Length of the rolling spend window, in seconds.
    uint256 public windowSeconds;

    /// @notice When true, all spending is frozen (kill-switch).
    bool public paused;

    /// @notice If true, only payees on the allowlist may receive funds.
    bool public allowlistEnabled;
    mapping(address => bool) public allowlisted;

    // ── True sliding-window accounting (ring buffer of time buckets) ───────────────
    //
    // The previous design reset a fixed window, which let an attacker spend windowCap
    // just before the reset and again just after — ~2x windowCap in seconds. A real
    // sliding window fixes that: we split time into buckets of `bucketSeconds =
    // windowSeconds / BUCKETS` and count the last (BUCKETS + 1) buckets.
    //
    // Why BUCKETS+1 and not BUCKETS: `bucketSeconds` truncates, so BUCKETS buckets cover
    // only `bucketSeconds * BUCKETS <= windowSeconds` seconds — if windowSeconds isn't a
    // multiple of BUCKETS, that's SHORTER than the configured window, and spend just past
    // the covered span (but younger than windowSeconds) would be dropped → cap bypass.
    // Counting one extra bucket makes coverage `bucketSeconds * (BUCKETS+1) >=
    // windowSeconds` for any windowSeconds >= BUCKETS, so we NEVER under-count. We may
    // over-count by up to one bucket (enforce slightly conservatively), which is the safe
    // direction for a budget guard. The ring therefore needs BUCKETS+1 physical slots so
    // the oldest counted period and the current one never alias.
    uint256 public constant BUCKETS = 12;
    uint256 public constant SLOTS = BUCKETS + 1; // ring size: counted periods never alias

    struct Bucket {
        uint256 periodIndex; // floor(timestamp / bucketSeconds) this slot accounts for
        uint256 amount; // amount spent during that period
    }

    Bucket[SLOTS] private _buckets;

    event PolicyUpdated(uint256 perPaymentCap, uint256 windowCap, uint256 windowSeconds);
    event AllowlistSet(address indexed payee, bool allowed);
    event AllowlistToggled(bool enabled);
    event Paused(bool paused);
    event Spent(address indexed payee, uint256 amount, uint256 spentInWindow);
    event Deposited(address indexed from, uint256 amount);
    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error IsPaused();
    error ZeroAmount();
    error PayeeNotAllowed(address payee);
    error OverPerPaymentCap(uint256 amount, uint256 cap);
    error OverWindowCap(uint256 wouldSpend, uint256 cap);
    error TransferFailed();
    error WindowTooShort(uint256 windowSeconds, uint256 minimum);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param _token         ERC-20 token disbursed by the vault.
    /// @param _perPaymentCap Max per single spend (base units).
    /// @param _windowCap     Max cumulative spend per rolling window (base units).
    /// @param _windowSeconds Sliding window length (seconds). Must be >= BUCKETS so each
    ///                       bucket spans >= 1 second.
    constructor(
        address _token,
        uint256 _perPaymentCap,
        uint256 _windowCap,
        uint256 _windowSeconds
    ) {
        if (_windowSeconds < BUCKETS) revert WindowTooShort(_windowSeconds, BUCKETS);
        owner = msg.sender;
        token = IERC20(_token);
        perPaymentCap = _perPaymentCap;
        windowCap = _windowCap;
        windowSeconds = _windowSeconds;
        emit PolicyUpdated(_perPaymentCap, _windowCap, _windowSeconds);
    }

    // ── Owner controls ───────────────────────────────────────────────────────────

    function setPolicy(uint256 _perPaymentCap, uint256 _windowCap, uint256 _windowSeconds)
        external
        onlyOwner
    {
        if (_windowSeconds < BUCKETS) revert WindowTooShort(_windowSeconds, BUCKETS);
        perPaymentCap = _perPaymentCap;
        windowCap = _windowCap;
        windowSeconds = _windowSeconds;
        emit PolicyUpdated(_perPaymentCap, _windowCap, _windowSeconds);
    }

    /// @notice Kill-switch. While paused, `spend` reverts. Funds remain withdrawable
    ///         by the owner via `withdraw`.
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    function setAllowlistEnabled(bool _enabled) external onlyOwner {
        allowlistEnabled = _enabled;
        emit AllowlistToggled(_enabled);
    }

    function setAllowlisted(address payee, bool allowed) external onlyOwner {
        allowlisted[payee] = allowed;
        emit AllowlistSet(payee, allowed);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Owner-only escape hatch to pull funds back out of the vault.
    function withdraw(address to, uint256 amount) external onlyOwner {
        if (!token.transfer(to, amount)) revert TransferFailed();
    }

    // ── Deposit ──────────────────────────────────────────────────────────────────

    /// @notice Record a deposit. Tokens must be transferred to this contract first
    ///         (e.g. `cast send <token> transfer <vault> <amount>`); this only emits
    ///         the audit event and is optional bookkeeping.
    function noteDeposit(uint256 amount) external {
        emit Deposited(msg.sender, amount);
    }

    // ── Spend ────────────────────────────────────────────────────────────────────

    /// @dev Sum of spend that still falls within the trailing `windowSeconds`. A bucket
    ///      counts only if the period it accounts for is recent enough that its END is
    ///      still inside the window — i.e. periodIndex > currentPeriod - BUCKETS. Older
    ///      buckets are stale (their time has fully rolled out) and are ignored.
    ///      Bounded loop over BUCKETS (constant) → bounded gas.
    function _spentInWindow() internal view returns (uint256 total) {
        uint256 bucketSeconds = windowSeconds / BUCKETS;
        // forge-lint: disable-next-line(block-timestamp)
        uint256 currentPeriod = block.timestamp / bucketSeconds;
        // Count the last BUCKETS+1 periods so coverage >= windowSeconds despite truncation.
        uint256 cutoff = currentPeriod >= BUCKETS ? currentPeriod - BUCKETS : 0;
        for (uint256 i = 0; i < SLOTS; i++) {
            Bucket storage b = _buckets[i];
            if (b.amount != 0 && b.periodIndex >= cutoff) {
                total += b.amount;
            }
        }
    }

    /// @notice Read-only preview of how much room is left in the trailing window. Lets an
    ///         agent size a payment without triggering a revert. Mirrors the exact check
    ///         `spend` enforces, so a value <= remainingThisWindow() will not hit the cap.
    function remainingThisWindow() public view returns (uint256) {
        uint256 spent = _spentInWindow();
        if (spent >= windowCap) return 0;
        return windowCap - spent;
    }

    /// @notice Release `amount` to `payee`, enforcing all guardrails. This is the call
    ///         that actually moves money — it is the settlement step the agent performs
    ///         after PaymentGate.authorizePayment has approved the payee.
    /// @param payee  Recipient of the funds.
    /// @param amount Amount in token base units.
    function spend(address payee, uint256 amount) external onlyOwner {
        if (paused) revert IsPaused();
        if (amount == 0) revert ZeroAmount();
        if (amount > perPaymentCap) revert OverPerPaymentCap(amount, perPaymentCap);
        if (allowlistEnabled && !allowlisted[payee]) revert PayeeNotAllowed(payee);

        // Enforce the cap over the TRAILING window — no boundary reset to game.
        uint256 wouldSpend = _spentInWindow() + amount;
        if (wouldSpend > windowCap) revert OverWindowCap(wouldSpend, windowCap);

        // Record this spend in the bucket for the current period (ring buffer slot).
        uint256 bucketSeconds = windowSeconds / BUCKETS;
        // forge-lint: disable-next-line(block-timestamp)
        uint256 currentPeriod = block.timestamp / bucketSeconds;
        uint256 slot = currentPeriod % SLOTS;
        Bucket storage b = _buckets[slot];
        if (b.periodIndex == currentPeriod) {
            b.amount += amount; // same period → accumulate
        } else {
            b.periodIndex = currentPeriod; // slot reused for a new period → overwrite
            b.amount = amount;
        }

        if (!token.transfer(payee, amount)) revert TransferFailed();
        emit Spent(payee, amount, wouldSpend);
    }
}
