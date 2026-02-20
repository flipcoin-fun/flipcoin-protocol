# Market Resolution Mechanism

This document describes the process of determining the outcome of a prediction market in the Flipcoin system.

**Scope:** dev / sandbox mode.
The mechanism described herein is used exclusively for testing and development purposes.

---

## Overview

Each market progresses through the following stages:

1. **Trading** — users buy and sell YES/NO positions
2. **Deadline** — trading is automatically halted
3. **Resolution** — the administrator determines the outcome
4. **Challenge** — users may submit evidence to dispute the outcome
5. **Finalization** — the outcome is permanently locked
6. **Redemption** — holders of winning positions receive their payout

---

## Resolution Lifecycle

### 1. End of Trading

When the market's `deadline` is reached:
- All trading functions (`buyYes`, `buyNo`, `sellYes`, `sellNo`) are disabled
- The pool state is frozen
- The resolution window begins

**State transition:**
```
Open -> TradingClosed
```

### 2. Administrator Resolution Window

**Duration:** 6 hours after the deadline

During this window the protocol administrator:
- Analyzes information sources
- Determines the actual outcome of the event
- Calls `proposeResolve(outcome, evidenceURI, evidenceHash)`

**Call parameters:**
- `outcome` — the result: `Yes`, `No`, or `Invalid`
- `evidenceURI` — link to evidence (public URL)
- `evidenceHash` — keccak256 hash of the evidence pack

**State transition:**
```
TradingClosed -> ResolutionProposed
```

If the administrator does not propose a resolution within 6 hours, the market automatically transitions to the `Invalid` state (see the "Unresolved Markets" section).

### 3. Challenge Window

**Duration:** 1 hour after the resolution is proposed

During this window any user may:
- Review the proposed outcome and evidence
- Submit a challenge with alternative evidence
- Call `submitChallenge(alternativeOutcome, evidenceURI, evidenceHash, comment)`

**Call parameters:**
- `alternativeOutcome` — the proposed alternative outcome
- `evidenceURI` — link to alternative evidence
- `evidenceHash` — keccak256 hash of the evidence pack
- `comment` — brief rationale (up to 500 characters)

**Important:**
- A challenge does NOT change the outcome automatically
- A challenge is only recorded on-chain for review
- There is no limit on the number of challenges

**State transition:**
```
ResolutionProposed -> ResolutionProposed (state unchanged)
```

### 4. Finalization

After the challenge window closes, the administrator:
- Reviews all submitted challenges
- Makes the final decision
- Calls `finalizeResolve(finalOutcome)`

**Possible decisions:**
- Confirm the original outcome
- Change the outcome based on challenges
- Declare the market invalid (`Invalid`)

**State transition:**
```
ResolutionProposed -> Resolved
```

After finalization:
- The outcome becomes immutable
- `payoutPerShare` is calculated
- The `redeem()` function is activated

### 5. Redemption (Redeem)

Holders of winning positions call `redeem()`:
- If the outcome is `Yes` — payout goes to YES token holders
- If the outcome is `No` — payout goes to NO token holders
- If the outcome is `Invalid` — proportional refund to all participants

---

## Unresolved Markets (Invalid)

If the administrator **does not propose an outcome** within the resolution window
(Admin Resolve Window) after the market deadline, the market is considered
unresolved and is automatically transitioned to the **Invalid** state.

### Conditions

A market is declared `Invalid` when all of the following conditions are met:
- The market deadline has passed
- The administrator resolution window has expired (6 hours)
- The administrator has not called `proposeResolve()` (YES or NO)

### Consequences

In the case of `Invalid`:
- The market is finalized without selecting a YES or NO outcome
- Further resolution is no longer possible
- Payouts follow the `Invalid` rules:
  - All positions (YES and NO) are eligible for payout
  - Each user receives a proportional share of the pool
- Users bear no risk from administrator inaction

### Automatic Transition

Any user may call `markAsInvalid()` after the resolution window has expired:

```solidity
function markAsInvalid() external {
    require(status == MarketStatus.TradingClosed, "not in TradingClosed");
    require(block.timestamp > deadline + ADMIN_RESOLVE_WINDOW, "resolve window not expired");

    status = MarketStatus.Resolved;
    outcome = Outcome.Invalid;
    // ... calculate payoutPerShare for Invalid
}
```

### Note

The `Invalid` state serves as a safety valve in case a market is not properly
resolved due to administrative reasons. This rule is in effect in dev / sandbox
mode and is explicitly documented.

---

## State Diagram

```
+------+    deadline    +---------------+
| Open | ------------> | TradingClosed |
+------+                +---------------+
                              |
              +---------------+---------------+
              |                               |
              | proposeResolve()              | 6h timeout (no resolve)
              v                               v
    +--------------------+              +-----------+
    | ResolutionProposed |<----+        | Invalid   |---> redeem()
    +--------------------+     |        +-----------+
              |                |
              |                | submitChallenge()
              +----------------+
              |
              | 1h window ends + finalizeResolve()
              v
        +----------+
        | Resolved |---> redeem()
        +----------+
```

**Transitions:**
- `Open` -> `TradingClosed`: automatically when the deadline is reached
- `TradingClosed` -> `ResolutionProposed`: administrator calls `proposeResolve()`
- `TradingClosed` -> `Invalid`: 6 hours elapsed without resolution; anyone may call `markAsInvalid()`
- `ResolutionProposed` -> `Resolved`: administrator calls `finalizeResolve()` after the challenge window
- `Resolved` / `Invalid` -> users may call `redeem()`

---

## Evidence Pack

The `evidenceHash` is computed from a JSON document with the following structure:

```json
{
  "version": "1.0",
  "marketAddress": "0x...",
  "proposedOutcome": "Yes",
  "timestamp": "2024-01-15T14:30:00Z",
  "sources": [
    {
      "url": "https://example.com/official-announcement",
      "type": "official",
      "archived": "https://web.archive.org/web/..."
    },
    {
      "url": "https://twitter.com/...",
      "type": "social",
      "archived": null
    }
  ],
  "rationale": "Brief rationale for the decision based on the provided sources.",
  "resolverAddress": "0x..."
}
```

**Fields:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `version` | string | yes | Schema version |
| `marketAddress` | address | yes | Market contract address |
| `proposedOutcome` | enum | yes | `Yes`, `No`, or `Invalid` |
| `timestamp` | ISO 8601 | yes | Pack creation time (UTC) |
| `sources` | array | yes | List of sources (minimum 1) |
| `sources[].url` | string | yes | Public link |
| `sources[].type` | string | yes | `official`, `social`, `news`, `other` |
| `sources[].archived` | string | no | Link to an archived copy |
| `rationale` | string | yes | Rationale (up to 1000 characters) |
| `resolverAddress` | address | yes | Caller address |

**Hash computation:**
```solidity
evidenceHash = keccak256(abi.encodePacked(jsonString))
```

---

## Accepted Sources

### Source Priority (highest to lowest)

1. **Official sources**
   - Official organization websites
   - Press releases
   - Government registries
   - APIs with verified data

2. **Authoritative media**
   - Major news agencies (Reuters, AP, Bloomberg)
   - Specialized industry publications

3. **Social media**
   - Verified accounts
   - Official organization pages

4. **Secondary sources**
   - Wikipedia (supplementary only)
   - Data aggregators

### Source Requirements

- The source must be publicly accessible
- Attaching an archived copy is recommended (Archive.org, Archive.today)
- The source must explicitly support the claimed outcome
- In case of conflicting sources, official sources take precedence

---

## Contract Interface

### Resolution Functions

```solidity
// Administrator proposes a resolution
function proposeResolve(
    Outcome outcome,
    string calldata evidenceURI,
    bytes32 evidenceHash
) external onlyAdmin;

// User submits a challenge
function submitChallenge(
    Outcome alternativeOutcome,
    string calldata evidenceURI,
    bytes32 evidenceHash,
    string calldata comment
) external;

// Administrator finalizes the resolution
function finalizeResolve(Outcome finalOutcome) external onlyAdmin;

// User redeems winnings
function redeem() external returns (uint256 payout);
```

### Events

```solidity
event ResolutionProposed(
    Outcome indexed outcome,
    string evidenceURI,
    bytes32 evidenceHash,
    uint64 challengeWindowEnds
);

event ChallengeSubmitted(
    address indexed challenger,
    Outcome alternativeOutcome,
    string evidenceURI,
    bytes32 evidenceHash,
    string comment
);

event MarketFinalized(
    Outcome indexed finalOutcome,
    uint256 payoutPerShare,
    uint256 totalChallenges
);
```

### Time Constants

```solidity
uint64 public constant ADMIN_RESOLVE_WINDOW = 6 hours;
uint64 public constant CHALLENGE_WINDOW = 1 hours;
```

---

## Administrator Role

### Authorities

- Propose a resolution after the deadline
- Review challenges
- Make the final decision
- Change the outcome based on new evidence

### Restrictions

- Cannot resolve before the deadline is reached
- Cannot finalize before the challenge window closes
- Cannot change the outcome after finalization
- Must provide evidence

### Transparency

All administrator actions are:
- Recorded on the blockchain
- Accompanied by links to evidence
- Available for public audit

---

## UI Requirements (dev mode)

### Displaying the Proposed Resolution

When the market transitions to the `ResolutionProposed` state, the UI must display:
- The proposed outcome (YES / NO / INVALID)
- A link to the evidence
- Remaining time in the challenge window
- A button to submit a challenge

### Displaying Challenges

A list of all submitted challenges showing:
- Challenger address (truncated)
- Alternative outcome
- Link to evidence
- Comment
- Submission time

### Displaying Finalization

After finalization:
- Final outcome (prominently displayed)
- Whether the outcome was changed
- Number of challenges reviewed
- Redeem button (if the user holds a winning position)

---

## Current Limitations

This resolution mechanism:

1. **Is used only in dev/sandbox mode**
   - Not intended for production
   - Serves for logic testing

2. **Is centralized**
   - A single administrator makes decisions
   - There is no voting mechanism
   - There are no economic incentives for honesty

3. **Has no bonding system**
   - Challenges are free
   - There are no penalties for false challenges

4. **Requires trust**
   - Users must trust the administrator
   - This is explicitly documented

---

## Disclosure

When a market is created, the user is explicitly informed:

> This market is resolved by the protocol administrator.
> The administrator is the final arbiter.
> All decisions and evidence are public.

This information is displayed:
- On the market creation page
- On the market card
- In the modal dialog before the first purchase

---

## Changelog

| Version | Date | Description |
|---------|------|-------------|
| 1.1 | 2024-02 | Added "Unresolved Markets (Invalid)" section |
| 1.0 | 2024-02 | Initial version for dev mode |
