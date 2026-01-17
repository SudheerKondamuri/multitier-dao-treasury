// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GovernorSettings} from "./GovernorSettings.sol";
import {GovernorCounting} from "./GovernorCounting.sol";
import {GovernorDelegation} from "./GovernorDelegation.sol";
import {IGovernor} from "../interfaces/IGovernor.sol";
import {ITimelock} from "../interfaces/ITimelock.sol";
import {IFundPolicy} from "../interfaces/IFundPolicy.sol";
import {IVotes} from "../interfaces/IVotes.sol";
import {GovernanceToken} from "../token/GovernanceToken.sol";

/**
 * @title CryptoVenturesGovernor
 * @dev The core governance contract that integrates multi-tier fund policies
 * and square-root weighted (anti-whale) voting math.
 */
contract CryptoVenturesGovernor is
    IGovernor,
    GovernorSettings,
    GovernorCounting,
    GovernorDelegation
{
    struct ProposalCore {
        uint256 voteStart;
        uint256 voteEnd;
        uint256 amount;
        bool executed;
        bool canceled;
        bool queued;
    }

    // Main proposal state mapping
    mapping(uint256 => ProposalCore) private _proposals;

    // Storage for parameters needed for Timelock execution
    mapping(uint256 => address[]) private _proposalTargets;
    mapping(uint256 => uint256[]) private _proposalValues;
    mapping(uint256 => bytes[]) private _proposalCalldatas;
    mapping(uint256 => bytes32) private _proposalSalts;

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
        uint256 totalGovernanceValue = 0;

        for (uint256 i = 0; i < targets.length; i++) {
            // 1. Add any ETH being sent directly from the Timelock
            totalGovernanceValue += values[i];

            // 2. SECURITY FIX: If the target is the TreasuryVault, extract the withdrawal amount
            // This ensures large treasury transfers require high-tier approval
            if (targets[i] == address(vault)) {
                // Check if the selector is for the 'withdraw' function
                bytes4 withdrawSelector = bytes4(
                    keccak256("withdraw(address,address,uint256)")
                );
                if (bytes4(calldatas[i]) == withdrawSelector) {
                    // The 'amount' is the 3rd parameter (offset 68: 4 for selector + 32 + 32)
                    uint256 amount;
                    bytes memory data = calldatas[i];
                    assembly {
                        amount := mload(add(data, 100))
                    }
                    totalGovernanceValue += amount;
                }
            }
        }

        // Fetch Tier based on the COMBINED value (direct ETH + Vault withdrawals)
        IFundPolicy.Tier memory tier = fundPolicy.getTierForAmount(
            totalGovernanceValue
        );

        proposalId = uint256(
            keccak256(
                abi.encode(
                    targets,
                    values,
                    calldatas,
                    keccak256(bytes(description))
                )
            )
        );

        ProposalCore storage proposal = _proposals[proposalId];
        require(proposal.voteStart == 0, "Governor: proposal already exists");

        // Store data for execution
        _proposalTargets[proposalId] = targets;
        _proposalValues[proposalId] = values;
        _proposalCalldatas[proposalId] = calldatas;
        _proposalSalts[proposalId] = keccak256(bytes(description));

        uint256 start = block.number + votingDelay();
        _proposals[proposalId] = ProposalCore({
            voteStart: start,
            voteEnd: start + tier.votingPeriod,
            amount: totalGovernanceValue, // Stored for quorum/state checks
            executed: false,
            canceled: false,
            queued: false
        });

        return proposalId;
    }

    /**
     * @notice Casts a vote using the anti-whale weighted power logic.
     */
    function castVote(
        uint256 proposalId,
        uint8 support
    ) external override returns (uint256 weight) {
        require(
            state(proposalId) == ProposalState.Active,
            "Governor: voting is closed"
        );
        ProposalCore storage proposal = _proposals[proposalId];

        uint256 rawStake = getRawStake(msg.sender, proposal.voteStart);
        require(
            rawStake > 0,
            "Governor: only token holders with stake can vote"
        );

        _countVote(proposalId, msg.sender, support, rawStake);

        return rawStake;
    }

    /**
     * @notice Returns the current state of a proposal.
     * @dev Integrates internal quorum and success checks.
     */
    function state(
        uint256 proposalId
    ) public view override returns (ProposalState) {
        ProposalCore storage proposal = _proposals[proposalId];
        if (proposal.executed) return ProposalState.Executed;
        if (proposal.canceled) return ProposalState.Canceled;
        if (proposal.queued) return ProposalState.Queued; //
        if (block.number <= proposal.voteStart) return ProposalState.Pending;
        if (block.number <= proposal.voteEnd) return ProposalState.Active;

        IFundPolicy.Tier memory tier = fundPolicy.getTierForAmount(
            proposal.amount
        );

        // FIX: Fetch weighted total supply from the token for accurate quorum
        uint256 totalWeightedSupply = GovernanceToken(address(token))
            .getPastTotalWeightedSupply(proposal.voteStart);

        if (
            _quorumReached(proposalId, totalWeightedSupply, tier.minQuorum) &&
            _voteSucceeded(proposalId)
        ) {
            return ProposalState.Succeeded;
        } else {
            return ProposalState.Defeated;
        }
    }

    /**
     * @notice Sends a successful proposal to the Timelock for the mandatory delay period.
     */
    function queue(uint256 proposalId) external {
        require(
            state(proposalId) == ProposalState.Succeeded,
            "Governor: proposal not successful"
        );
        ProposalCore storage proposal = _proposals[proposalId];
        proposal.queued = true; //

        IFundPolicy.Tier memory tier = fundPolicy.getTierForAmount(
            proposal.amount
        );

        // Use stored parameters to schedule in the Timelock
        timelock.schedule(
            _proposalTargets[proposalId][0],
            _proposalValues[proposalId][0],
            _proposalCalldatas[proposalId][0],
            bytes32(0),
            _proposalSalts[proposalId],
            tier.executionDelay
        );
    }

    /**
     * @notice Final execution triggered via Governor, calling the Timelock after delay expires.
     */
    function execute(uint256 proposalId) external payable override {
        require(
            state(proposalId) == ProposalState.Queued,
            "Governor: proposal not queued"
        );
        ProposalCore storage proposal = _proposals[proposalId];
        proposal.executed = true; //

        timelock.execute{value: msg.value}(
            _proposalTargets[proposalId][0],
            _proposalValues[proposalId][0],
            _proposalCalldatas[proposalId][0],
            bytes32(0),
            _proposalSalts[proposalId]
        );
    }
}
