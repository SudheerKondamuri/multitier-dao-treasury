// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {GovernanceToken} from "../contracts/token/GovernanceToken.sol";
import {TreasuryTimelock} from "../contracts/treasury/TreasuryTimelock.sol";
import {TreasuryVault} from "../contracts/treasury/TreasuryVault.sol";
import {DAOAccessControl} from "../contracts/access/DAOAccessControl.sol";
import {FundPolicy} from "../contracts/funds/FundPolicy.sol";
import {CryptoVenturesGovernor} from "../contracts/governance/CryptoVenturesGovernor.sol";

contract DeployDAO is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Core Infrastructure
        DAOAccessControl access = new DAOAccessControl(deployer);
        GovernanceToken token = new GovernanceToken();
        
        // 2. Deploy Timelock (Initially with deployer as admin for setup)
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        TreasuryTimelock timelock = new TreasuryTimelock(
            3600, // 1 hour min delay
            proposers,
            executors,
            deployer
        );

        // 3. Deploy Vault and Fund Policy
        TreasuryVault vault = new TreasuryVault(address(access));
        FundPolicy policy = new FundPolicy(address(access));

        // 4. Deploy the Main Governor
        CryptoVenturesGovernor governor = new CryptoVenturesGovernor(
            address(access),
            address(token),
            payable(address(timelock)),
            address(policy)
        );

        // 5. GRANT ROLES (The "Linking" Phase)
        access.grantRole(access.PROPOSER_ROLE(), address(governor));
        access.grantRole(access.EXECUTOR_ROLE(), address(timelock));
        
        // Grant Timelock permission to propose and execute on itself
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0)); // address(0) means anyone can execute passed proposals

        // 6. DECENTRALIZATION (Transfer Admin to Timelock)
        access.grantRole(0x00, address(timelock)); // DEFAULT_ADMIN_ROLE
        access.revokeRole(0x00, deployer);
        timelock.revokeRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopBroadcast();
    }
}