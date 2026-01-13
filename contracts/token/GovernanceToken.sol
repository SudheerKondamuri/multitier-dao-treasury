// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nones} from "@openzeppelin/contracts/utils/Nones.sol";
import {VotingPowerMath} from "../libraries/VotingPowerMath.sol";

/**
 * @title GovernanceToken
 * @dev Implements ERC20 with snapshots (votes) and square-root weighted voting power.
 */
contract GovernanceToken is ERC20, ERC20Permit, ERC20Votes {
    
    constructor() 
        ERC20("CryptoVentures Token", "CVT") 
        ERC20Permit("CryptoVentures Token") 
    {
        // Initial supply for testing; in production, this might be controlled by a DAO or crowdsale
        _mint(msg.sender, 1000000 * 10 ** decimals());
    }

    /**
     * @notice Returns the weighted voting power for an account at a specific block.
     * @dev Uses the Babylonian square root method from VotingPowerMath to prevent whale dominance.
     * @param account The address to check power for.
     * @param timepoint The block number or timestamp to check (depends on OZ version configuration).
     */
    function getWeightedVotingPower(address account, uint256 timepoint) public view returns (uint256) {
        // Retrieve the raw balance (stake) at the specific block/timepoint
        uint256 rawStake = getPastVotes(account, timepoint);
        
        // Apply the square root logic from the library
        return VotingPowerMath.calculatePower(rawStake);
    }


    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nones)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}