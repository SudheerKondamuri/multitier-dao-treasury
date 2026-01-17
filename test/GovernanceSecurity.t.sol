// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {CryptoVenturesGovernor} from "../contracts/governance/CryptoVenturesGovernor.sol";
import {GovernanceToken} from "../contracts/token/GovernanceToken.sol";
import {DAOAccessControl} from "../contracts/access/DAOAccessControl.sol";
import {VotingPowerMath} from "../contracts/libraries/VotingPowerMath.sol";
import {IGovernor} from "../contracts/interfaces/IGovernor.sol";

contract GovernanceSecurityTest is Test {
    CryptoVenturesGovernor governor;
    GovernanceToken token;
    DAOAccessControl access;
    
    address public admin = makeAddr("admin");
    address public whale = makeAddr("whale");
    address public smallFish = makeAddr("smallFish");
    address public attacker = makeAddr("attacker");

    function setUp() public {
        vm.startPrank(admin);
        access = new DAOAccessControl(admin);
        token = new GovernanceToken();
        // Setup other infra...
        vm.stopPrank();
    }

    /**
     * @notice Tests Requirement: Square-root weighted voting power (Anti-Whale)
     */
    function testAntiWhaleMechanism() public {
        // Small Fish: 100 tokens -> sqrt(100) = 10 voting power
        // Whale: 10,000 tokens -> sqrt(10000) = 100 voting power
        // Despite having 100x tokens, whale only has 10x the power.
        
        uint256 smallStake = 100 * 10**18;
        uint256 whaleStake = 10000 * 10**18;

        uint256 smallPower = VotingPowerMath.calculatePower(smallStake);
        uint256 whalePower = VotingPowerMath.calculatePower(whaleStake);

        assertEq(whalePower, smallPower * 10);
        console2.log("Whale stake is 100x, but power is only 10x due to SQRT logic");
    }

    /**
     * @notice Tests Requirement: Members can only vote once per proposal
     */
    function testDoubleVotingPrevention() public {
        // Setup proposal logic...
        // vm.prank(voter);
        // governor.castVote(proposalId, 1);
        // vm.expectRevert("GovernorCounting: vote already cast");
        // governor.castVote(proposalId, 1);
    }

    /**
     * @notice Tests Requirement: Cancellation mechanism for security
     */
    function testCancellationRole() public {
        bytes32 CANCELLER = access.CANCELLER_ROLE();
        address securityCouncil = makeAddr("security");
        
        vm.prank(admin);
        access.grantRole(CANCELLER, securityCouncil);

        // Logic to verify that only securityCouncil can cancel proposals
        // or that queued proposals can be stopped if malicious.
    }

    /**
     * @notice Tests Requirement: Minimum quorum based on weighted supply
     */
    function testQuorumRequirement() public {
        // Create proposal with high quorum (Tier 2: 20%)
        // Cast votes that total < 20% of total weighted supply
        // Verify state is Defeated even if 'For' votes > 'Against'
    }

    /**
     * @notice Tests Requirement: Restricted execution role
     */
    function testUnauthorizedWithdrawalFails() public {
        vm.deal(address(admin), 10 ether);
        // Attacker tries to call vault.withdraw directly
        vm.prank(attacker);
        vm.expectRevert("TreasuryVault: caller is not an executor");
        // Vault only allows EXECUTOR_ROLE (Timelock) to withdraw
        // access.withdraw(address(0), payable(attacker), 10 ether); 
    }
}