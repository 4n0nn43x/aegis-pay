---
name: pharos-agent-trust-and-budget
description: >-
  Skills for autonomous AI agents on Pharos that make agent payments SAFE: gate a
  payment on the payee's on-chain ERC-8004 reputation before paying, and enforce
  on-chain spending guardrails (per-payment cap, rolling-window cap, payee
  allowlist, kill-switch) that x402 leaves "to be implemented externally". Use
  when the user asks to pay an agent/provider safely, check an agent's reputation
  or trust score before paying, set a spending limit or budget for an agent, cap
  or rate-limit agent spending, allowlist payees, freeze or pause agent payments,
  or wire trust-gated payments on Pharos Chain / Pharos Network. Targets the Pharos
  Atlantic testnet (chain id 688689). Do not attempt to invent reputation values —
  always read them on-chain.
---

# Aegis Pay — Trust-Gated Agent Payments

> *Agents pay only who's trusted, only what's allowed.*

Aegis Pay is two composable Skills that together make autonomous agent payments on
Pharos safe. They are independently useful and independently deployable, but designed
to chain:

- **Aegis Gate** (`PaymentGate`) — decides **WHO** may be paid by reading the payee's
  aggregated ERC-8004 reputation and enforcing a minimum score and a minimum number of
  ratings. Comes with an ERC-8004-compatible `MockReputationRegistry` for live demos.
- **Aegis Vault** (`BudgetVault`) — decides **HOW MUCH** may flow and **executes** the
  transfer, under a per-payment cap, a sliding-window cap, an optional payee allowlist,
  and an owner kill-switch.

The story: *Aegis Gate approves the payee, Aegis Vault releases the funds.*

**The safe payment sequence an agent should follow:**
`PaymentGate.authorizePayment(payeeAgentId, amount)` → resolve the payee wallet →
`BudgetVault.spend(payeeAddr, amount)`. Skipping the first defeats trust; skipping
the second defeats budgeting.

## Write Operation Pre-checks

Before ANY `cast send` / `forge create`, confirm all four:

1. **Private key** is exported: `$PRIVATE_KEY` is set.
2. **Address** is derived: `cast wallet address --private-key $PRIVATE_KEY`.
3. **RPC** is reachable: `cast chain-id --rpc-url <rpc>` returns `688689`.
4. **Balance** is non-zero: `cast balance <address> --rpc-url <rpc>` > 0
   (fund from the Pharos Atlantic faucet if needed).

Foundry does NOT read env vars automatically — always pass `--private-key
$PRIVATE_KEY` explicitly on writes. `<rpc>` and chain id come from
`assets/networks.json`.

## Capability Index

| User Need | Capability | Detailed Instructions |
|-----------|------------|----------------------|
| Deploy reputation gate / set up trust-gated payments | forge create PaymentGate + MockReputationRegistry | → references/trust-gated-pay.md#deploy-the-reputation-registry-demo-and-paymentgate |
| Seed / record reputation feedback for an agent (demo) | cast send giveFeedback() | → references/trust-gated-pay.md#seed-reputation-demo-only |
| Check an agent's reputation / trust score before paying | cast call reputationOf() / isAuthorized() | → references/trust-gated-pay.md#check-a-payees-reputation-read-only |
| Authorize a payment / verify a payee is trustworthy enough to pay | cast send authorizePayment() | → references/trust-gated-pay.md#authorize-a-payment-enforcing |
| Update the trust policy (min score / min ratings) | cast send setPolicy() | → references/trust-gated-pay.md#authorize-a-payment-enforcing |
| Set a spending limit / budget / cap for an agent | forge create BudgetVault | → references/budget-vault.md#deploy-budgetvault |
| Fund the agent's budget vault | cast send transfer() + noteDeposit() | → references/budget-vault.md#fund-the-vault |
| Allowlist a payee / restrict who the agent can pay | cast send setAllowlisted() / setAllowlistEnabled() | → references/budget-vault.md#configure-guardrails-allowlist--pause--policy |
| Freeze / pause / kill-switch agent spending | cast send setPaused() | → references/budget-vault.md#configure-guardrails-allowlist--pause--policy |
| Rate-limit / retune spending caps | cast send setPolicy() | → references/budget-vault.md#configure-guardrails-allowlist--pause--policy |
| Pay a payee under guardrails / execute a guarded payment | cast call remainingThisWindow() + cast send spend() | → references/budget-vault.md#spend-execute-a-guarded-payment |
| Withdraw funds from the vault (owner) | cast send withdraw() | → references/budget-vault.md#configure-guardrails-allowlist--pause--policy |

For any operation, open the referenced file and follow its Command Template,
Parameters, Output Parsing, Error Handling, and Agent Guidelines exactly.
