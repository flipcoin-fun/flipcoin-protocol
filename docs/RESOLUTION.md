# Market Resolution Mechanism

> Resolution lifecycle for FlipCoin prediction markets.
> For the full ShareToken contract specification, see [HYBRID_SPEC_v5.md](HYBRID_SPEC_v5.md) §3 and §10.

**Scope:** dev / sandbox mode.
The mechanism described herein is used for testing and development.
Production will require decentralized resolution (oracle network, bonded disputes, etc.).

---

## Overview

Each market progresses through the following stages:

1. **Trading** — users buy and sell YES/NO positions
2. **Deadline** — trading deadline reached, market awaits resolution
3. **Resolution Proposal** — the oracle proposes an outcome
4. **Dispute Period** — shareholders may dispute the proposed outcome
5. **Finalization** — the outcome is permanently locked, CLOB paused
6. **Redemption** — holders of winning positions receive their payout

---

## State Machine

### On-chain States (ShareToken.ResolutionStatus)

The ShareToken contract defines exactly three resolution states:

```solidity
enum ResolutionStatus { Open, Pending, Resolved }
```

The **logical lifecycle** maps to these states as follows:

| Logical Phase | ResolutionStatus | Trading | Description |
|---------------|-----------------|---------|-------------|
| Trading active | Open | Allowed | Normal trading |
| Past deadline, awaiting resolution | Open | Allowed (no on-chain halt) | Oracle should propose |
| Resolution proposed, dispute period | Pending | Blocked (conditionPaused) | 24h dispute window |
| Outcome finalized | Resolved | Blocked permanently | Redemption enabled |

> **Note**: There is no separate `TradingClosed` or `Invalid` state on-chain.
> `Invalid` is an outcome (`Outcome.Invalid`), not a status.
> Trading halt past deadline is enforced by the CLOB engine (offchain) and by
> `conditionPaused` after resolution proposal.

### State Diagram

```
                  proposeResolution(outcome)
    Open ──────────────────────────────────► Pending
     │                                          │
     │                                          ├── disputeResolution()
     │                                          │   → resets to Open
     │                                          │
     │                                          └── finalizeResolution()
     │                                              (after 24h, by anyone)
     │                                              → Resolved
     │                                              → exchange.pauseCondition() [FINAL]
     │
     └── markAsInvalid()
         (deadline + 6h, status must be Open)
         → Resolved (outcome = Invalid)
         → exchange.pauseCondition() [FINAL]
```

### Transitions

| From | To | Trigger | Caller |
|------|----|---------|--------|
| Open | Pending | `proposeResolution(outcome)` | Oracle only, after deadline |
| Pending | Open | `disputeResolution()` | Any shareholder, during 24h window |
| Pending | Resolved | `finalizeResolution()` | Anyone, after 24h window expires |
| Open | Resolved | `markAsInvalid()` | Anyone, after deadline + 6h |

---

## Resolution Flow

### 1. End of Trading

When the market's `deadline` is reached:
- The CLOB matching engine stops accepting new orders for this condition
- LMSR backstop trades are no longer routed by the engine
- On-chain: the market remains in `Open` status until resolution is proposed

> **pauseCondition integration**: `exchange.pauseCondition(conditionId)` is called
> as a side effect of both `finalizeResolution()` and `markAsInvalid()`. Once paused,
> the condition is **never unpaused** — CLOB settlement is permanently disabled.
> Before finalization, the engine enforces the trading halt offchain.

### 2. Oracle Resolution Window

**Duration:** 6 hours after the deadline (`ADMIN_RESOLVE_WINDOW`)

During this window the oracle (admin in dev mode):
- Analyzes information sources
- Determines the actual outcome of the event
- Calls `proposeResolution(conditionId, outcome)`

**State transition:**
```
Open → Pending
```

**Guards:**
```solidity
require(resolutions[conditionId].status == Open, "not open");
require(block.timestamp > conditions[conditionId].deadline, "deadline not reached");
```

> **Cannot propose twice**: `proposeResolution` requires `status == Open`.
> If the oracle wants to change their proposal, the previous proposal must first
> be disputed (reset to Open) before a new proposal can be submitted.

### 3. Dispute Period

**Duration:** 24 hours after proposal (`DISPUTE_PERIOD`)

During this window any **shareholder** (holder of YES or NO tokens) may:
- Review the proposed outcome
- Call `disputeResolution(conditionId)` to contest

**Effects of dispute:**
- Status resets to `Open`
- The oracle must re-investigate and propose again
- No limit on the number of dispute cycles

**Important:**
- Only shareholders can dispute (skin in the game)
- Disputes are free (no bond required in dev mode)
- A dispute does NOT propose an alternative — it simply rejects and resets
- Disputes do NOT extend the window — the 24h is fixed from proposal time

**Guards:**
```solidity
require(resolutions[conditionId].status == Pending, "not pending");
require(block.timestamp <= resolutions[conditionId].proposedAt + DISPUTE_PERIOD, "window closed");
// Shareholder check:
require(
    shareToken.balanceOf(msg.sender, yesTokenId) > 0 ||
    shareToken.balanceOf(msg.sender, noTokenId) > 0,
    "not shareholder"
);
```

### 4. Finalization

After the dispute window closes (24h elapsed with no dispute), **anyone** may call
`finalizeResolution(conditionId)`.

**Effects:**
```
1. status = Resolved
2. finalOutcome = proposedOutcome
3. payoutPerShare = PAYOUT_PER_SHARE (1_000_000 = $1 for Yes/No)
4. exchange.pauseCondition(conditionId) — CLOB permanently disabled
5. emit ResolutionFinalized(conditionId, outcome, payoutPerShare)
```

**Guards:**
```solidity
require(resolutions[conditionId].status == Pending, "not pending");
require(block.timestamp > resolutions[conditionId].proposedAt + DISPUTE_PERIOD, "too early");
```

After finalization:
- The outcome is **immutable** — no further changes possible
- `redeemPositions()` becomes available
- `exchange.pauseCondition()` prevents any CLOB settlement

### 5. Redemption

Holders of winning positions call `ShareToken.redeemPositions(conditionId)`:

| Outcome | Who redeems | Payout per share |
|---------|-------------|------------------|
| Yes | YES token holders | $1.00 (1_000_000) |
| No | NO token holders | $1.00 (1_000_000) |
| Invalid | ALL token holders (YES + NO) | $0.50 (500_000) — hardcoded |

**Invalid payout rationale:**
Since `yesSupply == noSupply` (split/merge invariant), paying $0.50 per share
means each holder of a YES+NO pair receives exactly $1.00 (full refund).
A holder of only YES (or only NO) receives $0.50 — proportional to their exposure.

The $0.50 payout is **hardcoded** (not calculated from pool balance) for simplicity,
no rounding issues, and no oracle dependency. The `splitReserve` in the Vault always
covers this: `totalYesSupply * 500K + totalNoSupply * 500K = splitReserve`.

See [LMSR_SPEC.md](LMSR_SPEC.md) §2.3 and [HYBRID_SPEC_v5.md](HYBRID_SPEC_v5.md) §3.1.

---

## Unresolved Markets (markAsInvalid)

If the oracle **does not propose any outcome** within 6 hours after the deadline,
the market becomes eligible for `Invalid` resolution.

### Preconditions (ALL must be true)

```solidity
require(resolutions[conditionId].status == Open, "not open");
require(block.timestamp > conditions[conditionId].deadline + ADMIN_RESOLVE_WINDOW, "window not expired");
require(conditions[conditionId].prepared == true, "not prepared");
```

### Why status == Open only

`markAsInvalid` is a safety valve for **oracle inactivity only**. If the oracle
has already proposed a resolution (`status == Pending`), the dispute period
mechanism handles the outcome. `markAsInvalid` cannot be used to bypass an
active proposal.

### Who can call

**Anyone.** This is a permissionless safety valve, not a privileged function.
The function does not "automatically" trigger — a user must explicitly call it.

### Effects

```
1. status = Resolved (skips Pending — no dispute period needed)
2. finalOutcome = Invalid
3. payoutPerShare = 500_000 ($0.50, hardcoded)
4. exchange.pauseCondition(conditionId) — CLOB permanently disabled
5. emit MarkedAsInvalid(conditionId, msg.sender, block.timestamp)
6. emit ResolutionFinalized(conditionId, Invalid, 500_000)
```

### Finality

**Irreversible.** No un-invalid path. No dispute period.
Once `markAsInvalid` executes, the market is permanently resolved as Invalid.

---

## Evidence (dev mode)

In dev mode, resolution evidence is submitted offchain and stored in the database.
The admin provides a `resolutionReason` text when proposing resolution via the UI.

For future production use, an on-chain evidence commitment scheme is planned:

```
evidenceHash = keccak256(bytes(evidenceURI))
```

Where `evidenceURI` is a stable URL pointing to the evidence document.

> **Note**: Using `keccak256(abi.encodePacked(jsonString))` is not recommended
> because JSON serialization is not canonical — whitespace and field ordering
> differences produce different hashes. Use `keccak256(bytes(uri))` instead,
> committing to the URI rather than the content.

---

## On-chain Interface (ShareToken)

### Resolution Functions

```solidity
// Oracle proposes a resolution (after deadline)
function proposeResolution(bytes32 conditionId, Outcome outcome)
    external; // onlyOracle

// Shareholder disputes during DISPUTE_PERIOD
function disputeResolution(bytes32 conditionId)
    external; // onlyShareholder

// Anyone finalizes after DISPUTE_PERIOD expires
function finalizeResolution(bytes32 conditionId)
    external; // anyone

// Anyone marks as invalid after deadline + ADMIN_RESOLVE_WINDOW (status must be Open)
function markAsInvalid(bytes32 conditionId)
    external; // anyone, permissionless

// Holder redeems winning positions
function redeemPositions(bytes32 conditionId)
    external; // anyone with tokens
```

### Events

```solidity
event ResolutionProposed(
    bytes32 indexed conditionId,
    Outcome outcome,
    uint64 proposedAt,
    uint64 finalizeAfter
);

event ResolutionDisputed(
    bytes32 indexed conditionId,
    address indexed challenger,
    Outcome proposedOutcome
);

event ResolutionFinalized(
    bytes32 indexed conditionId,
    Outcome outcome,
    uint256 payoutPerShare
);

event MarkedAsInvalid(
    bytes32 indexed conditionId,
    address indexed caller,
    uint64 markedAt
);

event PositionRedeemed(
    bytes32 indexed conditionId,
    address indexed user,
    uint256 sharesBurned,
    uint256 usdcPayout
);
```

### Time Constants

```solidity
uint64 public constant DISPUTE_PERIOD = 24 hours;
uint64 public constant ADMIN_RESOLVE_WINDOW = 6 hours;
```

---

## Oracle / Admin Role

### Dev Mode: Centralized Admin

In dev/sandbox mode, the oracle is a single administrator address.

**Authorities:**
- Propose a resolution after the deadline
- Re-propose after a dispute resets to Open

**Restrictions:**
- Cannot resolve before the deadline
- Cannot bypass the dispute period (24h is mandatory)
- Cannot change the outcome after finalization
- Cannot call `markAsInvalid` (it's permissionless but requires `status == Open`)

**Admin address is set at deployment and cannot be changed** for the lifetime
of a ShareToken instance. This prevents admin replacement before resolution.

### Transparency

All resolution actions are:
- Recorded on the blockchain (events)
- Indexed by the protocol indexer
- Visible in the admin dashboard and market detail pages

### Centralization Disclosure

When a market is created, the user is explicitly informed:

> This market is resolved by the protocol administrator.
> The administrator is the final arbiter during the dispute period.
> All decisions are recorded on-chain and publicly auditable.

This information is displayed:
- On the market creation page
- On the market card
- In the modal before the first trade

---

## Current Limitations

This resolution mechanism:

1. **Is centralized** — a single admin makes decisions; no oracle network
2. **Has no bonding** — disputes are free; no penalties for frivolous disputes
3. **Has no incentive alignment** — no staking, no slashing, no reputation
4. **Disputes do not extend the window** — a challenge at minute 1439 of 1440 gives
   the oracle only 1 minute to review (acceptable in dev mode)
5. **Requires trust** — users must trust the admin to act honestly

These limitations are explicitly documented and acceptable for dev/sandbox mode.
Production resolution will require decentralized mechanisms.

---

## Changelog

| Version | Date | Description |
|---------|------|-------------|
| 2.0 | 2026-02 | Rewrite: sync with v5.2 ShareToken states, 24h dispute period, hardcoded Invalid payout, pauseCondition integration |
| 1.1 | 2026-01 | Added "Unresolved Markets (Invalid)" section |
| 1.0 | 2026-01 | Initial version for dev mode |
