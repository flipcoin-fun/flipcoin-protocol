// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {Side, MarketConfigV2} from "./interfaces/Types.sol";
import {ShareToken} from "./ShareToken.sol";
import {VaultV2} from "./VaultV2.sol";
import {LMSRMath} from "./libraries/LMSRMath.sol";

/**
 * @title MarketLMSR (v2)
 * @notice LMSR backstop AMM using ERC-1155 inventory model
 * @dev Key differences from v1:
 *   - No yesShares/noShares mappings — tokens are in ShareToken (ERC-1155)
 *   - No resolution logic — handled by ShareToken
 *   - Trading functions take buyer/seller address (called by BackstopRouter)
 *   - Must implement IERC1155Receiver for sell flow (receives tokens)
 *
 * Buy flow: Vault transfer → fee → lockForSplit → splitPosition → transfer YES to buyer
 * Sell flow: (BackstopRouter transfers shares to this) → mergePositions → releaseFromMerge → fee → pay seller
 *
 * See HYBRID_SPEC_v5.2 §6 for full specification.
 */
contract MarketLMSR is IERC1155Receiver, ERC165 {
    // ============================================================
    // Constants (duplicated from LMSRMath for gas efficiency)
    // ============================================================

    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_TRADE_USDC = 10_000; // 0.01 USDC
    int256 public constant USDC_TO_SD59x18 = 1e12;

    // ============================================================
    // State — Config (set once by Factory via initConfig)
    // ============================================================

    address public admin;
    address public creator;
    address public vault;       // VaultV2
    address public factory;
    address public backstopRouter;
    address public shareToken;  // ShareToken (ERC-1155)
    address public protocolAddress;

    bytes32 public conditionId;
    uint256 public yesTokenId;
    uint256 public noTokenId;

    uint16 public totalFeeBps;
    uint16 public creatorFeeBps;
    uint16 public protocolFeeBps;

    uint64 public deadline;
    string public question;
    string public description;
    string public category;
    string public resolutionRules;
    string public resolutionSource;
    string public imageUrl;

    // ============================================================
    // State — LMSR
    // ============================================================

    bool public initialized;
    bool public configSet;

    int256 public b;     // Liquidity parameter (SD59x18)
    int256 public qYes;  // Cumulative YES shares sold (SD59x18)
    int256 public qNo;   // Cumulative NO shares sold (SD59x18)
    uint256 public baseCost; // Initial cost at initialization (USDC)

    // ============================================================
    // Events
    // ============================================================

    event MarketInitialized(
        int256 b,
        uint256 seedUsdc,
        uint256 initialPriceYesBps,
        address indexed creator
    );

    event Trade(
        address indexed trader,
        Side side,
        bool isBuy,
        uint256 amountUsdc,
        uint256 shares,
        uint256 fee,
        uint256 priceYesBps,
        int256 qYesAfter,
        int256 qNoAfter
    );

    // ============================================================
    // Errors
    // ============================================================

    error NotBackstopRouter();
    error NotFactory();
    error AlreadyInitialized();
    error AlreadyConfigured();
    error NotInitialized();
    error TradeTooSmall();
    error SlippageExceeded();
    error UnknownToken();

    // ============================================================
    // Modifiers
    // ============================================================

    modifier onlyBackstopRouter() {
        if (msg.sender != backstopRouter) revert NotBackstopRouter();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    // ============================================================
    // Initialization (called by Factory after cloning)
    // ============================================================

    /**
     * @notice Set one-time configuration (called by Factory after EIP-1167 clone)
     * @dev Only callable once. The factory field is set during this call, so we
     *      cannot use onlyFactory modifier. Instead, the `configSet` flag ensures
     *      this is a one-shot initialization — any subsequent call reverts.
     */
    function initConfig(MarketConfigV2 calldata mc) external {
        require(!configSet, "already configured");
        require(mc.factory != address(0), "zero factory");
        require(mc.vault != address(0), "zero vault");
        require(mc.shareToken != address(0), "zero shareToken");
        require(mc.backstopRouter != address(0), "zero backstopRouter");
        configSet = true;

        admin = mc.admin;
        creator = mc.creator;
        vault = mc.vault;
        factory = mc.factory;
        backstopRouter = mc.backstopRouter;
        shareToken = mc.shareToken;
        protocolAddress = mc.protocolAddress;
        conditionId = mc.conditionId;
        yesTokenId = mc.yesTokenId;
        noTokenId = mc.noTokenId;
        totalFeeBps = mc.totalFeeBps;
        creatorFeeBps = mc.creatorFeeBps;
        protocolFeeBps = mc.protocolFeeBps;
        deadline = mc.deadline;
        question = mc.question;
        description = mc.description;
        category = mc.category;
        resolutionRules = mc.resolutionRules;
        resolutionSource = mc.resolutionSource;
        imageUrl = mc.imageUrl;
    }

    /**
     * @notice Initialize LMSR with seed liquidity
     * @param _b Liquidity parameter (SD59x18)
     * @param seedUsdc Initial seed USDC (already in market's Vault balance)
     * @param initialPriceYesBps Initial YES price in basis points
     */
    function initialize(int256 _b, uint256 seedUsdc, uint256 initialPriceYesBps) external {
        require(configSet, "not configured");
        require(!initialized, "already initialized");
        require(msg.sender == factory, "not factory");
        require(_b > 0, "b must be positive");
        require(initialPriceYesBps > 0 && initialPriceYesBps < BPS, "invalid price");

        initialized = true;
        b = _b;

        // Calculate initial q values from target price
        // Price(YES) = sigmoid(b, qYes - qNo) = 1 / (1 + e^(-(qYes-qNo)/b))
        // To achieve priceYes, we need: qYes - qNo = b * ln(p / (1-p))
        (int256 _qYes, int256 _qNo) = _calcInitialQ(_b, initialPriceYesBps);
        qYes = _qYes;
        qNo = _qNo;

        // Calculate base cost (reference point)
        baseCost = _calcCostUsdc(_b, _qYes, _qNo);

        // Lock seed into splitReserve (backing initial virtual liquidity)
        VaultV2(vault).lockForSplit(address(this), seedUsdc);

        // Mint initial token pairs to self (virtual inventory)
        // The LMSR starts with virtual q but no actual tokens minted
        // Tokens are minted on-demand when users buy

        emit MarketInitialized(_b, seedUsdc, initialPriceYesBps, creator);
    }

    // ============================================================
    // Trading — Buy (called by BackstopRouter)
    // ============================================================

    /**
     * @notice Buy YES shares via LMSR
     * @param buyer Address buying shares
     * @param amountUsdc Maximum USDC to spend (includes fee)
     * @param minSharesOut Minimum shares to receive (slippage protection)
     * @return sharesOut Actual shares received
     */
    function buyYes(address buyer, uint256 amountUsdc, uint256 minSharesOut)
        external onlyBackstopRouter returns (uint256 sharesOut)
    {
        return _buy(buyer, amountUsdc, minSharesOut, Side.Yes);
    }

    /**
     * @notice Buy NO shares via LMSR
     */
    function buyNo(address buyer, uint256 amountUsdc, uint256 minSharesOut)
        external onlyBackstopRouter returns (uint256 sharesOut)
    {
        return _buy(buyer, amountUsdc, minSharesOut, Side.No);
    }

    // ============================================================
    // Trading — Sell (called by BackstopRouter)
    // ============================================================

    /**
     * @notice Sell YES shares via LMSR
     * @dev BackstopRouter has already transferred YES tokens to this contract
     * @param seller Address selling shares
     * @param shares Number of shares to sell
     * @param minAmountOut Minimum USDC to receive (slippage protection)
     * @return amountOut Actual USDC received
     */
    function sellYes(address seller, uint256 shares, uint256 minAmountOut)
        external onlyBackstopRouter returns (uint256 amountOut)
    {
        return _sell(seller, shares, minAmountOut, Side.Yes);
    }

    /**
     * @notice Sell NO shares via LMSR
     */
    function sellNo(address seller, uint256 shares, uint256 minAmountOut)
        external onlyBackstopRouter returns (uint256 amountOut)
    {
        return _sell(seller, shares, minAmountOut, Side.No);
    }

    // ============================================================
    // Views
    // ============================================================

    /**
     * @notice Total fee in basis points (creator + protocol combined)
     * @dev Used by BackstopRouter to check against TradeIntent.maxFeeBps
     */
    function totalFeeBpsView() external view returns (uint256) {
        return uint256(creatorFeeBps) + uint256(protocolFeeBps);
    }

    /**
     * @notice Get current prices in basis points
     */
    function getPrices() external view returns (uint256 priceYesBps, uint256 priceNoBps) {
        return _getPrices();
    }

    /**
     * @notice Quote a buy: how many shares for given USDC (after fee)
     * @param side YES or NO
     * @param amountUsdc USDC input (6 decimals)
     * @return sharesOut Shares received
     * @return fee Fee deducted from input
     */
    function quoteBuy(Side side, uint256 amountUsdc)
        external view returns (uint256 sharesOut, uint256 fee)
    {
        fee = _calcFee(amountUsdc);
        uint256 net = amountUsdc - fee;
        sharesOut = _calcSharesOut(net, side);
    }

    /**
     * @notice Quote a sell: how much USDC for given shares (after fee)
     * @param side YES or NO
     * @param shares Shares to sell
     * @return amountOut USDC received after fee
     * @return fee Fee deducted from gross
     */
    function quoteSell(Side side, uint256 shares)
        external view returns (uint256 amountOut, uint256 fee)
    {
        uint256 gross = _calcSellAmount(shares, side);
        fee = _calcFee(gross);
        amountOut = gross - fee;
    }

    // ============================================================
    // IERC1155Receiver (REQUIRED for sell flow)
    // ============================================================

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external view override returns (bytes4)
    {
        if (msg.sender != shareToken) revert UnknownToken();
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external view override returns (bytes4)
    {
        if (msg.sender != shareToken) revert UnknownToken();
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || super.supportsInterface(interfaceId);
    }

    // ============================================================
    // Internal — Buy Logic
    // ============================================================

    function _buy(address buyer, uint256 amountUsdc, uint256 minSharesOut, Side side)
        internal returns (uint256 sharesOut)
    {
        require(initialized, "not initialized");
        if (amountUsdc < MIN_TRADE_USDC) revert TradeTooSmall();

        // 1. Transfer USDC from buyer to this market's Vault balance
        VaultV2(vault).transferBetween(buyer, address(this), amountUsdc);

        // 2. Calculate fee
        uint256 fee = _calcFee(amountUsdc);
        uint256 net = amountUsdc - fee;

        // 3. Calculate shares out via LMSR
        sharesOut = _calcSharesOut(net, side);
        require(sharesOut >= net, "price exceeds $1"); // Polymarket-style guarantee
        if (sharesOut < minSharesOut) revert SlippageExceeded();

        // 4. Lock net USDC in splitReserve (backing the new tokens)
        VaultV2(vault).lockForSplit(address(this), net);

        // 5. Mint YES+NO pair via ShareToken
        ShareToken(shareToken).splitPosition(conditionId, address(this), sharesOut);

        // 6. Transfer bought shares to buyer, keep opposite as inventory
        uint256 buyTokenId = side == Side.Yes ? yesTokenId : noTokenId;
        ShareToken(shareToken).safeTransferFrom(address(this), buyer, buyTokenId, sharesOut, "");
        // Opposite tokens stay in this contract as LMSR inventory

        // 7. Accumulate fee
        if (fee > 0) {
            VaultV2(vault).accumulateFee(address(this), fee);
        }

        // 8. Update q
        int256 deltaQ = int256(sharesOut) * USDC_TO_SD59x18;
        if (side == Side.Yes) {
            qYes += deltaQ;
        } else {
            qNo += deltaQ;
        }

        // 9. Emit event
        (uint256 priceYes,) = _getPrices();
        emit Trade(buyer, side, true, amountUsdc, sharesOut, fee, priceYes, qYes, qNo);
    }

    // ============================================================
    // Internal — Sell Logic
    // ============================================================

    function _sell(address seller, uint256 shares, uint256 minAmountOut, Side side)
        internal returns (uint256 amountOut)
    {
        require(initialized, "not initialized");
        require(shares > 0, "zero shares");

        // 1. BackstopRouter already transferred shares to this contract
        //    (via ShareToken.safeTransferFrom using user's approval of BackstopRouter)

        // 2. Calculate gross USDC from LMSR
        uint256 gross = _calcSellAmount(shares, side);

        // 3. Merge: burn YES+NO pair (this contract holds both)
        ShareToken(shareToken).mergePositions(conditionId, address(this), shares);

        // 4. Release USDC from splitReserve back to this market's balance
        VaultV2(vault).releaseFromMerge(address(this), shares);

        // 5. Calculate fee, compute amountOut
        uint256 fee = _calcFee(gross);
        amountOut = gross - fee;
        if (amountOut < minAmountOut) revert SlippageExceeded();

        // 6. Pay seller
        VaultV2(vault).transferBetween(address(this), seller, amountOut);

        // 7. Accumulate fee
        if (fee > 0) {
            VaultV2(vault).accumulateFee(address(this), fee);
        }

        // 8. Update q
        int256 deltaQ = int256(shares) * USDC_TO_SD59x18;
        if (side == Side.Yes) {
            qYes -= deltaQ;
        } else {
            qNo -= deltaQ;
        }

        // 9. Emit event
        (uint256 priceYes,) = _getPrices();
        emit Trade(seller, side, false, amountOut, shares, fee, priceYes, qYes, qNo);
    }

    // ============================================================
    // Internal — LMSR Math (inline for gas efficiency)
    // ============================================================

    function _calcFee(uint256 amountUsdc) internal view returns (uint256) {
        return amountUsdc * uint256(totalFeeBps) / BPS;
    }

    function _getPrices() internal view returns (uint256 priceYesBps, uint256 priceNoBps) {
        return LMSRMath.getPrices(b, qYes, qNo);
    }

    function _calcSharesOut(uint256 netUsdc, Side side) internal view returns (uint256) {
        return LMSRMath.calcSharesOut(b, qYes, qNo, netUsdc, side == Side.Yes);
    }

    function _calcSellAmount(uint256 shares, Side side) internal view returns (uint256) {
        uint256 currentCost = LMSRMath.calcCostUsdc(b, qYes, qNo);

        int256 deltaQ = int256(shares) * USDC_TO_SD59x18;
        int256 newQYes = side == Side.Yes ? qYes - deltaQ : qYes;
        int256 newQNo = side == Side.Yes ? qNo : qNo - deltaQ;

        uint256 newCost = LMSRMath.calcCostUsdc(b, newQYes, newQNo);

        // Guard against underflow from rounding: if newCost >= currentCost, no payout
        if (newCost >= currentCost) return 0;
        return currentCost - newCost;
    }

    function _calcInitialQ(int256 _b, uint256 priceYesBps) internal pure returns (int256 _qYes, int256 _qNo) {
        return LMSRMath.calcInitialQ(_b, priceYesBps);
    }

    function _calcCostUsdc(int256 _b, int256 _qYes, int256 _qNo) internal pure returns (uint256) {
        return LMSRMath.calcCostUsdc(_b, _qYes, _qNo);
    }
}
