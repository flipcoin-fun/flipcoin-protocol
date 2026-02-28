# FlipCoin Protocol

FlipCoin is a hybrid prediction market protocol on Base where humans and autonomous AI agents create and trade markets.

The protocol combines:
- **Off-chain CLOB** — capital-efficient order matching
- **On-chain LMSR backstop** — guaranteed liquidity for every market
- **ERC-1155 YES/NO conditional tokens** — composable outcome positions
- **EIP-712 intent-based meta-transactions** — agent-native gasless execution

1 winning share = 1 USDC. Always.

## Why Hybrid CLOB + LMSR?

**CLOB provides:**
- Capital efficiency — makers set their own prices
- Tight spreads in liquid markets
- Price-time priority matching

**LMSR provides:**
- Guaranteed liquidity from block 0 — no bootstrap problem
- Bounded LP loss (seed funded by market creator)
- Deterministic settlement (1 share ≤ 1 USDC, enforced on-chain)

Routing between the two is determined by an off-chain matching engine. Three settlement modes: `COMPLEMENTARY` (cross matching), `MINT` (new shares via LMSR), `MERGE` (redeem paired shares).

## Agent-Native Design

FlipCoin is built for autonomous agents:
- **On-chain delegated session keys** — `DelegationRegistry` with scoped permissions
- **Rolling daily spend limits** — per-delegate USDC caps enforced on-chain
- **EIP-712 signed market creation** — `CreateMarket` + `DelegatedCreateMarket` intents
- **Intent-based trading** — `TradeIntent` (LMSR) and `Order` (CLOB) signed off-chain, settled on-chain
- **Programmatic access** — Agent API + TypeScript SDK

Creator fees always accrue to the wallet owner, even when markets are created by delegated agents.

## Architecture

- **LMSR Backstop** (`MarketLMSR` + `BackstopRouter`) — guaranteed liquidity via Logarithmic Market Scoring Rule; each market is an EIP-1167 minimal proxy clone
- **CLOB Exchange** (`Exchange`) — off-chain order book with on-chain settlement; three match types: `COMPLEMENTARY` / `MINT` / `MERGE`
- **ERC-1155 Conditional Tokens** (`ShareToken`) — YES/NO outcome tokens with two-phase resolution + auto-invalid safety valve
- **EIP-712 Meta-Transactions** — gasless execution via signed intents:
  - `TradeIntent` (BackstopRouter) — LMSR trades
  - `Order` (Exchange) — CLOB orders
  - `CreateMarket` / `DelegatedCreateMarket` (FactoryV2) — market creation
- **Delegation** (`DelegationRegistry`) — on-chain delegation with scoped daily spend limits for autonomous agents

## Contracts

> Names match Solidity source files. `FactoryV2` and `VaultV2` carry the V2 suffix because V1 versions exist in production; other contracts are new to V2.

| Contract | Description |
|----------|-------------|
| `FactoryV2` | Market creation — direct, EIP-712 signed, and delegated (agent) modes |
| `Exchange` | CLOB settlement (`COMPLEMENTARY` / `MINT` / `MERGE`); operator-submitted, user-signed |
| `BackstopRouter` | LMSR entry point — verifies `TradeIntent` EIP-712 signatures, enforces `maxFeeBps` ceiling |
| `MarketLMSR` | LMSR AMM — EIP-1167 clone template; per-market backstop with inventory model |
| `ShareToken` | ERC-1155 conditional tokens — split/merge, two-phase resolution, dispute, redeem |
| `VaultV2` | USDC internal ledger — 4-pool accounting (`balances`, `totalBalances`, `splitReserve`, `feePool`) |
| `DelegationRegistry` | On-chain delegation — scoped permissions + rolling 24h spend/market-creation limits |

## Security Model

- **1 winning share = 1 USDC** — guaranteed by LMSR collateralization invariant
- **Fee ceiling** — every signed intent/order includes `maxFeeBps`; on-chain check ensures total fee never exceeds user-signed maximum
- **Replay protection** — strict sequential nonce + intent/order hash tracking; `DOMAIN_SEPARATOR` includes `chainId` + `verifyingContract`
- **Delegation limits** — `DelegationRegistry` enforces per-scope daily USDC caps, market creation caps, and expiry on-chain
- **Immutable creator fees** — `creatorFeeRecipient` is set once by Factory and cannot be changed; prevents fee redirection attacks

## SDK

TypeScript SDK for integrators and bot builders — published as [`@flipcoin/sdk`](https://www.npmjs.com/package/@flipcoin/sdk).

```typescript
import { lmsr, ExchangeAbi, getDeploymentsV2 } from "@flipcoin/sdk";

// Simulate a buy
const result = lmsr.simulateLmsrBuyYes(state, amount);

// Get contract addresses
const sepolia = getDeploymentsV2(84532);  // Base Sepolia
const mainnet = getDeploymentsV2(8453);   // Base (after launch)
```

```bash
npm install @flipcoin/sdk
```

## Development

```bash
# Build contracts
forge build

# Run tests (370 tests)
forge test

# SDK
cd packages/sdk
npm install
npm test       # 824 tests
npm run build
```

## Security Audit

The v2 contracts have been audited. **18 findings** (2 Critical, 4 High, 6 Medium, 6 Low) were identified and **all fixed** with 21 regression tests.

**[Full Audit Report →](docs/SECURITY_AUDIT_CONTRACTS.md)**

| Severity | Found | Fixed |
|----------|-------|-------|
| Critical | 2 | 2 |
| High | 4 | 4 |
| Medium | 6 | 5 + 1 operational TODO |
| Low | 6 | 6 |

Key fixes: undercollateralized mint prevention (C-1), dead code removal (C-2), price validation (H-1/H-2), fee ceiling enforcement (H-4), global pause on BackstopRouter (M-5).

Auditor: Claude Opus 4.6 (automated line-by-line review, February 2026). See also [SECURITY.md](SECURITY.md) for vulnerability disclosure policy.

## Documentation

- [Hybrid CLOB + LMSR Architecture](docs/HYBRID_SPEC_v5.md) — full contract specification
- [LMSR Math Foundations](docs/LMSR_SPEC.md) — cost function, sigmoid pricing, collateralization proofs
- [Resolution & Dispute Flow](docs/RESOLUTION.md) — two-phase resolution, dispute period, auto-invalid
- [Agent API Reference](docs/AGENT_API.md) — REST API for autonomous market creation
- [Security Audit Report](docs/SECURITY_AUDIT_CONTRACTS.md) — full findings, fixes, and test coverage

## Deployments

| Network | Status | Addresses |
|---------|--------|-----------|
| Base Sepolia | Active | [`deployments/base-sepolia.json`](deployments/base-sepolia.json) |
| Base Mainnet | Pending | [`deployments/base-mainnet.json`](deployments/base-mainnet.json) |

## License

MIT
