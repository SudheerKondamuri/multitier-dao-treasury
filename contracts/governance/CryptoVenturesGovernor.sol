// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GovernorSettings} from "./GovernorSettings.sol";
import {GovernorCounting} from "./GovernorCounting.sol";
import {GovernorDelegation} from "./GovernorDelegation.sol";
import {IGovernor} from "../interfaces/IGovernor.sol";
import {ITimelock} from "../interfaces/ITimelock.sol";
import {IFundPolicy} from "../interfaces/IFundPolicy.sol";
import {IVotes} from "../interfaces/IVotes.sol";

/**
 * @title CryptoVenturesGovernor
 * @dev The core governance contract that integrates multi-tier fund policies 
 * and square-root weighted (anti-whale) voting math.
 */
contract CryptoVenturesGovernor is IGovernor, GovernorSettings, GovernorCounting, GovernorDelegation {
    
    struct ProposalCore {
        uint256 voteStart;
        uint256 voteEnd;
        uint256 amount;
        bool executed;
        bool canceled;
    }

    mapping(uint256 => ProposalCore) private _proposals;
    ITimelock public immutable timelock;

    /**
     * @param _accessControl The DAOAccessControl contract address.
     * @param _token The GovernanceToken (CVT) address.
     * @param _timelock The TreasuryTimelock address.
     * @param _fundPolicy The initial FundPolicy address.
     */
    constructor(
        address _accessControl,
        address _token,
        address payable _timelock,
        address _fundPolicy
    ) 
        GovernorSettings(_accessControl, _fundPolicy, 7200) // Default 1-day delay (7200 blocks)
        GovernorDelegation(IVotes(_token)) 
    {
        timelock = ITimelock(_timelock);
    }

    /**
     * @notice Creates a new investment or management proposal.
     * @dev Dynamically fetches voting period and quorum from FundPolicy based on the requested value.
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) external override returns (uint256 proposalId) {
        uint256 totalValue = 0;
        for (uint256 i = 0; i < values.length; i++) {
            totalValue += values[i];
        }

        // Fetch Tier-based rules (Quorum and Voting Period) from the FundPolicy
        IFundPolicy.Tier memory tier = fundPolicy.getTierForAmount(totalValue);
        
        proposalId = uint256(keccak256(abi.encode(targets, values, calldatas, keccak256(bytes(description)))));
        
        ProposalCore storage proposal = _proposals[proposalId];
        require(proposal.voteStart == 0, "Governor: proposal already exists");

        uint256 start = block.number + votingDelay();
        uint256 end = start + tier.votingPeriod;

        _proposals[proposalId] = ProposalCore({
            voteStart: start,
            voteEnd: end,
            amount: totalValue,
            executed: false,
            canceled: false
        });

        return proposalId;
    }

    /**
     * @notice Casts a vote using the anti-whale weighted power logic.
     */
    function castVote(uint256 proposalId, uint8 support) external override returns (uint256 weight) {
        require(state(proposalId) == ProposalState.Active, "Governor: voting is closed");
        ProposalCore storage proposal = _proposals[proposalId];

        // Retrieve raw token balance at the block the proposal was created (snapshot)
        uint256 rawStake = getRawStake(msg.sender, proposal.voteStart);
        require(rawStake > 0, "Governor: only token holders with stake can vote");

        // Use inherited internal logic to calculate sqrt(stake) and tally the vote
        _countVote(proposalId, msg.sender, support, rawStake);
        
        return rawStake;
    }

    /**
     * @notice Returns the current state of a proposal.
     * @dev Integrates internal quorum and success checks from GovernorCounting.
     */
    function state(uint256 proposalId) public view override returns (ProposalState) {
        ProposalCore storage proposal = _proposals[proposalId];
        if (proposal.canceled) return ProposalState.Canceled;
        if (proposal.executed) return ProposalState.Executed;
        if (block.number <= proposal.voteStart) return ProposalState.Pending;
        if (block.number <= proposal.voteEnd) return ProposalState.Active;

        IFundPolicy.Tier memory tier = fundPolicy.getTierForAmount(proposal.amount);
        
        // Fetch weighted total supply at snapshot for accurate quorum calculation
        // In production, this would use token.getPastTotalWeightedSupply(proposal.voteStart)
        uint256 totalWeightedSupply = 1000000; 

        if (_quorumReached(proposalId, totalWeightedSupply, tier.minQuorum) && _voteSucceeded(proposalId)) {
            return ProposalState.Succeeded;
        } else {
            return ProposalState.Defeated;
        }
    }

    /**
     * @notice Sends a successful proposal to the Timelock for the mandatory delay period.
     */
    function queue(uint256 proposalId, address target, uint256 value, bytes calldata data, bytes32 salt) external {
        require(state(proposalId) == ProposalState.Succeeded, "Governor: proposal not successful");
        ProposalCore storage proposal = _proposals[proposalId];
        IFundPolicy.Tier memory tier = fundPolicy.getTierForAmount(proposal.amount);
        timelock.schedule(target, value, data, bytes32(0), salt, tier.executionDelay); 
    }

    function execute(uint256 proposalId) external payable override {
        // Final execution triggered via Timelock after delay expires
    }
}