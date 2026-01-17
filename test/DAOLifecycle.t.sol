// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {CryptoVenturesGovernor} from "../contracts/governance/CryptoVenturesGovernor.sol";
import {GovernanceToken} from "../contracts/token/GovernanceToken.sol";
import {TreasuryTimelock} from "../contracts/treasury/TreasuryTimelock.sol";
import {TreasuryVault} from "../contracts/treasury/TreasuryVault.sol";
import {DAOAccessControl} from "../contracts/access/DAOAccessControl.sol";
import {FundPolicy} from "../contracts/funds/FundPolicy.sol";
import {IGovernor} from "../contracts/interfaces/IGovernor.sol";

contract DAOLifecycleTest is Test {
    CryptoVenturesGovernor governor;
    GovernanceToken token;
    TreasuryTimelock timelock;
    TreasuryVault vault;
    DAOAccessControl access;
    FundPolicy policy;

    address payable public admin = payable(makeAddr("admin"));
    address payable public proposer = payable(makeAddr("proposer"));
    address payable public voter1 = payable(makeAddr("voter1"));
    address payable public recipient = payable(makeAddr("recipient"));

    function setUp() public {
        vm.startPrank(admin);
        
        access = new DAOAccessControl(admin);
        token = new GovernanceToken();
        
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        timelock = new TreasuryTimelock(1 hours, proposers, executors, admin);
        
        vault = new TreasuryVault(address(access));
        policy = new FundPolicy(address(access));
        
        governor = new CryptoVenturesGovernor(
            address(access),
            address(token),
            payable(address(timelock)),
            address(policy)
        );

        // Setup Roles
        access.grantRole(access.EXECUTOR_ROLE(), address(timelock));
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0)); // Anyone can execute passed proposals
        
        // Fund the Vault
        vm.deal(address(vault), 1000 ether);
        
        // Distribute tokens and delegate to enable voting power
        token.transfer(voter1, 10000 * 10**18);
        vm.stopPrank();

        vm.prank(voter1);
        token.delegate(voter1); // Required for ERC20Votes to snapshot power
    }

    /**
     * @notice Tests Requirement: Proposals must go through a complete lifecycle.
     * Covers: Draft -> Active -> Succeeded -> Queued -> Executed
     */

    function testCompleteProposalLifecycle() public {
        address[] memory targets = new address[](1);
        targets[0] = address(vault);
        
        uint256[] memory values = new uint256[](1);
        values[0] = 5 ether; // Tier 0: Small Grant (Max 10 ETH)
        
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(vault.withdraw.selector, address(0), recipient, 5 ether);
        
        string memory description = "Small grant for community tools";

        // 1. Propose: The state starts as Pending
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending));

        // 2. Voting Delay: Move blocks forward to make the proposal Active
        vm.roll(block.number + governor.votingDelay() + 1);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Active));

        // 3. Cast Vote: voter1 casts a "For" vote (support = 1)
        // Note: voter1 must have delegated to themselves in setUp to have voting power
        vm.prank(voter1);
        governor.castVote(proposalId, 1);

        // 4. Voting Period: Advance blocks past the Tier 0 voting period (21,600 blocks)
        vm.roll(block.number + 21600 + 1);
        
        // Ensure the state reached Succeeded (assuming quorum was met)
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Succeeded));

        // 5. Queue: Schedule the proposal in the Timelock
        bytes32 salt = keccak256(bytes(description));
        governor.queue(proposalId, targets[0], values[0], calldatas[0], salt);
        
        // 6. Execution Delay (Timelock): Move time forward to satisfy the tiered delay.
        // For Tier 0, the delay is 3600 seconds (1 hour).
        vm.warp(block.timestamp + 3600 + 1);
        
        // 7. Execute: Trigger the withdrawal from the vault via the Timelock
        uint256 initialRecipientBalance = recipient.balance;
        uint256 initialVaultBalance = vault.getBalance(address(0));
        
        // The timelock calls the vault.withdraw function directly
        timelock.execute(targets[0], values[0], calldatas[0], bytes32(0), salt);
        
        // 8. Final Assertions: Verify funds were transferred correctly
        assertEq(recipient.balance, initialRecipientBalance + 5 ether);
        assertEq(vault.getBalance(address(0)), initialVaultBalance - 5 ether);
    }

    /**
     * @notice Tests Requirement: Multi-tier thresholds based on amount
     */
    function testTieredVotingPeriods() public {
        // Tier 0: 5 ETH (21600 blocks)
        uint256 pId0 = governor.propose(_getSingleTarget(), _getSingleValue(5 ether), _getSingleData(), "T0");
        
        // Tier 1: 50 ETH (50400 blocks)
        uint256 pId1 = governor.propose(_getSingleTarget(), _getSingleValue(50 ether), _getSingleData(), "T1");

        vm.roll(block.number + governor.votingDelay() + 1);
        
        // After 30,000 blocks: T0 should be finished, T1 still active
        vm.roll(block.number + 30000);
        
        // T0 should be Defeated (if no votes) or Succeeded (if votes cast), but not Active
        assertTrue(governor.state(pId0) != IGovernor.ProposalState.Active);
        assertEq(uint256(governor.state(pId1)), uint256(IGovernor.ProposalState.Active));
    }

    // Helper functions for clean tests
    function _getSingleTarget() internal view returns (address[] memory) {
        address[] memory t = new address[](1);
        t[0] = address(vault);
        return t;
    }
    function _getSingleValue(uint256 amt) internal pure returns (uint256[] memory) {
        uint256[] memory v = new uint256[](1);
        v[0] = amt;
        return v;
    }
    function _getSingleData() internal view returns (bytes[] memory) {
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeWithSelector(vault.withdraw.selector, address(0), recipient, 1 ether);
        return c;
    }
}