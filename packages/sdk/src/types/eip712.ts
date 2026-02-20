/**
 * EIP-712 typed data utilities for v2 contracts
 *
 * Provides structured typed data for signing:
 * - TradeIntent (BackstopRouter gasless trades)
 * - Order (Exchange CLOB orders)
 */

import type { Address } from "viem";

// ============================================================
// Shared enums (matching Solidity)
// ============================================================

/** Side enum — 0 = YES, 1 = NO */
export enum Side {
  YES = 0,
  NO = 1,
}

/** Signature type for Exchange orders */
export enum SignatureType {
  EOA = 0,
  POLY_PROXY = 1,
  POLY_GNOSIS_SAFE = 2,
}

/** Match type for Exchange order matching */
export enum MatchType {
  COMPLEMENTARY = 0,
  MINT = 1,
  MERGE = 2,
}

/** Resolution status matching v2 ShareToken */
export enum ResolutionStatus {
  Open = 0,
  Pending = 1,
  Resolved = 2,
}

/** Outcome enum matching v2 ShareToken */
export enum OutcomeV2 {
  None = 0,
  Yes = 1,
  No = 2,
  Invalid = 3,
}

// ============================================================
// TradeIntent (BackstopRouter)
// ============================================================

export interface TradeIntent {
  trader: Address;
  signer: Address;
  conditionId: `0x${string}`;
  side: Side;
  isBuy: boolean;
  amount: bigint;
  minOut: bigint;
  deadline: bigint;
  nonce: bigint;
  maxFeeBps: bigint;
}

/**
 * EIP-712 typed data for signing a TradeIntent (BackstopRouter gasless trades)
 *
 * Domain: read from contract via `eip712Domain()`, or use defaults:
 *   name = "FlipCoinBackstopRouter", version = "1"
 */
export function getTradeIntentTypedData(
  domain: { name: string; version: string; chainId: number; verifyingContract: Address },
  intent: TradeIntent,
) {
  return {
    domain: {
      name: domain.name,
      version: domain.version,
      chainId: domain.chainId,
      verifyingContract: domain.verifyingContract,
    },
    types: {
      TradeIntent: [
        { name: "trader", type: "address" },
        { name: "signer", type: "address" },
        { name: "conditionId", type: "bytes32" },
        { name: "side", type: "uint8" },
        { name: "isBuy", type: "bool" },
        { name: "amount", type: "uint256" },
        { name: "minOut", type: "uint256" },
        { name: "deadline", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "maxFeeBps", type: "uint256" },
      ],
    },
    primaryType: "TradeIntent" as const,
    message: {
      trader: intent.trader,
      signer: intent.signer,
      conditionId: intent.conditionId,
      side: intent.side,
      isBuy: intent.isBuy,
      amount: intent.amount,
      minOut: intent.minOut,
      deadline: intent.deadline,
      nonce: intent.nonce,
      maxFeeBps: intent.maxFeeBps,
    },
  };
}

// ============================================================
// Order (Exchange CLOB)
// ============================================================

export interface Order {
  salt: bigint;
  maker: Address;
  signer: Address;
  taker: Address;
  tokenId: bigint;
  makerAmount: bigint;
  takerAmount: bigint;
  expiration: bigint;
  nonce: bigint;
  maxFeeBps: bigint;
  side: Side;
  sigType: SignatureType;
}

/**
 * EIP-712 typed data for signing an Order (Exchange CLOB)
 *
 * Domain: read from contract via `eip712Domain()`, or use defaults:
 *   name = "FlipCoinExchange", version = "1"
 */
export function getOrderTypedData(
  domain: { name: string; version: string; chainId: number; verifyingContract: Address },
  order: Order,
) {
  return {
    domain: {
      name: domain.name,
      version: domain.version,
      chainId: domain.chainId,
      verifyingContract: domain.verifyingContract,
    },
    types: {
      Order: [
        { name: "salt", type: "uint256" },
        { name: "maker", type: "address" },
        { name: "signer", type: "address" },
        { name: "taker", type: "address" },
        { name: "tokenId", type: "uint256" },
        { name: "makerAmount", type: "uint256" },
        { name: "takerAmount", type: "uint256" },
        { name: "expiration", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "maxFeeBps", type: "uint256" },
        { name: "side", type: "uint8" },
        { name: "sigType", type: "uint8" },
      ],
    },
    primaryType: "Order" as const,
    message: {
      salt: order.salt,
      maker: order.maker,
      signer: order.signer,
      taker: order.taker,
      tokenId: order.tokenId,
      makerAmount: order.makerAmount,
      takerAmount: order.takerAmount,
      expiration: order.expiration,
      nonce: order.nonce,
      maxFeeBps: order.maxFeeBps,
      side: order.side,
      sigType: order.sigType,
    },
  };
}

// ============================================================
// Domain helpers
// ============================================================

export function getBackstopRouterDomain(
  backstopRouterAddress: Address,
  chainId: number,
) {
  return {
    name: "FlipCoinBackstopRouter",
    version: "1",
    chainId,
    verifyingContract: backstopRouterAddress,
  };
}

export function getExchangeDomain(
  exchangeAddress: Address,
  chainId: number,
) {
  return {
    name: "FlipCoinExchange",
    version: "1",
    chainId,
    verifyingContract: exchangeAddress,
  };
}
