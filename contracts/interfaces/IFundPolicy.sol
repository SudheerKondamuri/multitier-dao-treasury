// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IFundPolicy
 * @dev Interface for defining multi-tier treasury spending rules.
 */
interface IFundPolicy {
    struct Tier {
        uint256 minQuorum;     // Minimum weighted votes required (in basis points, e.g., 400 = 4%)
        uint256 votingPeriod;  // How long the vote lasts (in blocks)
        uint256 maxAmount;     // Maximum fund amount for this specific tier
    }

    /**
     * @notice Returns the policy details for a specific amount of funds requested.
     * @param amount The amount of the investment/spend proposal.
     */
    function getTierForAmount(uint256 amount) external view returns (Tier memory);
}