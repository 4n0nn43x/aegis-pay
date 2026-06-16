// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IReputationRegistry} from "./IReputationRegistry.sol";

/// @title MockReputationRegistry — ERC-8004-compatible registry for local & testnet demos.
/// @notice The canonical ERC-8004 Reputation Registry may not be deployed on the Pharos
///         Atlantic testnet yet (the EIP is still Draft). This minimal, faithful
///         implementation lets the PaymentGate Skill run end-to-end today. It implements
///         the real `getSummary` read shape and a simplified `giveFeedback` write so a
///         demo can seed reputation, then gate a payment on it.
/// @dev    Simplifications vs. the full spec (documented honestly): feedback is averaged
///         in-contract instead of storing every entry; tags/URIs/off-chain hashes are
///         omitted; no revoke/response flow. The READ surface the gate depends on
///         (`getSummary`) matches the spec signature exactly, so swapping in the real
///         registry later requires no change to PaymentGate.
contract MockReputationRegistry is IReputationRegistry {
    uint8 public constant DECIMALS = 18;

    /// @notice Feedback values are bounded to [0, MAX_SCORE] (0.0–10.0 in 1e18 fixed point).
    ///         A signed, unbounded value let a single rater grief an honest agent into a
    ///         hugely negative average; an unbounded positive value let one rater inflate.
    int128 public constant MAX_SCORE = 10e18;

    /// @notice Owner controls who may submit feedback. Permissionless feedback made the
    ///         minFeedbackCount guard meaningless (free sybil raters), so attestation is
    ///         gated. Real ERC-8004 pushes Sybil-resistance to the registry layer; this
    ///         mock approximates it with an attester allowlist.
    address public owner;
    mapping(address => bool) public isAttester;

    struct Agg {
        uint64 count;
        int256 sum; // sum of normalized (1e18) scores; average = sum / count
    }

    mapping(uint256 => Agg) private _agg;
    // agentId => client => already rated? (one feedback per client, for simplicity)
    mapping(uint256 => mapping(address => bool)) public hasRated;

    event FeedbackGiven(uint256 indexed agentId, address indexed client, int128 value);
    event AttesterSet(address indexed attester, bool allowed);

    error AlreadyRated();
    error NotOwner();
    error NotAttester();
    error ValueOutOfRange(int128 value);

    constructor() {
        owner = msg.sender;
        isAttester[msg.sender] = true; // deployer can seed feedback by default
        emit AttesterSet(msg.sender, true);
    }

    /// @notice Owner adds/removes an authorized attester.
    function setAttester(address attester, bool allowed) external {
        if (msg.sender != owner) revert NotOwner();
        isAttester[attester] = allowed;
        emit AttesterSet(attester, allowed);
    }

    /// @notice Record feedback for an agent. `value` is 1e18 fixed point in [0, MAX_SCORE].
    ///         Only authorized attesters may rate; one feedback per attester per agent.
    function giveFeedback(uint256 agentId, int128 value) external {
        if (!isAttester[msg.sender]) revert NotAttester();
        if (value < 0 || value > MAX_SCORE) revert ValueOutOfRange(value);
        if (hasRated[agentId][msg.sender]) revert AlreadyRated();
        hasRated[agentId][msg.sender] = true;
        Agg storage a = _agg[agentId];
        a.count += 1;
        a.sum += int256(value);
        emit FeedbackGiven(agentId, msg.sender, value);
    }

    /// @inheritdoc IReputationRegistry
    /// @dev clientAddresses/tags are accepted for signature compatibility but ignored in
    ///      the mock (it always aggregates over all raters, untagged).
    function getSummary(
        uint256 agentId,
        address[] calldata, /* clientAddresses */
        string calldata, /* tag1 */
        string calldata /* tag2 */
    ) external view override returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals) {
        Agg storage a = _agg[agentId];
        count = a.count;
        summaryValue = count == 0 ? int128(0) : int128(a.sum / int256(uint256(count)));
        summaryValueDecimals = DECIMALS;
    }
}
