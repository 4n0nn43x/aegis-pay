# Budget Vault — Operation Instructions

> **Network Configuration:** `<rpc>` is the Pharos Atlantic testnet RPC
> (`https://atlantic.dplabs-internal.com`, chain id `688689`), read from
> `assets/networks.json`.
> **Private Key:** pass explicitly on every write with `--private-key $PRIVATE_KEY`.

## Why this skill exists (read this first)

x402 settles a payment but, by its own spec, leaves spending limits "to be
implemented externally." An autonomous agent with an unbounded wallet is a
liability: one hallucinated decision or one prompt-injection can drain it. The
`BudgetVault` IS that external enforcement — on-chain and composable.

The vault holds the agent's working funds and only releases them through
`spend()`, which enforces, in this order:

1. **kill-switch** — if the owner paused the vault, nothing moves;
2. **per-payment cap** — no single payment exceeds `perPaymentCap`;
3. **payee allowlist** — if enabled, funds only go to pre-approved addresses;
4. **rolling-window cap** — total spend stays under `windowCap` per
   `windowSeconds` window (the window auto-rolls).

It composes with the Trust-Gated Payment skill: `PaymentGate` decides **who**
may be paid, `BudgetVault` decides **how much** may flow and **executes** the
transfer. A safe agent does both: `authorizePayment(...)` then `spend(...)`.

---

## Deploy BudgetVault

### Overview

Deploy a vault bound to one ERC-20 (e.g. Atlantic test USDC,
`0xE0BE08c77f415F577A1B3A9aD7a1Df1479564ec8`, 6 decimals). The deployer becomes
the owner — the only address that can `spend`, retune policy, pause, or withdraw.

### Command Template

```bash
# BudgetVault(token, perPaymentCap, windowCap, windowSeconds)
# Example: USDC, 5 USDC/payment, 50 USDC/hour
forge create assets/budget-vault/BudgetVault.sol:BudgetVault \
  --rpc-url <rpc> --private-key $PRIVATE_KEY \
  --constructor-args <token> 5000000 50000000 3600
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `<token>` | address | Yes | ERC-20 the vault disburses (USDC = 6 decimals) |
| `perPaymentCap` | uint256 | Yes | Max per single spend, base units (`5 USDC` = `5000000`) |
| `windowCap` | uint256 | Yes | Max cumulative spend per window, base units |
| `windowSeconds` | uint256 | Yes | Rolling window length in seconds (`3600` = 1h) |

### Output Parsing

| Field | Description |
|-------|-------------|
| `contractAddress` | Save as `<budget_vault>` |
| `transactionHash` | `https://atlantic.pharosscan.xyz/tx/<hash>` |

> **Agent Guidelines:**
> 1. Run the Write Operation Pre-checks (SKILL.md).
> 2. Convert human amounts to base units using the token's decimals (6 for USDC).
> 3. Echo back the policy in human units so the user can confirm it.

---

## Fund the Vault

### Overview

Move ERC-20 into the vault so it has something to disburse. This is a normal
ERC-20 transfer to the vault address; `noteDeposit` is optional bookkeeping that
emits a `Deposited` audit event.

### Command Template

```bash
# Transfer tokens into the vault
cast send <token> "transfer(address,uint256)" <budget_vault> <amount_base_units> \
  --rpc-url <rpc> --private-key $PRIVATE_KEY

# (optional) record an audit event
cast send <budget_vault> "noteDeposit(uint256)" <amount_base_units> \
  --rpc-url <rpc> --private-key $PRIVATE_KEY
```

> **Agent Guidelines:**
> 1. Verify the vault balance after funding:
>    `cast call <token> "balanceOf(address)(uint256)" <budget_vault> --rpc-url <rpc>`.

---

## Configure Guardrails (allowlist / pause / policy)

### Overview

Owner-only controls to tighten or loosen the vault at runtime.

### Command Template

```bash
# Enable the allowlist and approve a payee
cast send <budget_vault> "setAllowlistEnabled(bool)" true --rpc-url <rpc> --private-key $PRIVATE_KEY
cast send <budget_vault> "setAllowlisted(address,bool)" <payee_addr> true --rpc-url <rpc> --private-key $PRIVATE_KEY

# Kill-switch: freeze / unfreeze all spending
cast send <budget_vault> "setPaused(bool)" true  --rpc-url <rpc> --private-key $PRIVATE_KEY
cast send <budget_vault> "setPaused(bool)" false --rpc-url <rpc> --private-key $PRIVATE_KEY

# Retune caps (perPaymentCap, windowCap, windowSeconds)
cast send <budget_vault> "setPolicy(uint256,uint256,uint256)" 2000000 20000000 3600 \
  --rpc-url <rpc> --private-key $PRIVATE_KEY
```

### Error Handling

| Error Signature | Cause | Suggested Action |
|----------------|-------|------------------|
| `NotOwner()` | Caller is not the vault owner | Use the deployer key |

> **Agent Guidelines:**
> 1. Treat `setPaused(true)` as the emergency stop — surface it to the user as
>    "freeze all agent spending now."

---

## Spend (execute a guarded payment)

### Overview

The call that actually moves money, under all guardrails. This is the settlement
step the agent runs **after** `PaymentGate.authorizePayment` has approved the
payee. Reverts with a precise reason if any guardrail is hit.

### Command Template

```bash
# Preview remaining room first (read-only)
cast call <budget_vault> "remainingThisWindow()(uint256)" --rpc-url <rpc>

# Execute
cast send <budget_vault> "spend(address,uint256)" <payee_addr> <amount_base_units> \
  --rpc-url <rpc> --private-key $PRIVATE_KEY
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `<payee_addr>` | address | Yes | Recipient wallet (resolve from agentId via Identity Registry) |
| `<amount_base_units>` | uint256 | Yes | Amount in token base units |

### Output Parsing

| Field | Description |
|-------|-------------|
| `Spent` event | Confirms transfer; carries running `spentInWindow` |
| `transactionHash` | Audit link on the explorer |

### Error Handling

| Error Signature | Cause | Suggested Action |
|----------------|-------|------------------|
| `IsPaused()` | Kill-switch is on | Do not retry; tell the user spending is frozen |
| `OverPerPaymentCap(uint256,uint256)` | Amount exceeds single-payment cap | Split the payment or raise the cap (owner) |
| `OverWindowCap(uint256,uint256)` | Window budget exhausted | Wait for the window to roll, or raise `windowCap` |
| `PayeeNotAllowed(address)` | Allowlist on, payee not listed | Allowlist the payee (owner) or stop |
| `TransferFailed()` | Vault underfunded or token reverted | Check vault balance; fund it |

> **Agent Guidelines:**
> 1. Call `remainingThisWindow()` and compare to the amount **before** spending —
>    avoid a guaranteed revert.
> 2. On a cap revert, do NOT loop-retry; explain the limit to the user and stop.
> 3. The full safe sequence is: (a) `PaymentGate.authorizePayment(agentId, amount)`,
>    (b) resolve `payee_addr` from the agent's Identity Registry, (c)
>    `BudgetVault.spend(payee_addr, amount)`. Skipping (a) defeats trust-gating;
>    skipping (c) defeats budget enforcement.
