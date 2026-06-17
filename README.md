# Aegis Pay — Trust-Gated Agent Payments

> *Agents pay only who's trusted, only what's allowed.*

**Skill-to-Agent Dual Cascade Hackathon (Phase 1) · Pharos Atlantic Testnet (chain id 688689)**

Two composable Skills — **Aegis Gate** (`PaymentGate`) and **Aegis Vault** (`BudgetVault`)
— that make autonomous agent payments on Pharos **safe**.

## Live on Pharos Atlantic (source verified ✓)

| Contract | Address | Explorer |
|----------|---------|----------|
| **Aegis Gate** (`PaymentGate`) | `0x6025bda965bebea591eb6d474907206cd5654c62` | [Pharosscan](https://atlantic.pharosscan.xyz/address/0x6025bda965bebea591eb6d474907206cd5654c62) |
| **Aegis Vault** (`BudgetVault`) | `0x803cf3c49aa2a8ab7a3b9aa67651ef750495b220` | [Pharosscan](https://atlantic.pharosscan.xyz/address/0x803cf3c49aa2a8ab7a3b9aa67651ef750495b220) |
| MockReputationRegistry (ERC-8004 demo) | `0x1d4a3cb00090775a8c12dd47c5a84a007e5367de` | [Pharosscan](https://atlantic.pharosscan.xyz/address/0x1d4a3cb00090775a8c12dd47c5a84a007e5367de) |

All three are deployed on Atlantic (chain id 688689) and **source-verified on Pharosscan**
(`Pass - Verified`). `forge build` is clean; regression PoCs in `test/` pass.

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
| **Aegis Gate** | `PaymentGate` | *WHO may be paid?* — reads ERC-8004 reputation, enforces a min score + min number of ratings | No (pure decision + audit event) |
| **Aegis Vault** | `BudgetVault` | *HOW MUCH may flow?* — per-payment cap, sliding-window cap, payee allowlist, kill-switch | Yes (executes the transfer) |

**Composability (the judging criterion #1), demonstrated by code:**

```
authorizePayment(payeeAgentId, amount)   # Aegis Gate — is the payee trusted enough?
        │  reverts ReputationTooLow / NotEnoughFeedback if not
        ▼
spend(payeeAddr, amount)                  # Aegis Vault — within budget? then transfer
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
│   ├── trust-gated-pay.md                     # agent instructions for Aegis Gate
│   └── budget-vault.md                        # agent instructions for Aegis Vault
├── script/
│   └── Deploy.s.sol                           # deploys the 3 contracts to Atlantic
├── test/
│   ├── RoleSeparationPoC.sol                  # proves a compromised agent can't drain
│   ├── BudgetVaultWindowPoC.sol              # proves the sliding-window cap holds
│   └── ExploitPoC.sol                         # sybil / negative-grief regression checks
└── src/                                       # mirror of assets/*.sol (Skill Engine convention)
```

## Quickstart (with Foundry + Claude Code)

```bash
# Prereqs
curl -L https://foundry.paradigm.xyz | bash && foundryup       # forge, cast

# Compile + run the regression PoCs (no network needed)
forge build
forge script test/RoleSeparationPoC.sol:RoleSeparationPoC --sig "run()"      # agent can't drain
forge script test/BudgetVaultWindowPoC.sol:BudgetVaultWindowPoC --sig "run()" # sliding-window holds

# Deploy to Atlantic (put your funded testnet key in .env as PRIVATE_KEY=0x...)
forge script script/Deploy.s.sol:Deploy \
  --rpc-url https://atlantic.dplabs-internal.com --private-key $PRIVATE_KEY --broadcast

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
- **Separated roles (least privilege)**: the vault splits `owner` (a human/multisig:
  policy, pause, allowlist, and the `withdraw` escape hatch) from `spender` (the agent:
  `spend` only, always within the guardrails). So a **compromised agent cannot drain** —
  it can only spend within `windowCap` per `windowSeconds`, and the owner can revoke it
  instantly via `setSpender`. `PaymentGate` moves no funds at all.
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
- The owner is trusted by design (it can `withdraw`); the security claim is that the
  *agent* (spender) can't drain. For maximal assurance, set `owner` to a multisig.
