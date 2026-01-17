// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFundPolicy} from "../interfaces/IFundPolicy.sol";
import {DAOAccessControl} from "../access/DAOAccessControl.sol";

/**
 * @title FundPolicy
 * @dev Implements multi-tier governance rules based on proposal value.
 */
contract FundPolicy is IFundPolicy {
    DAOAccessControl public immutable accessControl;
    
    // Ordered list of tiers from smallest to largest amount
    Tier[] private _tiers;

    event TierUpdated(uint256 indexed index, uint256 minQuorum, uint256 votingPeriod, uint256 maxAmount,uint256 executionDelay);
    event TierAdded(uint256 minQuorum, uint256 votingPeriod, uint256 maxAmount,uint256 executionDelay);

    /**
     * @param _accessControl The address of the DAOAccessControl contract.
     */
    constructor(address _accessControl) {
        accessControl = DAOAccessControl(_accessControl);
        
        // Initializing with default tiers as per typical DAO standards:
        // Tier 0: Small Grants (up to 10 ETH) - 4% quorum, 3 days voting
        _addTier(400, 21600, 10 ether,3600); 
        
        // Tier 1: Mid-Sized (up to 100 ETH) - 10% quorum, 7 days voting
        _addTier(1000, 50400, 100 ether,86400);
        
        // Tier 2: Large Investment (Unlimited) - 20% quorum, 14 days voting
        _addTier(2000, 100800, type(uint256).max,259200);
    }

    /**
     * @inheritdoc IFundPolicy
     */
    function getTierForAmount(uint256 amount) external view override returns (Tier memory) {
        for (uint256 i = 0; i < _tiers.length; i++) {
            if (amount <= _tiers[i].maxAmount) {
                return _tiers[i];
            }
        }
        return _tiers[_tiers.length - 1]; // Fallback to the highest tier
    }

    /**
     * @notice Allows the DAO to add a new tier.
     * @dev Restricted to the DEFAULT_ADMIN_ROLE (the DAO itself).
     */
    function addTier(uint256 minQuorum, uint256 votingPeriod, uint256 maxAmount,uint256 executionDelay) external {
        require(accessControl.hasRole(accessControl.DEFAULT_ADMIN_ROLE(), msg.sender), "FundPolicy: Restricted to Admin");
        _addTier(minQuorum, votingPeriod, maxAmount,executionDelay);
    }

    function _addTier(uint256 minQuorum, uint256 votingPeriod, uint256 maxAmount,uint256 executionDelay) internal {
        _tiers.push(Tier(minQuorum, votingPeriod, maxAmount,executionDelay));
        emit TierAdded(minQuorum, votingPeriod, maxAmount,executionDelay);
    }

    function getTotalTiers() external view returns (uint256) {
        return _tiers.length;
    }
}