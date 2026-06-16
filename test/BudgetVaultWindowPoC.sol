// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Regression PoC for the BudgetVault sliding-window fix. No forge-std dependency —
// time travel uses the VM cheatcode address directly.
// Run: forge script test/BudgetVaultWindowPoC.sol:BudgetVaultWindowPoC --sig "run()" -vvvv
//
// Before the fix: spend(windowCap) just before the boundary, then again just after the
// reset → ~2x windowCap in seconds. After the fix: the trailing window still counts the
// first spend, so the second reverts OverWindowCap until the window has actually elapsed.

import {BudgetVault} from "../src/budget-vault/BudgetVault.sol";

interface Vm {
    function warp(uint256) external;
}

/// Minimal mintable ERC-20 so the vault has something to disburse.
contract TestToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "insufficient");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// External spender (the agent role) — routes spend() so the PoC itself stays the owner
/// and we avoid `address(this)` (which forge script forbids).
contract Spender {
    function doSpend(BudgetVault v, address to, uint256 a) external { v.spend(to, a); }
}

contract BudgetVaultWindowPoC {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    event Log(string what, uint256 value);
    event Result(string verdict);

    TestToken token;
    BudgetVault vault;
    Spender spender;
    address payee = address(0xBEEF);

    uint256 constant WINDOW = 120;     // seconds (12 buckets of 10s)
    uint256 constant CAP    = 50;      // windowCap
    uint256 constant PER    = 50;      // perPaymentCap

    function run() external {
        check_boundaryBypassBlocked();
        check_windowReleasesAfterElapse();
        check_truncationUndercountBlocked();
        emit Result("SLIDING WINDOW HOLDS - boundary + truncation bypass fixed");
    }

    function setUp() internal {
        token = new TestToken();
        spender = new Spender();
        vault = new BudgetVault(address(spender), address(token), PER, CAP, WINDOW);
        token.mint(address(vault), 1000); // fund generously
    }

    /// The core fix: after spending the full cap, a second full-cap spend a few seconds
    /// later (the old boundary trick) must REVERT, because the trailing window still
    /// counts the first spend.
    function check_boundaryBypassBlocked() internal {
        setUp();
        vm.warp(1_000_000); // a deterministic, nonzero start time

        spender.doSpend(vault, payee, CAP);                 // spend full cap at t0
        emit Log("spent at t0", CAP);

        vm.warp(1_000_000 + WINDOW - 1);         // 1s before the window fully elapses
        bool reverted;
        try spender.doSpend(vault, payee, CAP) { reverted = false; } catch { reverted = true; }
        emit Log("remaining 1s before elapse", vault.remainingThisWindow());
        emit Result(reverted ? "2nd full-cap spend REJECTED (OverWindowCap) - fix holds" : "boundary bypass STILL WORKS (REGRESSION)");
        require(reverted, "REGRESSION: boundary double-spend succeeded");
    }

    /// Sanity: once the window has genuinely elapsed, spending is allowed again (the cap
    /// limits rate, it does not freeze the vault forever).
    function check_windowReleasesAfterElapse() internal {
        setUp();
        vm.warp(2_000_000);
        spender.doSpend(vault, payee, CAP);                 // full cap
        // Coverage is (BUCKETS+1) buckets = 13 * (120/12) = 130s (conservative over-count
        // by up to one bucket — the SAFE direction). Wait past full coverage, then it frees.
        vm.warp(2_000_000 + WINDOW + 10 + 1); // +131s > 130s coverage (13 buckets * 10s)
        emit Log("remaining after full coverage", vault.remainingThisWindow());
        spender.doSpend(vault, payee, CAP);                 // must succeed now
        emit Result("spend allowed after coverage elapsed - not bricked");
    }

    /// Regression found by the independent reviewer: with windowSeconds NOT a multiple of
    /// BUCKETS (e.g. 23 → bucketSeconds=1), the old BUCKETS-only sum covered just 12s, so
    /// spending CAP at t0 then CAP at t=12 slipped through (200 in 12s vs cap 100/23s).
    /// With the BUCKETS+1 fix, coverage >= windowSeconds, so the second spend must REVERT.
    function check_truncationUndercountBlocked() internal {
        token = new TestToken();
        spender = new Spender();
        vault = new BudgetVault(address(spender), address(token), 100, 100, 23); // windowSeconds=23 (not mult of 12)
        token.mint(address(vault), 1000);

        vm.warp(3_000_000);
        spender.doSpend(vault, payee, 100);                 // full cap at t0
        vm.warp(3_000_000 + 12);                 // 12s later — still within the 23s window
        bool reverted;
        try spender.doSpend(vault, payee, 100) { reverted = false; } catch { reverted = true; }
        emit Log("remaining at t+12 (window=23)", vault.remainingThisWindow());
        emit Result(reverted ? "truncation bypass REJECTED - Low fix holds" : "truncation bypass STILL WORKS (REGRESSION)");
        require(reverted, "REGRESSION: truncation undercount bypass succeeded");
    }
}
