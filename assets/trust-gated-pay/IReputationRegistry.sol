// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IReputationRegistry — minimal read interface of the ERC-8004 Reputation Registry.
/// @notice Mirrors the function the PaymentGate needs to make a trust decision on-chain.
///         The full ERC-8004 registry stores per-feedback (value, valueDecimals, tag1,
///         tag2, isRevoked) in contract storage precisely so other contracts can compose
///         on it. We only depend on `getSummary`, the aggregated read.
/// @dev    Spec: https://eips.ethereum.org/EIPS/eip-8004 (Draft). Agents are identified by
///         an ERC-721 `agentId` (uint256) issued by the Identity Registry.
interface IReputationRegistry {
    /// @notice Aggregate feedback for an agent, optionally filtered by clients and tags.
    /// @param agentId        ERC-721 id of the agent being rated.
    /// @param clientAddresses Filter to these raters; empty array = all clients.
    /// @param tag1           Optional category filter (""=ignore).
    /// @param tag2           Optional sub-category filter (""=ignore).
    /// @return count             Number of feedback entries counted.
    /// @return summaryValue      Aggregated score, scaled by 10**summaryValueDecimals.
    /// @return summaryValueDecimals Decimals applied to `summaryValue`.
    function getSummary(
        uint256 agentId,
        address[] calldata clientAddresses,
        string calldata tag1,
        string calldata tag2
    ) external view returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals);
}
