// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Proves the owner==agent fix: a compromised SPENDER (agent) is bounded by the
// guardrails and CANNOT drain the vault; only the OWNER can withdraw. No forge-std.
// Run: forge script test/RoleSeparationPoC.sol:RoleSeparationPoC --sig "run()" -vvvv

import {BudgetVault} from "../src/budget-vault/BudgetVault.sol";

contract TestToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "insufficient");
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
}

/// Stands in for the agent EOA (the spender). A "compromised" agent is just this
/// contract calling whatever it can reach on the vault.
contract Agent {
    function trySpend(BudgetVault v, address to, uint256 a) external returns (bool ok) {
        try v.spend(to, a) { ok = true; } catch { ok = false; }
    }
    function tryWithdraw(BudgetVault v, address to, uint256 a) external returns (bool ok) {
        try v.withdraw(to, a) { ok = true; } catch { ok = false; }
    }
    function tryPause(BudgetVault v) external returns (bool ok) {
        try v.setPaused(true) { ok = true; } catch { ok = false; }
    }
}

contract RoleSeparationPoC {
    event Result(string verdict);
    event Log(string what, uint256 value);

    TestToken token;
    BudgetVault vault;
    Agent agent;
    address attacker = address(0xBAD);

    function run() external {
        // This contract is the OWNER (deployer). `agent` is the SPENDER.
        token = new TestToken();
        agent = new Agent();
        // BudgetVault(spender, token, perPaymentCap=10, windowCap=50, windowSeconds=120)
        vault = new BudgetVault(address(agent), address(token), 10, 50, 120);
        token.mint(address(vault), 1000);
        emit Log("vault funded", token.balanceOf(address(vault)));

        // 1. Compromised agent tries to DRAIN via withdraw → must fail (NotOwner).
        bool drained = agent.tryWithdraw(vault, attacker, 1000);
        emit Result(drained ? "AGENT DRAINED VAULT (BUG)" : "agent withdraw REJECTED (NotOwner) - drain blocked");
        require(!drained, "REGRESSION: agent could withdraw");

        // 2. Compromised agent tries to disable the kill-switch → must fail (NotOwner).
        bool paused = agent.tryPause(vault);
        emit Result(paused ? "AGENT PAUSED VAULT (BUG)" : "agent setPaused REJECTED (NotOwner)");
        require(!paused, "REGRESSION: agent could pause");

        // 3. Agent CAN spend, but only within the per-payment cap (10).
        bool overCap = agent.trySpend(vault, attacker, 50); // > perPaymentCap
        emit Result(overCap ? "agent spent over cap (BUG)" : "agent over-cap spend REJECTED (bounded)");
        require(!overCap, "REGRESSION: agent spent over per-payment cap");

        bool okSpend = agent.trySpend(vault, attacker, 10); // within cap
        emit Result(okSpend ? "agent legit spend OK (bounded to guardrails)" : "legit spend wrongly blocked");
        require(okSpend, "legit in-cap spend should succeed");

        // 4. The OWNER (this contract, the deployer) CAN withdraw → escape hatch works.
        address recipient = address(0xC0FFEE);
        vault.withdraw(recipient, 100);
        emit Log("owner withdrew to recipient", token.balanceOf(recipient));
        require(token.balanceOf(recipient) == 100, "owner withdraw should succeed");

        emit Result("ROLE SEPARATION HOLDS - compromised agent cannot drain");
    }
}
