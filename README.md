# Aegis Pay — Trust-Gated Agent Payments

> *Agents pay only who's trusted, only what's allowed.*

**Skill-to-Agent Dual Cascade Hackathon (Phase 1) · Pharos Atlantic Testnet (chain id 688689)**

Two composable Skills — **Aegis Gate** (`PaymentGate`) and **Aegis Vault** (`BudgetVault`)
— that make autonomous agent payments on Pharos **safe**.

---

## The gap we fill

The Pharos agent economy has two protocols that don't talk to each other:

- **ERC-8004** records *who is trustworthy* (on-chain agent reputation).
- **x402** *settles payments* between agents.

Nothing connects them. An agent can pay a provider, but it has no on-chain way to
ask **"does this provider actually deserve to be paid?"** before settling. And
x402, by its own specification, leaves spending limits *"to be implemented
externally"* — so an agent's wallet is effectively unbounded, one hallucination
or prompt-injection away from being drained.

This pack closes both gaps with two small, auditable, composable contracts.

## The two Skills

| Skill | Contract | Answers | Moves funds? |
|-------|----------|---------|--------------|
| **Trust-Gated Payment** | `PaymentGate` | *WHO may be paid?* — reads ERC-8004 reputation, enforces a min score + min number of ratings | No (pure decision + audit event) |
| **Budget Vault** | `BudgetVault` | *HOW MUCH may flow?* — per-payment cap, rolling-window cap, payee allowlist, kill-switch | Yes (executes the transfer) |

**Composability (the judging criterion #1), demonstrated by code:**

```
authorizePayment(payeeAgentId, amount)   # Skill #1 — is the payee trusted enough?
        │  reverts ReputationTooLow / NotEnoughFeedback if not
        ▼
spend(payeeAddr, amount)                  # Skill #2 — within budget? then transfer
        │  reverts OverPerPaymentCap / OverWindowCap / IsPaused / PayeeNotAllowed
        ▼
payment settled on-chain, fully audited (PaymentAuthorized + Spent events)
```

Skipping the first defeats trust; skipping the second defeats budgeting. Each Skill
is independently useful and independently deployable — but together they are a
complete safe-payment primitive other builders can reuse.

## Why this is differentiated

Across the Phase-1 field, projects either *pay* agents or *secure wallets*. None
**gate the payment itself on reputation**, and none enforce **composable on-chain
budgets** as the settlement path. The "ERC-8004 → x402" trust layer is an
explicitly unbuilt integration point in the agent-economy literature; this is a
focused, working slice of it.

## Repository layout (Pharos Skill Engine format)

```
pharos-skills/
├── SKILL.md                                  # manifest + Capability Index
├── README.md                                 # this file
├── assets/
│   ├── networks.json                         # Atlantic RPC / chainId / explorer / USDC
│   ├── trust-gated-pay/
│   │   ├── IReputationRegistry.sol           # ERC-8004 read interface (getSummary)
│   │   ├── PaymentGate.sol                    # the trust gate
│   │   └── MockReputationRegistry.sol         # ERC-8004-compatible registry for demos
│   └── budget-vault/
│       └── BudgetVault.sol                    # spending guardrails + transfer
├── references/
│   ├── trust-gated-pay.md                     # agent instructions for Skill #1
│   └── budget-vault.md                        # agent instructions for Skill #2
└── src/                                       # mirror of assets/*.sol (Skill Engine convention)
```

## Quickstart (with Foundry + Claude Code)

```bash
# Prereqs
curl -L https://foundry.paradigm.xyz | bash && foundryup       # forge, cast
export PRIVATE_KEY=0xYourTestnetKey                            # fund it from the Atlantic faucet

# Compile
forge build

# Then drive it in natural language via Claude Code, e.g.:
#   "Deploy a reputation gate requiring score 7 and at least 3 ratings"
#   "Set a budget vault for USDC: 5 per payment, 50 per hour"
#   "Pay agent #42 0.01 USDC if it's trustworthy enough"
# The agent reads SKILL.md → the right reference file → runs the cast/forge commands.
```

See `references/trust-gated-pay.md` and `references/budget-vault.md` for the exact
end-to-end demo sequence (deploy → seed reputation → show a rejection → show an
authorized, budgeted payment).

## Security notes (for the CertiK Skill Scanner)

- **Self-contained**: no external network calls, no shell execution, no file-system
  access. The Solidity depends only on a minimal in-repo `IERC20` interface and the
  ERC-8004 read interface — no opaque imports.
- **No private-key handling in code**: keys are passed only via `--private-key
  $PRIVATE_KEY` on the command line, per Skill Engine convention; nothing is read,
  stored, or logged by the contracts or references.
- **Least privilege**: `spend`, policy changes, pause, allowlist, and withdraw are
  all `onlyOwner`. `PaymentGate` moves no funds at all.
- **Human-readable reverts + events on every state change**, so an agent (and an
  auditor) can always tell exactly what happened and why.

## Honest limitations

- `MockReputationRegistry` is a faithful but **simplified** ERC-8004 registry
  (averages feedback in-contract; omits tags/URIs/revoke). Its `getSummary` read
  signature matches the spec exactly, so the canonical ERC-8004 registry can be
  swapped in with **no change** to `PaymentGate`. ERC-8004 is still a Draft EIP.
- x402 settlement is performed off-chain by a facilitator; this pack provides the
  **on-chain authorization and budgeted execution** around it (the part x402 says
  is out of scope), not a reimplementation of the x402 wire protocol.
- `BudgetVault.spend` is `onlyOwner` by design: the agent's signer owns the vault
  and is the only caller. Multi-signer / delegated-spender setups are future work.
