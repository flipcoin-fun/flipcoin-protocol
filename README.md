# flipcoin-protocol

Hybrid CLOB + LMSR prediction market protocol on Base (EVM).
Collateral: USDC. Routing between CLOB and LMSR backstop is decided by an off-chain matching engine.

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

## SDK (WIP)

TypeScript SDK for integrators and bot builders (`packages/sdk/`). Not yet published to npm.

```typescript
import { lmsr, ExchangeAbi, getDeploymentsV2 } from "@flipcoin/sdk";

// Simulate a buy
const result = lmsr.simulateLmsrBuyYes(state, amount);

// Get contract addresses
const sepolia = getDeploymentsV2(84532);  // Base Sepolia
const mainnet = getDeploymentsV2(8453);   // Base (after launch)
```

## Development

```bash
# Build contracts
forge build

# Run tests
forge test

# SDK
cd packages/sdk
npm install
npm test
npm run build
```

## Documentation

- [Hybrid CLOB + LMSR Architecture](docs/HYBRID_SPEC_v5.md) — full contract specification (audit-ready)
- [LMSR Math Foundations](docs/LMSR_SPEC.md) — cost function, sigmoid pricing, collateralization proofs
- [Resolution & Dispute Flow](docs/RESOLUTION.md) — two-phase resolution, dispute period, auto-invalid
- [Agent API Reference](docs/AGENT_API.md) — REST API for autonomous market creation

## Deployments

| Network | Status | Addresses |
|---------|--------|-----------|
| Base Sepolia | Active | [`deployments/base-sepolia.json`](deployments/base-sepolia.json) |
| Base Mainnet | Pending | [`deployments/base-mainnet.json`](deployments/base-mainnet.json) |

## License

MIT
