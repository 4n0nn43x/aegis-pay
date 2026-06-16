// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Aegis Pay — Atlantic testnet deployment.
// Deploys the 3 contracts in order and prints their addresses.
//
// Run (after exporting your testnet key, funded with PHRS gas):
//   export PATH="$HOME/.foundry/bin:$PATH"
//   forge script script/Deploy.s.sol:Deploy \
//     --rpc-url https://atlantic.dplabs-internal.com \
//     --private-key $PRIVATE_KEY --broadcast
//
// The deployer becomes OWNER of both contracts and (for this single-key demo)
// also the SPENDER of the vault. For the secure split, deploy with a separate
// agent address as spender, or call setSpender(agent) afterwards.

import {MockReputationRegistry} from "../src/trust-gated-pay/MockReputationRegistry.sol";
import {PaymentGate} from "../src/trust-gated-pay/PaymentGate.sol";
import {BudgetVault} from "../src/budget-vault/BudgetVault.sol";

interface IVm {
    function envUint(string calldata) external view returns (uint256);
    function addr(uint256) external view returns (address);
    function startBroadcast(uint256) external;
    function stopBroadcast() external;
}

contract Deploy {
    IVm constant vm = IVm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // Atlantic test USDC (referenced by the Pharos x402 docs; 6 decimals).
    address constant USDC = 0xE0BE08c77f415F577A1B3A9aD7a1Df1479564ec8;

    // Policy params (tune as you like).
    int128  constant MIN_SCORE      = 7e18; // 7.0 on a 0–10 scale
    uint64  constant MIN_FEEDBACK   = 3;
    uint256 constant PER_PAYMENT    = 5_000000;   // 5 USDC
    uint256 constant WINDOW_CAP     = 50_000000;  // 50 USDC
    uint256 constant WINDOW_SECONDS = 3600;       // 1 hour

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        vm.startBroadcast(pk);

        MockReputationRegistry reg = new MockReputationRegistry();
        PaymentGate gate = new PaymentGate(address(reg), MIN_SCORE, MIN_FEEDBACK);
        // single-key demo: deployer is also the spender. Pass an agent addr here for the split.
        BudgetVault vault =
            new BudgetVault(me, USDC, PER_PAYMENT, WINDOW_CAP, WINDOW_SECONDS);

        vm.stopBroadcast();

        // Addresses are also in the broadcast/ JSON; printed here for convenience.
        _log("MockReputationRegistry", address(reg));
        _log("PaymentGate (Aegis Gate)", address(gate));
        _log("BudgetVault (Aegis Vault)", address(vault));
    }

    event Deployed(string name, address addr);
    function _log(string memory n, address a) internal { emit Deployed(n, a); }
}
