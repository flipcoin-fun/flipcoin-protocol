// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SD59x18, sd, exp, ln, UNIT, ZERO} from "@prb/math/SD59x18.sol";

/**
 * @title LMSRMath
 * @notice Pure math library for LMSR (Logarithmic Market Scoring Rule) calculations
 * @dev Extracted from MarketLMSR to reduce contract bytecode below EIP-170 limit.
 *      All functions are `internal` so they get inlined — but because they use
 *      PRBMath SD59x18 operations extensively, moving them to a library with
 *      well-defined entry points helps the Solidity optimizer deduplicate code.
 *
 * Constants are duplicated here (same values as MarketLMSR) to avoid cross-contract reads.
 */
library LMSRMath {
    int256 internal constant UNIT_INT = 1e18;
    int256 internal constant USDC_TO_SD59x18 = 1e12;
    int256 internal constant SIGMOID_CLAMP = 20;
    uint256 internal constant BPS = 10_000;

    /**
     * @notice Calculate initial q values for a desired YES price
     * @param b Liquidity parameter (SD59x18)
     * @param priceYesBps Target YES price in basis points (100-9900)
     * @return _qYes Initial qYes value (SD59x18)
     * @return _qNo Initial qNo value (SD59x18)
     */
    function calcInitialQ(
        int256 b,
        uint256 priceYesBps
    ) internal pure returns (int256 _qYes, int256 _qNo) {
        SD59x18 p = sd(int256(priceYesBps) * UNIT_INT / int256(BPS));
        SD59x18 oneMinusP = sd(UNIT_INT).sub(p);

        if (p.unwrap() <= 0 || oneMinusP.unwrap() <= 0) {
            return (0, 0);
        }

        SD59x18 ratio = p.div(oneMinusP);
        SD59x18 lnRatio = ln(ratio);
        SD59x18 qDiff = sd(b).mul(lnRatio);

        _qYes = qDiff.unwrap() / 2;
        _qNo = -_qYes;
    }

    /**
     * @notice Calculate LMSR cost function using Log-Sum-Exp trick
     * @dev C = b * (m + ln(e^(a-m) + e^(c-m))) where m = max(a, c)
     * @param b Liquidity parameter (SD59x18)
     * @param _qYes Cumulative YES shares (SD59x18)
     * @param _qNo Cumulative NO shares (SD59x18)
     * @return cost Cost in USDC (6 decimals)
     */
    function calcCostUsdc(
        int256 b,
        int256 _qYes,
        int256 _qNo
    ) internal pure returns (uint256 cost) {
        SD59x18 bSD = sd(b);
        SD59x18 a = sd(_qYes).div(bSD);
        SD59x18 c = sd(_qNo).div(bSD);

        SD59x18 m = a.gt(c) ? a : c;

        SD59x18 expAM = exp(a.sub(m));
        SD59x18 expCM = exp(c.sub(m));
        SD59x18 sumExp = expAM.add(expCM);

        SD59x18 lnSum = ln(sumExp);
        SD59x18 result = bSD.mul(m.add(lnSum));

        int256 rawResult = result.unwrap();
        require(rawResult >= 0, "negative cost");

        cost = uint256(rawResult) / uint256(USDC_TO_SD59x18);
    }

    /**
     * @notice Calculate shares out for a given USDC cost using binary search
     * @param b Liquidity parameter (SD59x18)
     * @param _qYes Current qYes (SD59x18)
     * @param _qNo Current qNo (SD59x18)
     * @param costUsdc Net USDC to spend (6 decimals, after fees)
     * @param isYes True for YES shares, false for NO
     * @return sharesOut Shares to receive (6 decimals)
     */
    function calcSharesOut(
        int256 b,
        int256 _qYes,
        int256 _qNo,
        uint256 costUsdc,
        bool isYes
    ) internal pure returns (uint256 sharesOut) {
        uint256 currentCost = calcCostUsdc(b, _qYes, _qNo);
        uint256 targetCost = currentCost + costUsdc;

        uint256 low = 0;
        uint256 high = costUsdc * 200;

        for (uint256 i = 0; i < 40; i++) {
            uint256 mid = (low + high) / 2;
            if (mid == low) break;

            int256 deltaQ = int256(mid) * USDC_TO_SD59x18;
            int256 newQYes = isYes ? _qYes + deltaQ : _qYes;
            int256 newQNo = isYes ? _qNo : _qNo + deltaQ;

            uint256 newCost = calcCostUsdc(b, newQYes, newQNo);

            if (newCost <= targetCost) {
                low = mid;
            } else {
                high = mid;
            }
        }

        sharesOut = low;

        // Post-check: verify binary search converged to a valid result.
        // If high == upper bound, the search may not have found a valid solution.
        if (sharesOut == 0 && costUsdc > 0) {
            revert("binary search: no convergence");
        }
    }

    /**
     * @notice Calculate sigmoid price P(yes) = 1 / (1 + e^(-diff/b))
     * @param b Liquidity parameter (SD59x18)
     * @param diff qYes - qNo (SD59x18)
     * @return priceYesBps YES price in basis points (1-9999)
     */
    function sigmoid(int256 b, int256 diff) internal pure returns (uint256 priceYesBps) {
        SD59x18 x = sd(diff).div(sd(b));
        SD59x18 negX = ZERO.sub(x);
        SD59x18 expNegX = exp(negX);
        SD59x18 denom = UNIT.add(expNegX);
        SD59x18 prob = UNIT.div(denom);

        uint256 probBps = uint256(prob.unwrap()) * BPS / uint256(UNIT_INT);

        if (probBps == 0) return 1;
        if (probBps >= BPS) return 9999;
        return probBps;
    }

    /**
     * @notice Get current prices in basis points
     * @param b Liquidity parameter (SD59x18)
     * @param _qYes Cumulative YES shares (SD59x18)
     * @param _qNo Cumulative NO shares (SD59x18)
     * @return priceYesBps YES price (1-9999)
     * @return priceNoBps NO price (1-9999)
     */
    function getPrices(
        int256 b,
        int256 _qYes,
        int256 _qNo
    ) internal pure returns (uint256 priceYesBps, uint256 priceNoBps) {
        int256 diff = _qYes - _qNo;

        if (diff > b * SIGMOID_CLAMP) {
            priceYesBps = 9999;
        } else if (diff < -b * SIGMOID_CLAMP) {
            priceYesBps = 1;
        } else {
            priceYesBps = sigmoid(b, diff);
        }

        priceNoBps = BPS - priceYesBps;
    }

    /**
     * @notice Absolute value helper
     */
    function abs(int256 x) internal pure returns (int256) {
        return x >= 0 ? x : -x;
    }
}
