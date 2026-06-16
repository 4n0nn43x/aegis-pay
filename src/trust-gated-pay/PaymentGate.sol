// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IReputationRegistry} from "./IReputationRegistry.sol";

/// @title PaymentGate — trust-gated authorization for agent payments.
/// @notice The missing link between ERC-8004 (who is trustworthy?) and x402
///         (pay this provider). Before an AI agent settles an x402 payment, it
///         asks this gate: "is the payee's on-chain reputation above my bar?".
///         The gate reads the ERC-8004 Reputation Registry and either authorizes
///         (emitting an auditable event) or reverts with a human-readable reason.
///
/// @dev    This contract makes a DECISION; it does not move funds. Settlement is
///         performed by the BudgetVault (composable Skill #2) or by the x402
///         facilitator. Keeping money movement out of the gate keeps it a pure,
///         side-effect-light policy contract — easy to audit and to reason about.
contract PaymentGate {
    /// @notice The ERC-8004 Reputation Registry this gate reads from.
    IReputationRegistry public immutable reputation;

    /// @notice Owner may tune the policy (threshold, minimum rater count).
    address public owner;

    /// @notice Minimum aggregated reputation score required to authorize a payment.
    ///         Compared against the registry's `summaryValue` normalized to 18 decimals.
    int128 public minScore;

    /// @notice Minimum number of distinct feedback entries required (anti-cold-start /
    ///         anti-single-rater gaming). A glowing score from one rater is not enough.
    uint64 public minFeedbackCount;

    event PolicyUpdated(int128 minScore, uint64 minFeedbackCount);
    event PaymentAuthorized(
        uint256 indexed payeeAgentId,
        address indexed payer,
        uint256 amount,
        int128 score,
        uint64 feedbackCount
    );
    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error ReputationTooLow(int128 score, int128 required);
    error NotEnoughFeedback(uint64 count, uint64 required);
    error ZeroAmount();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param _reputation       Address of the ERC-8004 Reputation Registry.
    /// @param _minScore         Initial reputation bar, normalized to 18 decimals
    ///                          (e.g. 7e18 == a score of 7.0 on a 0–10 scale).
    /// @param _minFeedbackCount Initial minimum number of feedback entries.
    constructor(address _reputation, int128 _minScore, uint64 _minFeedbackCount) {
        reputation = IReputationRegistry(_reputation);
        owner = msg.sender;
        minScore = _minScore;
        minFeedbackCount = _minFeedbackCount;
        emit PolicyUpdated(_minScore, _minFeedbackCount);
    }

    /// @notice Update the trust policy. Effective immediately for subsequent checks.
    function setPolicy(int128 _minScore, uint64 _minFeedbackCount) external onlyOwner {
        minScore = _minScore;
        minFeedbackCount = _minFeedbackCount;
        emit PolicyUpdated(_minScore, _minFeedbackCount);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Read a payee agent's reputation, normalized to 18 decimals, plus the
    ///         number of feedback entries behind it. Pure view — safe for an agent to
    ///         call (via `cast call`) before deciding to pay.
    /// @param payeeAgentId ERC-8004 agentId of the provider being considered.
    /// @return score        Aggregated reputation normalized to 1e18 fixed point.
    /// @return feedbackCount Number of feedback entries counted.
    function reputationOf(uint256 payeeAgentId)
        public
        view
        returns (int128 score, uint64 feedbackCount)
    {
        address[] memory allClients = new address[](0); // empty = aggregate over all raters
        (uint64 count, int128 summaryValue, uint8 dec) =
            reputation.getSummary(payeeAgentId, allClients, "", "");
        return (_normalize(summaryValue, dec), count);
    }

    /// @notice Non-reverting check, for an agent that wants to branch on the result
    ///         instead of catching a revert.
    /// @return ok   True if the payee passes the current policy.
    /// @return score        The normalized reputation that was evaluated.
    /// @return feedbackCount The feedback count that was evaluated.
    function isAuthorized(uint256 payeeAgentId)
        public
        view
        returns (bool ok, int128 score, uint64 feedbackCount)
    {
        (score, feedbackCount) = reputationOf(payeeAgentId);
        ok = (feedbackCount >= minFeedbackCount) && (score >= minScore);
    }

    /// @notice Enforcing check: reverts with a precise reason if the payee fails policy.
    ///         An agent calls this right before kicking off the x402 settle (or before
    ///         calling BudgetVault.spend). The emitted event is the on-chain proof that
    ///         "this payment was reputation-checked" — useful for audit and liability.
    /// @param payeeAgentId ERC-8004 agentId of the provider being paid.
    /// @param amount       Payment amount (token base units) — recorded for the audit trail.
    function authorizePayment(uint256 payeeAgentId, uint256 amount)
        external
        returns (int128 score, uint64 feedbackCount)
    {
        if (amount == 0) revert ZeroAmount();
        (score, feedbackCount) = reputationOf(payeeAgentId);
        if (feedbackCount < minFeedbackCount) {
            revert NotEnoughFeedback(feedbackCount, minFeedbackCount);
        }
        if (score < minScore) {
            revert ReputationTooLow(score, minScore);
        }
        emit PaymentAuthorized(payeeAgentId, msg.sender, amount, score, feedbackCount);
    }

    /// @dev Normalize an ERC-8004 (value, decimals) pair to 1e18 fixed point so the
    ///      policy threshold is expressed in one consistent unit regardless of how a
    ///      given registry scales its scores. Computed in int256 to avoid intermediate
    ///      overflow, then range-checked before narrowing back to int128.
    function _normalize(int128 value, uint8 decimals) internal pure returns (int128) {
        if (decimals == 18) return value;

        int256 scaled;
        if (decimals < 18) {
            int256 factor = int256(10) ** (uint256(18) - decimals);
            scaled = int256(value) * factor;
        } else {
            int256 factor = int256(10) ** (uint256(decimals) - 18);
            scaled = int256(value) / factor;
        }

        require(scaled >= type(int128).min && scaled <= type(int128).max, "score overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        return int128(scaled); // safe: range-checked on the line above

    }
}
