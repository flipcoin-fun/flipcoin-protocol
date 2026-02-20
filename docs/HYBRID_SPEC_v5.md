# FlipCoin v2 — Hybrid CLOB + LMSR Backstop: Contract Specifications

> **Status**: DRAFT v5.2 (audit-ready)
> **Network**: Base (Mainnet target), Base Sepolia (testnet)
> **Collateral**: USDC (6 decimals)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          USER (Browser/SDK)                              │
│                                                                          │
│  Path A (CLOB - gasless):                                                │
│    Sign EIP-712 Order → send to Matching Engine API                      │
│                                                                          │
│  Path B (LMSR - gasless via TradeIntent):                                │
│    Sign EIP-712 TradeIntent → send to Matching Engine API                │
│                                                                          │
│  Path C (LMSR - direct, user pays gas):                                  │
│    Call BackstopRouter.executeTrade() onchain                            │
│                                                                          │
│  Path D (Agent market creation - gasless):                               │
│    Agent signs EIP-712 CreateMarket → relayer submits to Factory         │
└────────────┬────────────────────────────────────────┬───────────────────┘
             │ signed order/intent / meta-tx          │ onchain tx
             ▼                                        │
┌────────────────────────────────┐                    │
│  MATCHING ENGINE (offchain)     │                    │
│                                 │                    │
│  Order Book (bids/asks)         │                    │
│  Match Engine                   │                    │
│  LMSR Quote Comparator          │                    │
│                                 │                    │
│  Routing decision:              │                    │
│   • CLOB match → Exchange       │                    │
│   • LMSR better → BackstopRouter│                    │
│   • Mixed → sequential txs      │                    │
└──────────┬──────────────────────┘                    │
           │ operator tx(s)                            │
           ▼                                           ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                          BASE BLOCKCHAIN                                 │
│                                                                          │
│  ┌──────────────┐  ┌──────────────────┐  ┌───────────────────────────┐  │
│  │   Exchange    │  │  BackstopRouter   │  │         Vault             │  │
│  │ (CLOB settle) │  │ (LMSR entry point)│  │   (USDC internal ledger) │  │
│  │ operator-only │  │ sig-verified      │  │                           │  │
│  └──────┬───────┘  └────────┬─────────┘  └─────────┬─────────────────┘  │
│         │                   │                       │                    │
│         │         ┌─────────┴──────────┐            │                    │
│         │         │    MarketLMSR      │            │                    │
│         │         │  (backstop AMM)    │◄───────────┘                    │
│         │         │  per-market clone  │                                 │
│         │         └────────────────────┘                                 │
│         │                                                                │
│  ┌──────┴────────┐  ┌──────────────┐  ┌──────────────────────────────┐  │
│  │  ShareToken    │  │   Factory     │  │    DelegationRegistry       │  │
│  │  (ERC-1155)    │  │ (creates mkts)│  │  (signer → maker rights)   │  │
│  │  split/merge   │  │  + agent      │  │  scope: Exchange, Factory, │  │
│  │  resolve/redeem│  │    meta-tx    │  │         BackstopRouter      │  │
│  └───────────────┘  └──────────────┘  └──────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

### Variant A Architecture (CONFIRMED)

**Routing is decided by the off-chain matching engine, NOT by an on-chain contract.**

`TradeRouter` from the v1 spec has been **completely removed**. The on-chain contracts have no access to the off-chain order book.

| Path | Initiator | Authorization | On-chain Contract | Gas |
|------|-----------|---------------|-------------------|-----|
| CLOB limit order | User (signs Order) | EIP-712 signature | `Exchange.matchOrders()` | Operator |
| CLOB market order | User (signs Order) | EIP-712 signature | `Exchange.matchOrders()` / `fillOrder()` | Operator |
| LMSR gasless | User (signs TradeIntent) | EIP-712 signature | `BackstopRouter.executeTradeIntent()` | Operator |
| LMSR direct | User (on-chain tx) | msg.sender == trader | `BackstopRouter.executeTrade()` | User |
| Mixed (CLOB + LMSR) | User (signs both) | EIP-712 signatures | 2 sequential txs | Operator |
| Agent market creation | Agent (signs CreateMarket) | EIP-712 + DelegationRegistry | `Factory.createMarketForDelegated()` | Relayer |

**Atomicity of mixed fills**: two sequential txs — a deliberate trade-off. The engine provides a firm quote with CLOB/LMSR split and limit prices. If the second leg fails the limit check → partial fill (expected behavior, UI warns upfront).

---

## 2. Units & Precision Convention (CRITICAL)

```
┌────────────────────────────────────────────────────────────────┐
│ USDC:    1 USDC = 1_000_000 (6 decimals)                       │
│ Shares:  1 share = 1_000_000 (6 decimals, $1 face value)       │
│ Price:   basis points, 1-9999 (5000 = $0.50)                   │
│ Fee:     basis points, 0-500 (100 = 1%)                         │
│                                                                  │
│ Invariant: 1 winning share always redeems for exactly 1 USDC    │
│            (1_000_000 units → 1_000_000 units)                   │
└────────────────────────────────────────────────────────────────┘
```

### Order Amount Semantics

```
BUY order (buying shares for USDC):
  makerAmount = USDC to spend (6 dec)
  takerAmount = shares to receive (6 dec)
  price = makerAmount / takerAmount
  quantity = takerAmount (shares)

SELL order (selling shares for USDC):
  makerAmount = shares to sell (6 dec)
  takerAmount = USDC to receive (6 dec)
  price = takerAmount / makerAmount
  quantity = makerAmount (shares)
```

### fillAmount Definition

**`fillAmount` is always in shares (quantity).**

```
For BUY order:
  fillAmount = shares to fill (≤ takerAmount)
  filledUsdc = mulDivCeil(fillAmount, makerAmount, takerAmount)
  → buyer pays AT MOST signed price

For SELL order:
  fillAmount = shares to fill (≤ makerAmount)
  filledUsdc = mulDivFloor(fillAmount, takerAmount, makerAmount)
  → seller gets AT LEAST signed price
```

### Fee Rounding

```
Fee is always rounded DOWN (floor). On small fills fee CAN round to 0.
This is an accepted behavior:
  - fillAmount = 1 (0.000001 share), fee formula produces < 1 unit → fee = 0
  - Acceptable: micro-fills are not economically interesting
  - Minimum fillAmount check recommended: >= 1000 (0.001 share)
```

---

## 3. Contract: ShareToken (ERC-1155 with Supply Tracking)

### Purpose
Each market creates 2 tokens (YES / NO). 1 USDC → split → 1 YES + 1 NO. On resolution, winning tokens redeem for $1.

### Key Design Decisions

1. **Extends ERC1155Supply** (OZ) — per-tokenId `totalSupply()` tracking
2. **Minimal authorized caller surface**: only `Exchange` and `MarketLMSR` clones
3. **Resolution lives here** (two-phase + auto-invalid)
4. **Purity**: split/merge only mint/burn tokens. Caller handles Vault separately.

### Authorized Callers (MINIMAL surface)

```
WHO can call splitPosition / mergePositions:
  ✅ Exchange        — for MINT/MERGE settlement modes
  ✅ MarketLMSR clones — for backstop trades

WHO CANNOT:
  ❌ BackstopRouter  — calls MarketLMSR, which calls ShareToken
  ❌ Factory         — only prepareCondition + addAuthorizedCaller
  ❌ Users           — via Exchange (CLOB) or BackstopRouter (LMSR)

Each MarketLMSR clone authorized individually by Factory at creation.
```

### Mint/Burn Paths (EXHAUSTIVE — no other paths exist)

```
PRE-RESOLUTION:
  MINT:  splitPosition  — mints equal YES + NO → caller (authorized only)
  BURN:  mergePositions — burns equal YES + NO from holder (authorized only)

  Checks inside splitPosition:
    require(authorizedCallers[msg.sender], "not authorized")
    require(conditions[conditionId].prepared, "condition not prepared")
    require(resolutions[conditionId].status == Open, "not open")
    → _mint(to, yesTokenId, amount, "")
    → _mint(to, noTokenId, amount, "")

  Checks inside mergePositions:
    require(authorizedCallers[msg.sender], "not authorized")
    require(conditions[conditionId].prepared, "condition not prepared")
    require(resolutions[conditionId].status == Open, "not open")
    → _burn(from, yesTokenId, amount)
    → _burn(from, noTokenId, amount)

POST-RESOLUTION:
  BURN:  redeemPositions — burns winning shares, releases USDC via Vault
    require(resolutions[conditionId].status == Resolved)
    → Burns winning tokens only (or both if Invalid)
    → No mint path post-resolution

INVARIANT: totalSupply(yesTokenId) == totalSupply(noTokenId) pre-resolution
```

### Interface

```solidity
contract ShareToken is ERC1155Supply {

    address public admin;
    address public factory;          // Can add authorized callers
    address public vault;
    Exchange public exchange;        // For pauseCondition callbacks

    mapping(address => bool) public authorizedCallers;

    struct Condition {
        bytes32 conditionId;
        address oracle;
        bytes32 questionId;
        address collateral;
        uint256 yesTokenId;
        uint256 noTokenId;
        uint64 deadline;
        bool prepared;
    }

    mapping(bytes32 => Condition) public conditions;

    enum Outcome { None, Yes, No, Invalid }
    enum ResolutionStatus { Open, Pending, Resolved }

    struct Resolution {
        ResolutionStatus status;
        Outcome proposedOutcome;
        Outcome finalOutcome;
        uint64 proposedAt;
        uint64 resolvedAt;
        bool disputed;
        uint256 payoutPerShare;
    }

    mapping(bytes32 => Resolution) public resolutions;

    uint64 public constant DISPUTE_PERIOD = 24 hours;
    uint64 public constant ADMIN_RESOLVE_WINDOW = 6 hours;

    // Events
    event ConditionPrepared(bytes32 indexed conditionId, address oracle, uint256 yesTokenId, uint256 noTokenId, uint64 deadline);
    event AuthorizedCallerAdded(address indexed caller);
    event AuthorizedCallerRemoved(address indexed caller);
    event PositionSplit(bytes32 indexed conditionId, address indexed caller, address indexed to, uint256 amount);
    event PositionMerged(bytes32 indexed conditionId, address indexed caller, address indexed from, uint256 amount);
    event ResolutionProposed(bytes32 indexed conditionId, Outcome outcome, uint64 proposedAt, uint64 finalizeAfter);
    event ResolutionDisputed(bytes32 indexed conditionId, address indexed challenger, Outcome proposedOutcome);
    event ResolutionFinalized(bytes32 indexed conditionId, Outcome outcome, uint256 payoutPerShare);
    event MarkedAsInvalid(bytes32 indexed conditionId, address indexed caller, uint64 markedAt);
    event PositionRedeemed(bytes32 indexed conditionId, address indexed user, uint256 sharesBurned, uint256 usdcPayout);

    // Token ID derivation
    function getConditionId(address oracle, bytes32 questionId) public pure returns (bytes32);
    function getTokenIds(bytes32 conditionId, address collateral) public pure returns (uint256 yesTokenId, uint256 noTokenId);

    // Admin
    function addAuthorizedCaller(address caller) external;    // onlyAdmin or onlyFactory
    function removeAuthorizedCaller(address caller) external;  // onlyAdmin

    // Condition lifecycle
    function prepareCondition(address oracle, bytes32 questionId, address collateral, uint64 deadline)
        external returns (bytes32 conditionId); // onlyAdmin or onlyFactory

    // Split & Merge
    function splitPosition(bytes32 conditionId, address to, uint256 amount) external;    // onlyAuthorizedCaller, whenOpen
    function mergePositions(bytes32 conditionId, address from, uint256 amount) external; // onlyAuthorizedCaller, whenOpen

    // Resolution
    function proposeResolution(bytes32 conditionId, Outcome outcome) external; // onlyOracle, after deadline
    function disputeResolution(bytes32 conditionId) external;                   // onlyShareholder, during DISPUTE_PERIOD
    function finalizeResolution(bytes32 conditionId) external;                  // anyone, after DISPUTE_PERIOD
    function markAsInvalid(bytes32 conditionId) external;                       // anyone, see §3.1

    // Redemption
    function redeemPositions(bytes32 conditionId) external; // anyone with tokens
}
```

### 3.1 markAsInvalid — Full Semantics

**Preconditions** (ALL must be true):
```
1. resolutions[conditionId].status == Open
2. block.timestamp > conditions[conditionId].deadline + ADMIN_RESOLVE_WINDOW (6h)
3. conditions[conditionId].prepared == true
```

**Who can call**: Anyone. Safety valve, not privileged.

**Effects**:
```
1. status = Resolved (skips Pending — no dispute period)
2. finalOutcome = Invalid
3. resolvedAt = block.timestamp
4. payoutPerShare = 500_000 (hardcoded: 50 cents per share)
5. exchange.pauseCondition(conditionId) — FINAL
6. emit MarkedAsInvalid + emit ResolutionFinalized
```

**Payout for Invalid = 500_000 (hardcoded)**:
```
Since yesSupply == noSupply (pre-resolution invariant):
  Holder of 1 YES + 1 NO → redeems 500K + 500K = 1_000_000 = full refund
  Holder of only 1 YES → redeems 500_000 (50 cents)
  Holder of only 1 NO → redeems 500_000 (50 cents)

Hardcoded is simpler, no rounding, no oracle dependency.
splitReserve always covers: totalYesSupply * 500K + totalNoSupply * 500K
  = 2 * totalYesSupply * 500K = totalYesSupply * 1_000_000 = splitReserve ✓
```

**Finality**: IRREVERSIBLE. No un-invalid path. No dispute period.

---

## 4. Contract: Exchange (CLOB Settlement)

### EIP-712 Domain

```solidity
constructor(...) {
    DOMAIN_SEPARATOR = keccak256(abi.encode(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak256("FlipCoinExchange"),
        keccak256("1"),
        block.chainid,
        address(this)
    ));
}
```

### Order Structure

```solidity
struct Order {
    uint256 salt;
    address maker;
    address signer;         // == maker or delegated via DelegationRegistry
    address taker;          // address(0) for any
    uint256 tokenId;
    uint256 makerAmount;
    uint256 takerAmount;
    uint256 expiration;     // 0 = no expiry
    uint256 nonce;          // bulk cancel: orders with nonce < nonces[maker] invalid
    uint256 maxFeeBps;      // MAX fee user accepts (see §4.1)
    Side side;
    SignatureType sigType;
}

bytes32 constant ORDER_TYPEHASH = keccak256(
    "Order(uint256 salt,address maker,address signer,address taker,"
    "uint256 tokenId,uint256 makerAmount,uint256 takerAmount,"
    "uint256 expiration,uint256 nonce,uint256 maxFeeBps,"
    "uint8 side,uint8 signatureType)"
);
```

### 4.1 Fee Model: maxFeeBps (CHANGED from v4)

```
CHANGE: feeRateBps → maxFeeBps

Old (v4): require(order.feeRateBps == protocolFeeBps)
  Problem: any fee change invalidates ALL open orders. Protocol cannot safely lower fees.

New (v5): require(totalFeeBps <= order.maxFeeBps)
  where totalFeeBps = protocolFeeBps + creatorFeeBps[conditionId]

  - maxFeeBps is a CEILING on TOTAL fee (protocol + creator combined)
  - User signs the MAX total fee they accept
  - Actual fee = totalFeeBps (always ≤ maxFeeBps)
  - Protocol can LOWER protocolFeeBps → existing orders remain valid
  - Protocol RAISES → only orders where totalFeeBps still ≤ maxFeeBps survive

  Example (current rates: protocol 50 + creator 50 = total 100):
    User signs maxFeeBps = 200 (2%)
    Total = 100 (1%) → user pays 1% ✓
    Protocol raises to 100 → total = 150 (1.5%) → user pays 1.5% ✓
    Protocol raises to 200 → total = 250 (2.5%) → REVERTS (250 > 200) ✓

  CRITICAL: maxFeeBps covers BOTH protocol AND creator fees.
  This is what the user actually cares about: total cost.
  Splitting into separate ceilings would be confusing and unnecessary.

Fee formula:
  fee = totalFeeBps * min(priceBps, BPS - priceBps) * fillAmount / BPS / BPS
  where totalFeeBps = protocolFeeBps + creatorFeeBps[conditionId]
  Rounding: floor. On micro-fills fee CAN be 0 (accepted).
```

### Fee Rates

```
┌────────────────────────────────────────────────────────────────┐
│ protocolFeeBps    = 50  (0.5% to protocol)                      │
│ creatorFeeBps     = 50  (0.5% to market creator, per condition) │
│ totalFeeBps       = 100 (1.0% total, per condition)             │
│                                                                  │
│ totalFeeBps = protocolFeeBps + creatorFeeBps[conditionId]       │
│                                                                  │
│ Both sides pay same fee:                                         │
│   fee = totalFeeBps * min(price, BPS-price) * fill / BPS²       │
│   makerFee = fee, takerFee = fee                                │
│                                                                  │
│ Fee split (from total = makerFee + takerFee):                    │
│   protocolShare = total * protocolFeeBps / totalFeeBps          │
│   creatorShare  = total - protocolShare                          │
│                                                                  │
│ maxFeeBps in Order: user signs CEILING on totalFeeBps.          │
│   require(totalFeeBps <= order.maxFeeBps)                        │
│   Typical: user signs maxFeeBps = 200 (2%) for headroom.        │
│                                                                  │
│ Example at price $0.50, 100 shares:                              │
│   min(5000, 5000) = 5000                                         │
│   fee = 100 * 5000 * 100_000_000 / 10000 / 10000                │
│       = 500_000 (0.5 USDC per side)                              │
│   totalFee = 1_000_000 (1 USDC)                                 │
│   protocolShare = 500_000, creatorShare = 500_000                │
│                                                                  │
│ Example at price $0.90, 100 shares:                              │
│   min(9000, 1000) = 1000                                         │
│   fee = 100 * 1000 * 100_000_000 / 10000 / 10000                │
│       = 100_000 (0.1 USDC per side)                              │
│   totalFee = 200_000 (0.2 USDC)                                 │
│   protocolShare = 100_000, creatorShare = 100_000                │
└────────────────────────────────────────────────────────────────┘
```

### Interface

```solidity
contract Exchange {

    address public admin;
    address public operator;
    ShareToken public shareToken;
    address public vault;
    DelegationRegistry public delegationRegistry;
    address public factory;

    bool public paused;

    uint256 public protocolFeeBps;           // 50 = 0.5%
    address public protocolFeeRecipient;

    // IMMUTABLE creator fee (per condition)
    mapping(bytes32 => address) public creatorFeeRecipient;
    mapping(bytes32 => uint256) public creatorFeeBps;       // 50 = 0.5%
    mapping(bytes32 => bool)    public creatorFeeSet;

    // Fee accumulators
    uint256 public protocolFeesAccumulated;
    mapping(bytes32 => uint256) public creatorFeesAccumulated;

    // Order state
    mapping(bytes32 => uint256) public ordersFilled;
    mapping(bytes32 => bool) public ordersCancelled;
    mapping(address => uint256) public nonces;

    // Token registry
    mapping(uint256 => uint256) public complements;
    mapping(uint256 => bytes32) public tokenConditions;
    mapping(bytes32 => bool) public registeredConditions;

    // Per-condition pause
    // When paused: ✅ cancel/bumpNonce, ❌ matchOrders/fillOrder
    mapping(bytes32 => bool) public conditionPaused;

    bytes32 public immutable DOMAIN_SEPARATOR;

    enum MatchType { COMPLEMENTARY, MINT, MERGE }
    enum Side { BUY, SELL }
    enum SignatureType { EOA, EIP1271 }

    // Events
    event OrderFilled(bytes32 indexed orderHash, address indexed maker, address indexed taker,
        uint256 tokenId, uint256 fillAmount, uint256 usdcAmount, uint256 fee, Side side);
    event OrdersMatched(bytes32 indexed takerOrderHash, bytes32 indexed makerOrderHash,
        MatchType matchType, uint256 fillAmount);
    event OrderCancelled(bytes32 indexed orderHash, address indexed maker);
    event NonceBumped(address indexed user, uint256 oldNonce, uint256 newNonce);
    event ConditionPaused(bytes32 indexed conditionId);
    event ConditionUnpaused(bytes32 indexed conditionId);

    // Admin / Factory
    function registerToken(uint256 yesTokenId, uint256 noTokenId, bytes32 conditionId) external; // onlyFactory
    function setCreatorFee(bytes32 conditionId, address creator, uint256 feeBps) external; // ONLY Factory, ONCE
    function setOperator(address) external; // onlyAdmin
    function setProtocolFeeBps(uint256) external; // onlyAdmin, max 500
    function pause() external; // onlyAdmin
    function unpause() external; // onlyAdmin
    function pauseCondition(bytes32) external; // onlyShareToken or onlyAdmin
    function unpauseCondition(bytes32) external; // onlyShareToken or onlyAdmin

    // Settlement
    function matchOrders(Order memory takerOrder, Order[] memory makerOrders,
        uint256 takerFillAmount, uint256[] memory makerFillAmounts,
        bytes memory takerSig, bytes[] memory makerSigs
    ) external; // onlyOperator, nonReentrant, whenNotPaused, whenConditionNotPaused

    function fillOrder(Order memory order, uint256 fillAmount, bytes memory sig
    ) external; // onlyOperator, nonReentrant, whenNotPaused, whenConditionNotPaused

    // User self-service (ALLOWED even when paused)
    function cancelOrder(Order memory order) external;
    function bumpNonce(uint256 newNonce) external;

    // Fee withdrawal
    function withdrawProtocolFees() external; // onlyAdmin
    function withdrawCreatorFees(bytes32 conditionId) external; // ONLY creatorFeeRecipient

    // Views
    function getOrderStatus(bytes32 orderHash) external view returns (uint256 filled, bool cancelled, bool expired);
    function hashOrder(Order memory order) public view returns (bytes32);
}
```

### 4.2 Order Validation Checklist (in matchOrders/fillOrder)

```solidity
function _validateOrder(Order memory order, bytes memory sig, uint256 fillAmount) internal {
    bytes32 orderHash = hashOrder(order);

    // 1. Signature
    _validateSigner(order, sig); // see §4.3

    // 2. Not cancelled
    require(!ordersCancelled[orderHash], "cancelled");

    // 3. Nonce check (bulk cancel)
    require(order.nonce >= nonces[order.maker], "nonce too low");

    // 4. Expiration
    require(order.expiration == 0 || block.timestamp <= order.expiration, "expired");

    // 5. Fee ceiling
    uint256 totalFeeBps = protocolFeeBps + creatorFeeBps[tokenConditions[order.tokenId]];
    require(totalFeeBps <= order.maxFeeBps, "fee exceeds max");

    // 6. Fill capacity
    uint256 remaining = _orderCapacity(order) - ordersFilled[orderHash];
    require(fillAmount <= remaining, "overfill");

    // 7. Token registered
    bytes32 conditionId = tokenConditions[order.tokenId];
    require(registeredConditions[conditionId], "unknown token");

    // 8. Condition not paused
    require(!conditionPaused[conditionId], "condition paused");

    // 9. Taker restriction
    // (checked in matchOrders: if order.taker != address(0), counterparty must match)

    // 10. Record fill
    ordersFilled[orderHash] += fillAmount;
}
```

### 4.3 Signer Validation

```solidity
function _validateSigner(Order memory order, bytes memory signature) internal {
    bytes32 digest = _hashTypedDataV4(hashOrder(order));

    if (order.sigType == SignatureType.EOA) {
        address recovered = ECDSA.recover(digest, signature);
        // ECDSA.recover: low-s check, v check, reverts on address(0)

        if (order.signer == order.maker) {
            require(recovered == order.maker, "bad sig");
        } else {
            require(recovered == order.signer, "bad sig");
            bytes32 conditionId = tokenConditions[order.tokenId];
            require(delegationRegistry.isAuthorized(
                order.maker, order.signer, address(this), conditionId
            ), "not delegated");
            // Record spend
            uint256 notional = order.side == Side.BUY ? order.makerAmount : order.takerAmount;
            delegationRegistry.recordSpend(order.maker, order.signer, notional);
        }
    } else {
        // EIP-1271: call isValidSignature on order.signer contract
        // signer MUST be the contract that implements IERC1271
        // maker is the logical owner — delegation check applies:
        if (order.signer != order.maker) {
            bytes32 conditionId = tokenConditions[order.tokenId];
            require(delegationRegistry.isAuthorized(
                order.maker, order.signer, address(this), conditionId
            ), "not delegated");
        }
        (bool ok, bytes memory result) = order.signer.staticcall(
            abi.encodeWithSelector(IERC1271.isValidSignature.selector, digest, signature)
        );
        require(ok && abi.decode(result, (bytes4)) == IERC1271.isValidSignature.selector, "EIP1271 fail");
    }
}
```

### 4.4 ConditionId Validation in MINT/MERGE

```solidity
// In matchOrders, when determining MatchType:
function _deriveMatchType(Order memory taker, Order memory maker) internal view returns (MatchType) {
    bytes32 takerCondition = tokenConditions[taker.tokenId];
    bytes32 makerCondition = tokenConditions[maker.tokenId];
    require(takerCondition == makerCondition, "condition mismatch");

    if (taker.side == Side.BUY && maker.side == Side.SELL && taker.tokenId == maker.tokenId) {
        return MatchType.COMPLEMENTARY;
    }
    if (taker.side == Side.BUY && maker.side == Side.BUY) {
        require(complements[taker.tokenId] == maker.tokenId, "not complements");
        return MatchType.MINT;
    }
    if (taker.side == Side.SELL && maker.side == Side.SELL) {
        require(complements[taker.tokenId] == maker.tokenId, "not complements");
        return MatchType.MERGE;
    }
    revert("invalid match");
}
```

### 4.5 Immutable creatorFeeRecipient

```solidity
function setCreatorFee(bytes32 conditionId, address creator, uint256 feeBps) external {
    require(msg.sender == factory, "only factory");
    require(!creatorFeeSet[conditionId], "already set");
    require(creator != address(0), "zero creator");
    require(feeBps <= 500, "fee too high");

    creatorFeeRecipient[conditionId] = creator;
    creatorFeeBps[conditionId] = feeBps;
    creatorFeeSet[conditionId] = true;
    // No update function exists. No admin override. IMMUTABLE.
}
```

---

## 5. Contract: DelegationRegistry

### Scope Model

**Scope = contract address**:

| Scope | Delegate can | Limits | recordSpend caller |
|-------|-------------|--------|-------------------|
| Exchange | Sign CLOB orders | maxNotionalPerDay | Exchange only |
| Factory | Sign CreateMarket EIP-712 | maxMarketsPerDay, maxSeedPerDay | Factory only |
| BackstopRouter | Sign TradeIntent EIP-712 | maxNotionalPerDay | BackstopRouter only |
| address(0) | ALL of the above | Per-scope limits still apply | Any authorizedContract |

**tokenScope = conditionId** (not tokenId): each market has 2 tokens, conditionId covers both.

### Interface

```solidity
contract DelegationRegistry {

    struct Delegation {
        bool active;
        address scope;
        uint256 tokenScope;         // conditionId as uint256, or 0 for any
        uint256 maxNotionalPerDay;
        uint256 maxMarketsPerDay;
        uint256 spentToday;
        uint256 marketsCreatedToday;
        uint64 dayStart;
        uint64 expiresAt;
    }

    mapping(address => mapping(address => Delegation)) public delegations;
    mapping(address => bool) public authorizedContracts; // Exchange, Factory, BackstopRouter

    // Events
    event DelegationSet(address indexed owner, address indexed signer, address scope,
        uint256 tokenScope, uint256 maxNotionalPerDay, uint256 maxMarketsPerDay, uint64 expiresAt);
    event DelegationRevoked(address indexed owner, address indexed signer);
    event SpendRecorded(address indexed owner, address indexed signer, address indexed caller, uint256 amount);
    event MarketCreationRecorded(address indexed owner, address indexed signer, address indexed caller);

    function setDelegation(address signer, address scope, uint256 tokenScope,
        uint256 maxNotionalPerDay, uint256 maxMarketsPerDay, uint64 expiresAt) external;
    function revokeDelegation(address signer) external;
    function isAuthorized(address owner, address signer, address callingContract, bytes32 conditionId)
        external view returns (bool);
    function recordSpend(address owner, address signer, uint256 usdcAmount) external; // onlyAuthorizedContract
    function recordMarketCreation(address owner, address signer) external; // onlyAuthorizedContract
}
```

### recordSpend Protection

```solidity
function recordSpend(address owner, address signer, uint256 usdcAmount) external {
    require(authorizedContracts[msg.sender], "not authorized");
    Delegation storage d = delegations[owner][signer];
    require(d.active, "not active");
    require(d.scope == address(0) || d.scope == msg.sender, "scope mismatch");

    if (block.timestamp >= d.dayStart + 24 hours) {
        d.dayStart = uint64(block.timestamp);
        d.spentToday = 0;
    }
    if (d.maxNotionalPerDay > 0) {
        require(d.spentToday + usdcAmount <= d.maxNotionalPerDay, "daily limit");
    }
    d.spentToday += usdcAmount;
    emit SpendRecorded(owner, signer, msg.sender, usdcAmount);
}
```

---

## 6. Contract: MarketLMSR (Backstop AMM)

### LMSR + ERC-1155 Inventory Model

```
BUY YES (user wants 100 YES, LMSR prices at 52 USDC):
  1. Vault: user -= 52 USDC → LMSR += 52 USDC
  2. ShareToken.splitPosition(conditionId, lmsr, 100) → LMSR gets +100 YES +100 NO
  3. Transfer 100 YES → user
  4. LMSR keeps 100 NO inventory
  5. qYes += 100

SELL YES (user sells 100 YES, LMSR pays 48 USDC):
  1. BackstopRouter transfers 100 YES from user → LMSR
     (BackstopRouter has setApprovalForAll from user, see §7.1.1)
  2. LMSR merges 100 YES + 100 NO → Vault: splitReserve -= 100, LMSR += 100
  3. Vault: LMSR -= 48 → user += 48
  4. qYes -= 100

INVARIANT: split/merge always paired → yesSupply == noSupply
```

### Interface (unchanged from v4, + IERC1155Receiver)

```solidity
contract MarketLMSR is IERC1155Receiver, ERC165 {
    // Config set once by Factory
    address public creator;
    bytes32 public conditionId;
    // ... (see v4 §6 for full state)
    // NOTE: Inherits ERC165 for supportsInterface(IERC1155Receiver) — required by ERC-1155 spec.

    function buyYes(address buyer, uint256 amountUsdc, uint256 minSharesOut) external returns (uint256);
    function buyNo(address buyer, uint256 amountUsdc, uint256 minSharesOut) external returns (uint256);
    function sellYes(address seller, uint256 shares, uint256 minAmountOut) external returns (uint256);
    function sellNo(address seller, uint256 shares, uint256 minAmountOut) external returns (uint256);

    function quoteYes(uint256 amountUsdc) external view returns (uint256);
    function quoteNo(uint256 amountUsdc) external view returns (uint256);
    function quoteSellYes(uint256 shares) external view returns (uint256);
    function quoteSellNo(uint256 shares) external view returns (uint256);
    function getPrices() external view returns (uint256 priceYesBps, uint256 priceNoBps);

    /// @notice Total fee in basis points (creator + protocol combined)
    /// @dev Used by BackstopRouter to check against TradeIntent.maxFeeBps
    function totalFeeBps() external view returns (uint256) {
        return uint256(creatorFeeBps) + uint256(protocolFeeBps);
    }

    function withdrawSeedAndFees() external; // onlyCreator, after resolution

    // === IERC1155Receiver (REQUIRED) ===
    // MarketLMSR must implement IERC1155Receiver because sell flow uses
    // ShareToken.safeTransferFrom(user, lmsrClone, tokenId, amount, "")
    // which calls onERC1155Received on the recipient.
    // Without this, all sell operations will revert.
    //
    // Implementation: accept only from known ShareToken, only expected tokenIds.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external view returns (bytes4) {
        require(msg.sender == address(shareToken), "unknown token");
        return IERC1155Receiver.onERC1155Received.selector;
    }
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external view returns (bytes4) {
        require(msg.sender == address(shareToken), "unknown token");
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }
}
```

---

## 7. Contract: BackstopRouter (with TradeIntent EIP-712)

### Purpose
Entry point for LMSR trades. Now supports **signed TradeIntent** — operator is just relayer, not delegatee.

### 7.1 TradeIntent EIP-712 (NEW in v5 — fixes operator-as-delegatee vulnerability)

```
PROBLEM (v4):
  operator could call buyFromLMSR(buyer=alice, amountUsdc=X, minSharesOut=0)
  with ANY parameters, including minSharesOut=0 (max slippage).
  Daily limit restricts total $ but NOT execution quality.
  Stolen operator key = arbitrary trades for all delegated users.

SOLUTION (v5):
  User signs TradeIntent with ALL parameters (including minOut).
  Operator becomes pure relayer — submits the signed intent.
  BackstopRouter verifies signature onchain.
```

### EIP-712 Domain

```solidity
bytes32 public immutable DOMAIN_SEPARATOR;
// name = "FlipCoinBackstopRouter", version = "1", chainId, verifyingContract
```

### TradeIntent Structure

```solidity
struct TradeIntent {
    address trader;          // Funds owner
    address signer;          // == trader, or delegated via DelegationRegistry
    bytes32 conditionId;
    Side side;               // YES or NO
    bool isBuy;              // true = buy shares, false = sell shares
    uint256 amount;          // USDC if buy, shares if sell
    uint256 minOut;          // min shares if buy, min USDC if sell (slippage protection)
    uint256 deadline;        // Unix timestamp
    uint256 nonce;           // Sequential per-signer
    uint256 maxFeeBps;       // MAX total fee user accepts
}

bytes32 constant TRADE_INTENT_TYPEHASH = keccak256(
    "TradeIntent(address trader,address signer,bytes32 conditionId,"
    "uint8 side,bool isBuy,uint256 amount,uint256 minOut,"
    "uint256 deadline,uint256 nonce,uint256 maxFeeBps)"
);
```

### Interface

```solidity
contract BackstopRouter is ReentrancyGuard {  // OZ ReentrancyGuard for CEI defense-in-depth

    address public vault;
    ShareToken public shareToken;
    DelegationRegistry public delegationRegistry;

    bytes32 public immutable DOMAIN_SEPARATOR;

    mapping(bytes32 => address) public backstops;       // conditionId => MarketLMSR
    mapping(address => uint256) public nonces;           // signer => next nonce
    mapping(bytes32 => bool) public usedIntentHashes;    // replay protection

    // Events
    event BackstopRegistered(bytes32 indexed conditionId, address indexed backstop);
    event BackstopTrade(bytes32 indexed conditionId, address indexed trader, Side side,
        bool isBuy, uint256 amountUsdc, uint256 shares, bytes32 intentHash);
    //   ↑ amountUsdc is ALWAYS USDC, shares is ALWAYS shares — regardless of isBuy.
    //   Emit normalizes: BUY → amountUsdc=intent.amount, shares=result.
    //                     SELL → amountUsdc=result, shares=intent.amount. See §7.4 step 9.
    event IntentCancelled(bytes32 indexed intentHash, address indexed trader);
    event NonceBumped(address indexed signer, uint256 oldNonce, uint256 newNonce);

    // === Gasless (signed intent, operator relays) ===

    /// @notice Execute a signed TradeIntent (operator is relayer, not counterparty)
    /// @dev CEI-compliant + nonReentrant. See §7.4 for full validation flow.
    function executeTradeIntent(
        TradeIntent memory intent,
        bytes memory signature
    ) external nonReentrant returns (uint256 result); // anyone can call (typically operator)

    // === Direct (user pays gas) ===

    /// @notice Direct trade (msg.sender == trader, no signature needed)
    /// @dev Also nonReentrant — same external interaction surface
    function executeTrade(
        bytes32 conditionId,
        Side side,
        bool isBuy,
        uint256 amount,
        uint256 minOut
    ) external nonReentrant returns (uint256 result);

    // === User self-service ===
    function cancelIntent(TradeIntent memory intent) external; // trader or signer
    function bumpNonce(uint256 newNonce) external;

    // === Views ===
    function quoteBuy(bytes32 conditionId, Side side, uint256 amountUsdc)
        external view returns (uint256 sharesOut, uint256 avgPriceBps);
    function quoteSell(bytes32 conditionId, Side side, uint256 shares)
        external view returns (uint256 amountOut, uint256 avgPriceBps);

    // Factory
    function registerBackstop(bytes32 conditionId, address backstop) external; // onlyFactory
}
```

### 7.1.1 ERC-1155 Approval Model for LMSR Sell

```
PROBLEM:
  LMSR sell requires transferring YES/NO shares from user to MarketLMSR.
  ERC-1155 requires setApprovalForAll(operator, true) for safeTransferFrom.
  If each MarketLMSR clone is the operator → per-market approvals (BAD UX).

SOLUTION: BackstopRouter is the SINGLE approval target for LMSR sells.

  User does ONE-TIME: ShareToken.setApprovalForAll(backstopRouter, true)

  Sell flow in BackstopRouter._executeSell():
    1. BackstopRouter calls ShareToken.safeTransferFrom(user, lmsrClone, tokenId, amount)
       → Works because user approved BackstopRouter (not each clone)
    2. MarketLMSR processes the sell (merge, pay USDC)

  This means BackstopRouter needs ShareToken approval but does NOT need
  to be an authorizedCaller (split/merge rights). It only transfers existing tokens.

  ERC-1155 approvals summary:
    ShareToken.setApprovalForAll(exchange, true)        — for CLOB selling
    ShareToken.setApprovalForAll(backstopRouter, true)  — for LMSR selling
    Vault.approveMarket(backstopRouter, MAX_UINT)       — for LMSR buying (USDC)

  Total: 3 one-time approvals. NO per-market approvals.
```

### 7.2 Nonce & Replay Model (STRICT SEQUENTIAL)

```
Replay protection is TWO-LAYER (same model as Factory):

Layer 1 — Nonce (STRICT sequential, primary):
  mapping(address => uint256) public nonces;  // signer → next expected nonce
  require(intent.nonce == nonces[intent.signer], "bad nonce");
  nonces[intent.signer]++;

  Strict == (not >=) means:
    - Each nonce used exactly once
    - Cannot skip nonces
    - bumpNonce(newNonce) sets nonces[signer] = newNonce, invalidating all < newNonce

  CEI note: nonce++ and usedIntentHashes[hash]=true are committed BEFORE
  external calls (_executeBuy/_executeSell). See §7.4 step 6.
  If the external call reverts, the whole tx rolls back — nonce stays unchanged.

Layer 2 — intentHash (secondary, for cancel):
  mapping(bytes32 => bool) public usedIntentHashes;
  Used for: (a) preventing double-execution, (b) implementing cancelIntent.

  cancelIntent marks usedIntentHashes[hash] = true → intent becomes non-executable.
  This is the ONLY mechanism for single-intent cancellation.
  bumpNonce is for bulk cancellation (all intents with nonce < newNonce).

  IMPORTANT: cancelIntent does NOT block other intents at the same nonce.
  If intent A (nonce=5) is cancelled via cancelIntent, a NEW intent B (nonce=5)
  with different parameters can still be submitted — it will have a different
  intentHash and pass both nonce and hash checks. This is by design:
  cancelIntent is per-intent, not per-nonce-slot.

Source of truth: nonce is PRIMARY (determines ordering, enables bulk cancel).
intentHash map is SECONDARY (single-cancel + defense-in-depth).
```

### 7.3 cancelIntent

```solidity
function cancelIntent(TradeIntent memory intent) external {
    require(msg.sender == intent.trader || msg.sender == intent.signer, "not authorized");
    bytes32 intentHash = _hashIntent(intent);
    require(!usedIntentHashes[intentHash], "already used/cancelled");
    usedIntentHashes[intentHash] = true;
    emit IntentCancelled(intentHash, intent.trader);
}

function bumpNonce(uint256 newNonce) external {
    require(newNonce > nonces[msg.sender], "nonce not increased");
    uint256 oldNonce = nonces[msg.sender];
    nonces[msg.sender] = newNonce;
    emit NonceBumped(msg.sender, oldNonce, newNonce);
}
```

### 7.4 executeTradeIntent Validation (CEI-compliant)

```
SECURITY NOTE: Checks-Effects-Interactions (CEI) pattern.

All state mutations (nonce++, usedIntentHashes) happen BEFORE external calls
(_executeBuy/_executeSell which call MarketLMSR + ShareToken + Vault).

Why: _executeSell calls ShareToken.safeTransferFrom → MarketLMSR.onERC1155Received,
which is a potential reentrancy vector. By committing nonce/hash before the external
call, a reentrant call to executeTradeIntent would fail on "bad nonce" check.

Additionally, nonReentrant modifier is REQUIRED as defense-in-depth
(protects executeTrade path and any future entry points).

If _executeBuy/_executeSell reverts, nonce++ and usedHash rollback with the tx — safe.
```

```solidity
function executeTradeIntent(TradeIntent memory intent, bytes memory sig)
    external
    nonReentrant          // defense-in-depth (OZ ReentrancyGuard)
    returns (uint256)
{
    // ── CHECKS ──

    // 1. Deadline
    require(block.timestamp <= intent.deadline, "expired");

    // 2. Nonce (STRICT sequential)
    require(intent.nonce == nonces[intent.signer], "bad nonce");

    // 3. Replay (secondary check + cancel support)
    bytes32 intentHash = _hashIntent(intent);
    require(!usedIntentHashes[intentHash], "already used or cancelled");

    // 4. Signature (OZ ECDSA.recover)
    bytes32 digest = _hashTypedDataV4(intentHash);
    address recovered = ECDSA.recover(digest, sig);

    if (intent.signer == intent.trader) {
        require(recovered == intent.trader, "bad sig");
    } else {
        require(recovered == intent.signer, "bad sig");
        require(delegationRegistry.isAuthorized(
            intent.trader, intent.signer, address(this), intent.conditionId
        ), "not delegated");
    }

    // 5. Fee check
    address lmsrAddr = backstops[intent.conditionId];
    require(lmsrAddr != address(0), "no backstop");
    uint256 lmsrTotalFee = MarketLMSR(lmsrAddr).totalFeeBps();
    require(lmsrTotalFee <= intent.maxFeeBps, "fee exceeds max");

    // ── EFFECTS (before external calls) ──

    // 6. Commit nonce + replay hash
    nonces[intent.signer]++;
    usedIntentHashes[intentHash] = true;

    // ── INTERACTIONS ──

    // 7. Execute via MarketLMSR (external calls: Vault, ShareToken, MarketLMSR)
    uint256 result;
    if (intent.isBuy) {
        result = _executeBuy(intent);
    } else {
        result = _executeSell(intent);
    }

    // 8. Record delegation spend (USDC notional, see §7.5)
    //    This is also an external call (DelegationRegistry), but it's safe:
    //    nonce/hash already committed, and DelegationRegistry is trusted infra.
    if (intent.signer != intent.trader) {
        uint256 usdcNotional = intent.isBuy ? intent.amount : result;
        delegationRegistry.recordSpend(intent.trader, intent.signer, usdcNotional);
    }

    // 9. Emit event (Variant B: always emit amountUsdc/shares in correct positions)
    uint256 amountUsdc = intent.isBuy ? intent.amount : result;
    uint256 shares     = intent.isBuy ? result : intent.amount;
    emit BackstopTrade(intent.conditionId, intent.trader, intent.side,
        intent.isBuy, amountUsdc, shares, intentHash);

    return result;
}
```

### 7.5 recordSpend Units for BackstopRouter

```
DelegationRegistry.maxNotionalPerDay is in USDC (6 decimals).
recordSpend MUST receive USDC amount, NOT shares.

For BUY intent:
  intent.amount = USDC to spend
  recordSpend(..., intent.amount)  ← correct, already USDC

For SELL intent:
  intent.amount = shares to sell (NOT USDC)
  result = actual USDC received from MarketLMSR

  recordSpend(..., result)  ← use actual USDC output

NOTE: recordSpend is called AFTER _executeBuy/_executeSell (step 8 in §7.4)
because for SELL we need the actual USDC result. This is safe because
nonce/hash are already committed in step 6 (CEI-compliant), and
DelegationRegistry is trusted infrastructure.

Code in executeTradeIntent (step 8):
  uint256 usdcNotional = intent.isBuy ? intent.amount : result;
  delegationRegistry.recordSpend(intent.trader, intent.signer, usdcNotional);
```

---

## 8. Contract: Vault — Accounting Model (FORMALIZED)

### 8.1 Accounting Model: Model A (separate buckets)

```
┌─────────────────────────────────────────────────────────────────────┐
│ VAULT ACCOUNTING MODEL                                               │
│                                                                       │
│ FOUR state variables:                                                 │
│                                                                       │
│   balances[addr]    User/contract ledger balances                     │
│   totalBalances     Running sum of all balances (Σ balances[addr])   │
│   splitReserve      USDC backing outstanding split token pairs        │
│   feePool           Accumulated protocol + creator fees               │
│                                                                       │
│ totalBalances is a RUNNING SUM — updated on every balances change:   │
│   balances[x] += amount → totalBalances += amount                    │
│   balances[x] -= amount → totalBalances -= amount                    │
│                                                                       │
│ This makes the invariant ENFORCEABLE onchain (no mapping iteration): │
│                                                                       │
│ GLOBAL INVARIANT:                                                     │
│   USDC.balanceOf(vault) >= totalBalances + splitReserve + feePool    │
│                                                                       │
│ Can be checked with a single comparison after every state change.     │
│ Optional: add require() at end of every external function             │
│   (gas cost: ~2100 for SLOAD + comparison).                          │
│                                                                       │
│ NO overlap:                                                           │
│   splitReserve is NOT in any balance[addr]                            │
│   feePool is NOT in any balance[addr]                                 │
│   totalBalances tracks ONLY the balances mapping                      │
│   They are three separate reserved buckets                            │
└─────────────────────────────────────────────────────────────────────┘
```

### 8.2 State Transitions (exhaustive, with totalBalances)

```
lockForSplit(caller, amount):
  balances[caller] -= amount     →  totalBalances -= amount
  splitReserve += amount
  NET: totalBalances + splitReserve + feePool unchanged. USDC stays in vault.

releaseFromMerge(to, amount):
  splitReserve -= amount
  balances[to] += amount         →  totalBalances += amount
  NET: unchanged.

releaseForRedeem(to, amount):
  splitReserve -= amount
  balances[to] += amount         →  totalBalances += amount
  NET: unchanged.

accumulateFee(from, amount):
  balances[from] -= amount       →  totalBalances -= amount
  feePool += amount
  NET: unchanged.

withdrawFeePool(to, amount):
  feePool -= amount
  balances[to] += amount         →  totalBalances += amount
  NET: unchanged.

transferBetween(from, to, amount):
  balances[from] -= amount       →  totalBalances -= amount
  balances[to] += amount         →  totalBalances += amount
  NET: totalBalances unchanged (zero-sum).

deposit(user, amount):
  USDC.transferFrom(user, vault, amount)   // external USDC in
  balances[user] += amount                 // totalBalances += amount
  BOTH sides of invariant increase by amount.

withdraw(user, amount):
  balances[user] -= amount                 // totalBalances -= amount
  USDC.transfer(user, amount)              // external USDC out
  BOTH sides of invariant decrease by amount.

INVARIANT CHECK (optional, at end of every external function):
  assert(USDC.balanceOf(address(this)) >= totalBalances + splitReserve + feePool);
```

### 8.3 Permission Matrix

```
┌─────────────────────┬───────────────────────────────────────────────┐
│ Caller              │ Allowed methods                               │
├─────────────────────┼───────────────────────────────────────────────┤
│ User (direct)       │ deposit, withdraw, approveMarket              │
│ Exchange            │ transferBetween, accumulateFee, withdrawFeePool│
│                     │ lockForSplit, releaseFromMerge                │
│ ShareToken          │ lockForSplit, releaseFromMerge, releaseForRedeem│
│ BackstopRouter      │ (none directly — calls MarketLMSR)            │
│ MarketLMSR          │ spendFromUser (via whitelist), payToUser      │
│ Factory             │ pullForNewMarket, addWhitelistedMarket        │
│ Admin               │ addTrustedFactory, pause/unpause, setExchange │
└─────────────────────┴───────────────────────────────────────────────┘
```

---

## 9. Contract: Factory (with Agent Meta-Transactions)

### Three Creation Modes
1. **Direct**: msg.sender = creator
2. **Mode A**: Owner signs `CreateMarket` EIP-712 → relayer submits
3. **Mode B**: Agent signs `DelegatedCreateMarket` → relayer submits

### EIP-712 Domain
```solidity
// name = "FlipCoinFactory", version = "1", chainId, verifyingContract
```

### Replay Protection: Two-Layer
```
Layer 1: nonces[signer]++ (sequential)
Layer 2: usedRequestIds[requestId] = true (idempotency)
Deadline: require(block.timestamp <= deadline)
```

### Signature Verification: OZ ECDSA.recover
```
- Mode A: ECDSA.recover(digest) == creator
- Mode B: ECDSA.recover(digest) == signer + DelegationRegistry check
- Low-s normalization, v check, address(0) revert — all handled by OZ
```

### Internal Creation Flow

```solidity
function _createMarketInternal(params, seedUsdc, price, creator) {
    conditionId = shareToken.prepareCondition(oracle, questionId, usdc, deadline);
    (yesId, noId) = shareToken.getTokenIds(conditionId, usdc);

    exchange.setCreatorFee(conditionId, creator, 50); // 0.5% creator fee, IMMUTABLE
    exchange.registerToken(yesId, noId, conditionId);

    backstop = Clones.clone(marketImplementation);
    MarketLMSR(backstop).initConfig(...);
    shareToken.addAuthorizedCaller(backstop);
    backstopRouter.registerBackstop(conditionId, backstop);
    vault.addWhitelistedMarket(backstop);
    vault.pullForNewMarket(creator, backstop, seedUsdc);
    MarketLMSR(backstop).initialize(b, seedUsdc, price);
}
```

### Creator Fee Protection

```
INVARIANT: fees always go to wallet owner.

1. Factory passes creator = owner (Mode B: owner, NOT signer)
2. exchange.setCreatorFee: require(msg.sender == factory) + require(!creatorFeeSet)
3. After set: LOCKED. No update function. No admin override.
4. DelegatedCreateMarket includes owner in signed data → can't redirect.
```

---

## 10. Resolution Flow (unchanged from v4)

```
Open ──propose──► Pending ──24h──► Finalize ──► Resolved
                    │
                    │ dispute
                    ▼
                  Open (reset)

Open ──deadline+6h──► markAsInvalid() ──► Resolved (Invalid)
```

See §3.1 for markAsInvalid semantics.

---

## 11. Offchain Matching Engine

### REST API

```
POST   /v1/orders              Submit signed CLOB order
POST   /v1/intents             Submit signed TradeIntent (LMSR)
DELETE /v1/orders/:hash        Cancel order offchain
GET    /v1/orderbook/:condId   Book (bids/asks)
GET    /v1/trades/:condId      Recent trades
GET    /v1/quote               Firm quote: CLOB + LMSR split, limit prices, partial fill warning
GET    /v1/markets             Markets with prices
```

### Firm Quote for Mixed Fills

```
GET /v1/quote?conditionId=X&side=YES&amount=100&type=buy

Response:
{
  "totalShares": 100_000_000,
  "avgPrice": 5200,
  "legs": [
    { "source": "clob", "shares": 60_000_000, "price": 5000, "limitPrice": 5050 },
    { "source": "lmsr", "shares": 40_000_000, "price": 5400, "minSharesOut": 39_500_000 }
  ],
  "validUntilBlock": 12345678,
  "mayPartialFill": true,
  "fee": { "totalUsdc": 490_000, "effectiveRate": "0.49%" }
}

UI shows: "May fill partially. CLOB: 60 shares @ $0.50, LMSR: 40 shares @ $0.54"
```

### WebSocket

```
ws://engine/v1/ws
Channels: orderbook:{condId}, trades:{condId}, prices:{condId}, user:{addr}, system
```

---

## 12. Agent API Backend

### Endpoints

```
GET    /api/agent/ping
POST   /api/agent/api-key

POST   /api/agent/markets              Request market creation (returns EIP-712 typed data)
POST   /api/agent/relay                Submit signed meta-tx
GET    /api/agent/markets              List agent markets
GET    /api/agent/markets/:condId      Market details
GET    /api/agent/markets/:condId/history  Price history

POST   /api/agent/orders               Submit signed CLOB order
POST   /api/agent/intents              Submit signed TradeIntent (LMSR)
DELETE /api/agent/orders/:hash         Cancel order
GET    /api/agent/orders/open          Open orders
GET    /api/agent/orderbook/:condId    Order book

GET    /api/agent/portfolio            Positions (ERC-1155)
GET    /api/agent/stats                Stats
GET    /api/agents/leaderboard         Leaderboard
GET    /api/agent/markets/explore      Catalog
```

---

## 13. Indexer Events (complete)

### ShareToken
| Event | Key fields | Usage |
|-------|-----------|-------|
| ConditionPrepared | conditionId, oracle, yesTokenId, noTokenId, deadline | New market |
| PositionSplit | conditionId, caller, to, amount | TVL |
| PositionMerged | conditionId, caller, from, amount | TVL |
| ResolutionProposed | conditionId, outcome, proposedAt, finalizeAfter | Status |
| ResolutionDisputed | conditionId, challenger | Status |
| ResolutionFinalized | conditionId, outcome, payoutPerShare | Status |
| MarkedAsInvalid | conditionId, caller, markedAt | Status |
| PositionRedeemed | conditionId, user, sharesBurned, usdcPayout | Activity |

### Exchange
| Event | Key fields | Usage |
|-------|-----------|-------|
| OrderFilled | orderHash, maker, taker, tokenId, fillAmount, usdcAmount, fee, side | **PRIMARY trade source** |
| OrdersMatched | takerHash, makerHash, matchType, fillAmount | Match context |
| OrderCancelled | orderHash, maker | Order state |
| ConditionPaused / Unpaused | conditionId | Market status |

### BackstopRouter
| Event | Key fields | Usage |
|-------|-----------|-------|
| BackstopTrade | conditionId, trader, side, isBuy, amountUsdc, shares, intentHash | LMSR trades |
| IntentCancelled | intentHash, trader | Intent state |
| NonceBumped | signer, oldNonce, newNonce | Bulk cancel |

> **BackstopTrade fields are NORMALIZED**: `amountUsdc` is always USDC, `shares` is always shares — regardless of `isBuy`. Indexer can always use `amountUsdc` as USDC volume without conditional logic.

### Factory
| Event | Key fields | Usage |
|-------|-----------|-------|
| MarketCreated | conditionId, creator, backstop, yesTokenId, noTokenId, seedUsdc, price | New market |
| MarketCreatedViaRelayer | conditionId, creator, signer, requestId | Agent context |

### DelegationRegistry
| Event | Key fields | Usage |
|-------|-----------|-------|
| DelegationSet | owner, signer, scope, limits, expiresAt | Agent permissions |
| DelegationRevoked | owner, signer | Revocation |
| SpendRecorded | owner, signer, caller, amount | Agent dashboard |

### Price & Volume
```
Price = composite: best bid/ask (WebSocket) → last OrderFilled → LMSR getPrices() (fallback)
Volume = Σ Exchange.OrderFilled.usdcAmount + Σ BackstopRouter.BackstopTrade.amountUsdc
```

---

## 14. Frontend UX

### Fee Display

```
Total fee = 1% (protocol 0.5% + creator 0.5%)
Effective = totalFeeBps * min(price, 1-price) * size / BPS²

At price $0.50: effective = 1% * 0.50 = 0.50% of notional
At price $0.90: effective = 1% * 0.10 = 0.10% of notional

UI: "Fee: $0.50 (0.5% of trade)" — always show by EXECUTION price, not mid.
```

### Approvals (one-time, 3 total)
```
ShareToken.setApprovalForAll(exchange, true)         // for CLOB selling
ShareToken.setApprovalForAll(backstopRouter, true)   // for LMSR selling (see §7.1.1)
Vault.approveMarket(backstopRouter, MAX_UINT)        // for LMSR buying (USDC)

No per-market approvals. CLOB buying needs no approval (signed order IS auth).

UI flow: on first interaction, prompt user for 3 approvals in sequence.
Subsequent interactions require zero approvals.
```

### Mixed Fill UX
```
UI must show: "May fill partially" when firm quote includes LMSR leg.
Show breakdown: "CLOB: 60 @ $0.50 + LMSR: 40 @ $0.54 = avg $0.52"
```

---

## 15. Security Analysis

### Attack Vectors & Mitigations

| Attack | Mitigation |
|--------|-----------|
| Operator front-runs | Orders/intents pre-signed at exact price; Base low MEV |
| Operator arbitrary LMSR trades | **FIXED v5**: TradeIntent EIP-712. Operator is relayer, not delegatee. |
| Replay order/intent | salt + nonce + filled tracking + DOMAIN_SEPARATOR |
| Cross-chain replay | DOMAIN_SEPARATOR includes chainId + verifyingContract |
| Signature malleability | OZ ECDSA.recover |
| Delegated signer abuse | DelegationRegistry: scope, daily limit, expiry |
| Fee redirect by agent | creatorFeeRecipient immutable, set by Factory only |
| Burn delegate limit | recordSpend: onlyAuthorizedContract + scope match |
| Supply mismatch | Exhaustive mint/burn paths listed in §3 |
| Vault double count | **FIXED v5**: Model A — splitReserve/feePool NOT in balances |
| Fee manipulation | maxFeeBps ceiling + onchain check |
| Fee change breaks orders | **FIXED v5**: maxFeeBps allows lowering without invalidation |
| Rounding → zero fee | Accepted: micro-fills, minimum fillAmount recommended |
| conditionId mismatch in MINT/MERGE | **FIXED v5**: explicit check in _deriveMatchType |
| Market stuck | markAsInvalid after deadline + 6h |
| Trading during resolution | conditionPaused; cancel/bumpNonce allowed |

---

## 16. Migration Plan

Same as v4 §16. Addition: BackstopRouter now requires EIP-712 domain setup.

---

## 17. Contract Sizes

| Contract | Est. Size | EIP-170 |
|----------|----------|---------|
| ShareToken | ~12-16 KB | OK |
| Exchange | ~18-24 KB | OK |
| DelegationRegistry | ~5-7 KB | OK |
| BackstopRouter | ~9-13 KB | OK (+TradeIntent, +ReentrancyGuard) |
| MarketLMSR (impl) | ~17-21 KB | OK (+IERC1155Receiver) |
| Factory | ~10-14 KB | OK |
| Vault | ~8-11 KB | OK |

---

## 18. Resolved Questions (v1–v5.2)

| # | Issue | Resolution | §  |
|---|-------|-----------|-----|
| 1 | TradeRouter onchain | Eliminated. Variant A. | 1 |
| 2 | fillAmount units | Always shares | 2 |
| 3 | Rounding exploits | mulDivCeil/Floor | 2 |
| 4 | signer != maker | DelegationRegistry | 5 |
| 5 | Delegation scope | 3 scopes + wildcard | 5 |
| 6 | recordSpend anyone | onlyAuthorizedContract + scope | 5 |
| 7 | Fees in tokens | USDC-only | 4 |
| 8 | feeRateBps=0 | maxFeeBps ceiling | 4.1 |
| 9 | Fee recipients | Protocol + creator, immutable | 4 |
| 10 | Agent fee redirect | creatorFeeRecipient locked by Factory | 4.5, 9 |
| 11 | ShareToken supply | ERC1155Supply, exhaustive paths | 3 |
| 12 | Resolution | Two-phase + markAsInvalid | 3, 10 |
| 13 | markAsInvalid | Full semantics, hardcoded 500K, irreversible | 3.1 |
| 14 | Per-condition pause | pauseCondition; cancel allowed, fill reverts | 4 |
| 15 | LMSR + ERC-1155 | Inventory model (split/merge pairs) | 6 |
| 16 | Vault accounting | **FIXED v5**: Model A, 3 separate pools, invariant | 8 |
| 17 | Factory meta-tx | Full EIP-712, ECDSA.recover, nonce+requestId | 9 |
| 18 | Cross-chain replay | DOMAIN_SEPARATOR | 4, 7, 9 |
| 19 | EIP-1271 | Specified in §4.3 | 4.3 |
| 20 | conditionId in MINT/MERGE | Explicit check in _deriveMatchType | 4.4 |
| 21 | **Operator LMSR abuse** | **FIXED v5**: TradeIntent EIP-712, operator=relayer | 7 |
| 22 | **feeRateBps breaks on change** | **FIXED v5**: maxFeeBps ceiling | 4.1 |
| 23 | **Vault double count** | **FIXED v5**: Model A, separate pools | 8.1 |
| 24 | **Fee rates** | **Set**: protocol 0.5% + creator 0.5% = 1% total | 4 |
| 25 | **CEI reentrancy in BackstopRouter** | **FIXED v5.2**: Effects before interactions + nonReentrant | 7.4 |
| 26 | **BackstopTrade event SELL fields** | **FIXED v5.2**: Normalized emit (amountUsdc=USDC, shares=shares always) | 7.4, 13 |
| 27 | **MarketLMSR IERC1155Receiver** | **FIXED v5.2**: Explicit IERC1155Receiver + ERC165 | 6 |
| 28 | **cancelIntent vs nonce** | **Clarified v5.2**: cancelIntent is per-intent, not per-nonce-slot | 7.2 |

---

## 19. Open Questions

1. **Operator hosting**: Self-hosted matching engine vs managed service?
2. **Gas reimbursement**: Operator gas from feePool accounting?
3. **Protocol-funded LMSR**: Protocol seeds backstop for popular markets?
4. **Tick size**: $0.01 fixed or configurable?
5. **Multi-outcome**: Binary only for v2. NegRisk = v3?
6. **Minimum fillAmount**: enforce >= 1000 onchain or engine-only?
7. **LMSR dynamic b**: Adjust liquidity parameter?
