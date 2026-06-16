# Trust-Gated Payment — Operation Instructions

> **Network Configuration:** `<rpc>` is the Pharos Atlantic testnet RPC
> (`https://atlantic.dplabs-internal.com`, chain id `688689`), read from
> `assets/networks.json`.
> **Private Key:** Foundry does NOT read env vars automatically — pass it
> explicitly on every write with `--private-key $PRIVATE_KEY`.

## Why this skill exists (read this first)

An AI agent on Pharos can already *pay* a provider over x402. What it cannot do
natively is answer the question that comes *before* paying: **"does this provider
actually deserve to be paid?"** ERC-8004 records on-chain reputation for agents;
x402 settles payments. Nobody connects the two. This skill is that connection.

The `PaymentGate` contract reads a payee agent's aggregated ERC-8004 reputation
(`getSummary`) and authorizes a payment **only** if the payee clears two bars:

1. a **minimum score** (e.g. ≥ 7.0 on a 0–10 scale), and
2. a **minimum number of feedback entries** (so a single glowing rating from a
   sock-puppet is not enough).

`PaymentGate` makes the *decision* and emits an auditable `PaymentAuthorized`
event. It does **not** move money — that is the job of the `BudgetVault` skill
(see `references/budget-vault.md`) or of the x402 facilitator. Keeping the policy
contract free of fund movement is deliberate: it stays a pure, easy-to-audit
decision layer.

**The agent's job:** before settling any x402 payment, call the gate. If it
authorizes, proceed. If it reverts, do NOT pay — explain why to the user.

---

## Deploy the Reputation Registry (demo) and PaymentGate

### Overview

For a live demo you need a Reputation Registry to read from. The canonical
ERC-8004 registry may not be deployed on Atlantic yet (the EIP is still Draft),
so this skill ships `MockReputationRegistry.sol`, which implements the real
`getSummary` read shape. Deploy it, seed some feedback, then deploy `PaymentGate`
pointed at it. To use a real ERC-8004 registry instead, skip the mock deploy and
pass its address as `<reputation_registry>`.

### Command Template

```bash
# 1) Deploy the demo Reputation Registry (no constructor args)
forge create assets/trust-gated-pay/MockReputationRegistry.sol:MockReputationRegistry \
  --rpc-url <rpc> --private-key $PRIVATE_KEY

# 2) Deploy PaymentGate(reputationRegistry, minScore, minFeedbackCount)
#    minScore is 1e18-fixed (7e18 = score 7.0); minFeedbackCount is a plain uint.
forge create assets/trust-gated-pay/PaymentGate.sol:PaymentGate \
  --rpc-url <rpc> --private-key $PRIVATE_KEY \
  --constructor-args <reputation_registry> 7000000000000000000 3
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `<rpc>` | url | Yes | Atlantic RPC from `assets/networks.json` |
| `<reputation_registry>` | address | Yes | Mock (step 1 output) or a real ERC-8004 registry |
| `minScore` | int128 (1e18) | Yes | Reputation bar, 18-dec fixed point. `7e18` = 7.0 |
| `minFeedbackCount` | uint64 | Yes | Minimum distinct feedback entries required |

### Output Parsing

| Field | Description |
|-------|-------------|
| `contractAddress` | Deployed address — save as `<payment_gate>` (and `<reputation_registry>` for step 1) |
| `transactionHash` | View at `https://atlantic.pharosscan.xyz/tx/<hash>` |

### Error Handling

| Error Signature | Cause | Suggested Action |
|----------------|-------|------------------|
| `insufficient funds` | Signer EOA has no testnet PHRS for gas | Fund the EOA from the Pharos faucet, retry |
| reverts on `forge create` | Bad constructor arg order/types | Order is `(registry, minScore, minFeedbackCount)`; `minScore` must be 1e18-scaled |

> **Agent Guidelines:**
> 1. Complete the Write Operation Pre-checks (see SKILL.md): key set, address
>    derived, RPC reachable, balance > 0.
> 2. Deploy the mock registry first **only if** no real ERC-8004 registry address
>    was given. Record its address.
> 3. Deploy `PaymentGate`. Echo back both addresses and the policy you set.
> 4. Wait ~10 s, then verify on the explorer before continuing.

---

## Authorize Attesters (demo only — do this BEFORE seeding)

### Overview

The mock registry gates feedback to authorized **attesters** (a hardening against
free Sybil ratings — see Security notes). The deployer is an attester by default.
To seed feedback from *additional* signer keys (needed to reach a
`minFeedbackCount` > 1), the registry owner must authorize each of those keys
first, or every `giveFeedback` from them reverts `NotAttester()`.

### Command Template

```bash
# Owner authorizes an extra attester address (repeat per extra signer key).
cast send <reputation_registry> "setAttester(address,bool)" <attester_addr> true \
  --rpc-url <rpc> --private-key $PRIVATE_KEY
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `<attester_addr>` | address | Yes | Signer address allowed to submit feedback |

> **Agent Guidelines:**
> 1. The deployer key is already an attester — no `setAttester` needed for the
>    first rating from the deploying key.
> 2. For each additional signer you'll seed from, call `setAttester(addr, true)`
>    from the OWNER key first, then seed from that signer.
> 3. On a real ERC-8004 registry this step does not exist — Sybil-resistance is
>    the registry's concern; skip straight to reading reputation.

---

## Seed Reputation (demo only)

### Overview

Give a payee agent some feedback so the gate has something to read. Skip this
step when reading from a real, already-populated ERC-8004 registry. Values are
1e18-fixed and **bounded to [0, 10e18]** (0.0–10.0); out-of-range or negative
values revert `ValueOutOfRange`. The mock allows one feedback per attester per
agent, so authorize several attesters (above) to reach a `minFeedbackCount` > 1.

### Command Template

```bash
cast send <reputation_registry> "giveFeedback(uint256,int128)" \
  <payee_agent_id> <value_1e18> \
  --rpc-url <rpc> --private-key $PRIVATE_KEY
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `<payee_agent_id>` | uint256 | Yes | ERC-8004 agentId being rated |
| `<value_1e18>` | int128 | Yes | Score in 1e18 fixed point, in [0, 10e18] (e.g. `8000000000000000000`) |

### Error Handling

| Error Signature | Cause | Suggested Action |
|----------------|-------|------------------|
| `NotAttester()` | Signer is not an authorized attester | Have the owner run `setAttester(<addr>, true)` first |
| `ValueOutOfRange(int128)` | `value` < 0 or > 10e18 | Pass a value in [0, 10e18] (1e18-scaled) |
| `AlreadyRated()` | This attester already rated this agent | Use a different authorized attester key |

> **Agent Guidelines:**
> 1. Authorize the extra attesters first (see section above), or seeding reverts.
> 2. To demonstrate the `NotEnoughFeedback` guard, seed *fewer* than
>    `minFeedbackCount` entries first and show the gate rejecting.
> 3. Then seed enough to pass and show authorization succeeding.

---

## Check a Payee's Reputation (read-only)

### Overview

Before paying, read the payee's normalized reputation and feedback count. This is
a pure `view` — no gas, no key strictly needed for the call. Use it to *decide*,
or to explain to the user why a payment will or won't be authorized.

### Command Template

```bash
# Normalized score (1e18) + feedback count
cast call <payment_gate> "reputationOf(uint256)(int128,uint64)" \
  <payee_agent_id> --rpc-url <rpc>

# Boolean policy check without reverting
cast call <payment_gate> "isAuthorized(uint256)(bool,int128,uint64)" \
  <payee_agent_id> --rpc-url <rpc>
```

### Output Parsing

| Field | Description |
|-------|-------------|
| `int128` (reputationOf) | Score in 1e18 fixed point — divide by 1e18 for the human value |
| `uint64` (reputationOf) | Number of feedback entries behind the score |
| `bool` (isAuthorized) | `true` ⇒ payee passes current policy |

> **Agent Guidelines:**
> 1. Always divide the score by 1e18 before showing it (e.g. `8000000000000000000`
>    → "8.0").
> 2. If `isAuthorized` is false, tell the user the actual score and count vs. the
>    required `minScore`/`minFeedbackCount` (read them with `cast call
>    <payment_gate> "minScore()(int128)"` and `"minFeedbackCount()(uint64)"`).

---

## Authorize a Payment (enforcing)

### Overview

The gate check the agent runs immediately before settling an x402 payment. Reverts
with a precise reason if the payee fails policy; on success emits
`PaymentAuthorized` — the on-chain proof that the payment was reputation-checked.

### Command Template

```bash
cast send <payment_gate> "authorizePayment(uint256,uint256)" \
  <payee_agent_id> <amount_base_units> \
  --rpc-url <rpc> --private-key $PRIVATE_KEY
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `<payee_agent_id>` | uint256 | Yes | ERC-8004 agentId of the provider |
| `<amount_base_units>` | uint256 | Yes | Payment amount in token base units (USDC = 6 decimals → `0.01` = `10000`) |

### Output Parsing

| Field | Description |
|-------|-------------|
| `PaymentAuthorized` event | Confirms authorization; carries `score` and `feedbackCount` |
| `transactionHash` | Audit link on the explorer |

### Error Handling

| Error Signature | Cause | Suggested Action |
|----------------|-------|------------------|
| `ReputationTooLow(int128,int128)` | Payee score below `minScore` | Do NOT pay; report score vs. required |
| `NotEnoughFeedback(uint64,uint64)` | Too few ratings (cold start / gaming) | Do NOT pay; explain the payee is unproven |
| `ZeroAmount()` | `amount` was 0 | Pass a non-zero amount in base units |

> **Agent Guidelines:**
> 1. Decode the revert: on `ReputationTooLow` or `NotEnoughFeedback`, **stop** —
>    never fall back to paying anyway.
> 2. On success, proceed to settlement. If the `BudgetVault` skill is in use,
>    the next step is `BudgetVault.spend(<payee_addr>, <amount>)` — see
>    `references/budget-vault.md`. Otherwise kick off the normal x402 flow.
> 3. The `payee_agent_id` (ERC-8004) and the `payee_addr` (the wallet that
>    actually receives funds) are distinct. Resolve the wallet via the agent's
>    Identity Registry `getAgentWallet(agentId)` when settling.
