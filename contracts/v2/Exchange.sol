// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import {
    Order, Side, MatchType, SignatureType, Outcome
} from "./interfaces/Types.sol";
import {ShareToken} from "./ShareToken.sol";
import {VaultV2} from "./VaultV2.sol";
import {DelegationRegistry} from "./DelegationRegistry.sol";

/**
 * @title Exchange
 * @notice CLOB settlement contract for FlipCoin v2
 * @dev Operator-only order matching with three settlement modes:
 *   - COMPLEMENTARY: buyer + seller same token → direct transfer
 *   - MINT: two buyers opposite tokens → split via ShareToken
 *   - MERGE: two sellers opposite tokens → merge via ShareToken
 *
 * Fee model: totalFeeBps * min(price, BPS-price) * fillAmount / BPS²
 * maxFeeBps: user-signed ceiling on total fee (protocol + creator)
 *
 * See HYBRID_SPEC_v5.2 §4 for full specification.
 */
contract Exchange is EIP712, ReentrancyGuard {
    using ECDSA for bytes32;

    // ============================================================
    // Constants
    // ============================================================

    uint256 public constant BPS = 10_000;

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(uint256 salt,address maker,address signer,address taker,"
        "uint256 tokenId,uint256 makerAmount,uint256 takerAmount,"
        "uint256 expiration,uint256 nonce,uint256 maxFeeBps,"
        "uint8 side,uint8 signatureType)"
    );

    bytes4 private constant EIP1271_MAGIC = 0x1626ba7e;

    // ============================================================
    // State
    // ============================================================

    address public admin;
    address public operator;
    address public factory;

    ShareToken public shareToken;
    VaultV2 public vault;
    DelegationRegistry public delegationRegistry;

    bool public paused;
    uint256 public protocolFeeBps; // Default: 50 (0.5%)
    address public protocolFeeRecipient;

    /// @notice Per-condition creator fee (immutable once set by Factory)
    mapping(bytes32 => uint256) public creatorFeeBps;
    mapping(bytes32 => address) public creatorFeeRecipient;
    mapping(bytes32 => bool) public creatorFeeSet;

    /// @notice Fee accumulators (tracked for withdrawal)
    uint256 public protocolFeesAccumulated;
    mapping(bytes32 => uint256) public creatorFeesAccumulated;

    /// @notice Order fill tracking: orderHash → filled amount (shares)
    mapping(bytes32 => uint256) public ordersFilled;

    /// @notice Cancelled orders
    mapping(bytes32 => bool) public ordersCancelled;

    /// @notice Per-signer sequential nonce
    mapping(address => uint256) public nonces;

    /// @notice Token registration: tokenId → complementary tokenId
    mapping(uint256 => uint256) public complements;

    /// @notice Token → conditionId lookup
    mapping(uint256 => bytes32) public tokenConditions;

    /// @notice Registered conditions
    mapping(bytes32 => bool) public registeredConditions;

    /// @notice Per-condition pause (from resolution or admin)
    mapping(bytes32 => bool) public conditionPaused;

    // ============================================================
    // Events
    // ============================================================

    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed maker,
        address indexed taker,
        uint256 tokenId,
        uint256 fillAmount,
        uint256 usdcAmount,
        uint256 fee,
        Side side
    );

    event OrdersMatched(
        bytes32 indexed takerHash,
        bytes32 indexed makerHash,
        MatchType matchType,
        uint256 fillAmount
    );

    event OrderCancelled(bytes32 indexed orderHash, address indexed maker);
    event NonceBumped(address indexed signer, uint256 oldNonce, uint256 newNonce);
    event ConditionPaused(bytes32 indexed conditionId);
    event ConditionUnpaused(bytes32 indexed conditionId);

    // ============================================================
    // Errors
    // ============================================================

    error NotAdmin();
    error NotOperator();
    error NotFactory();
    error ExchangePaused();
    error ConditionIsPaused();
    error OrderExpired();
    error InvalidNonce();
    error FeeExceedsMax();
    error InvalidSignature();
    error OrderAlreadyCancelled();
    error InsufficientFillCapacity();
    error TokenNotRegistered();
    error CreatorFeeAlreadySet();
    error InvalidTaker();
    error ZeroFillAmount();

    // ============================================================
    // Modifiers
    // ============================================================

    modifier onlyAdmin() { if (msg.sender != admin) revert NotAdmin(); _; }
    modifier onlyOperator() { if (msg.sender != operator) revert NotOperator(); _; }
    modifier onlyFactory() { if (msg.sender != factory) revert NotFactory(); _; }
    modifier whenNotPaused() { if (paused) revert ExchangePaused(); _; }

    // ============================================================
    // Constructor
    // ============================================================

    constructor(
        address _admin,
        address _operator,
        address _shareToken,
        address _vault,
        address _delegationRegistry,
        address _protocolFeeRecipient,
        uint256 _protocolFeeBps
    ) EIP712("FlipCoinExchange", "1") {
        require(_admin != address(0) && _operator != address(0), "zero addr");
        admin = _admin;
        operator = _operator;
        shareToken = ShareToken(_shareToken);
        vault = VaultV2(_vault);
        delegationRegistry = DelegationRegistry(_delegationRegistry);
        protocolFeeRecipient = _protocolFeeRecipient;
        protocolFeeBps = _protocolFeeBps;
    }

    // ============================================================
    // Core: Match Orders
    // ============================================================

    /**
     * @notice Match a taker order against one maker order
     * @param takerOrder The taker's order
     * @param makerOrder The maker's order
     * @param fillAmount Amount to fill (in shares)
     * @param takerSig Taker's EIP-712 signature
     * @param makerSig Maker's EIP-712 signature
     * @param matchType Settlement mode (COMPLEMENTARY, MINT, or MERGE)
     */
    function matchOrders(
        Order calldata takerOrder,
        Order calldata makerOrder,
        uint256 fillAmount,
        bytes calldata takerSig,
        bytes calldata makerSig,
        MatchType matchType
    ) external onlyOperator nonReentrant whenNotPaused {
        if (fillAmount == 0) revert ZeroFillAmount();

        // Validate both orders
        bytes32 takerHash = _validateOrder(takerOrder, takerSig);
        bytes32 makerHash = _validateOrder(makerOrder, makerSig);

        // Check taker restriction
        if (takerOrder.taker != address(0) && takerOrder.taker != makerOrder.maker) revert InvalidTaker();
        if (makerOrder.taker != address(0) && makerOrder.taker != takerOrder.maker) revert InvalidTaker();

        // Determine condition and check pause
        bytes32 conditionId = tokenConditions[takerOrder.tokenId];
        require(conditionId != bytes32(0), "taker token not registered");
        if (conditionPaused[conditionId]) revert ConditionIsPaused();

        // Check fill capacity
        require(
            ordersFilled[takerHash] + fillAmount <= _getOrderShares(takerOrder),
            "taker fill capacity"
        );
        require(
            ordersFilled[makerHash] + fillAmount <= _getOrderShares(makerOrder),
            "maker fill capacity"
        );

        // Validate match type
        _validateMatchType(takerOrder, makerOrder, matchType);

        // Calculate fees
        uint256 totalFee = _getTotalFeeBps(conditionId);
        _checkMaxFee(takerOrder, totalFee);
        _checkMaxFee(makerOrder, totalFee);

        // Execute settlement
        _settle(takerOrder, makerOrder, fillAmount, matchType, conditionId, totalFee);

        // Update fill amounts
        ordersFilled[takerHash] += fillAmount;
        ordersFilled[makerHash] += fillAmount;

        // Record delegation spend for delegated signers
        // For MINT both orders are buys; for MERGE both are sells; COMPLEMENTARY: taker=buy, maker=sell
        if (takerOrder.signer != takerOrder.maker) {
            bool takerIsBuy = (matchType == MatchType.MINT || matchType == MatchType.COMPLEMENTARY);
            uint256 takerNotional = _getNotional(takerOrder, takerIsBuy, fillAmount);
            delegationRegistry.recordSpend(takerOrder.maker, takerOrder.signer, takerNotional);
        }
        if (makerOrder.signer != makerOrder.maker) {
            bool makerIsBuy = (matchType == MatchType.MINT);
            uint256 makerNotional = _getNotional(makerOrder, makerIsBuy, fillAmount);
            delegationRegistry.recordSpend(makerOrder.maker, makerOrder.signer, makerNotional);
        }

        emit OrdersMatched(takerHash, makerHash, matchType, fillAmount);
    }

    // ============================================================
    // Order Management
    // ============================================================

    /**
     * @notice Cancel an order
     */
    function cancelOrder(Order calldata order) external {
        require(msg.sender == order.maker, "not maker");
        bytes32 digest = _hashTypedDataV4(_hashOrder(order));
        ordersCancelled[digest] = true;
        emit OrderCancelled(digest, order.maker);
    }

    /**
     * @notice Bump nonce to invalidate all orders with lower nonces
     */
    function bumpNonce(uint256 newNonce) external {
        require(newNonce > nonces[msg.sender], "nonce not increased");
        uint256 old = nonces[msg.sender];
        nonces[msg.sender] = newNonce;
        emit NonceBumped(msg.sender, old, newNonce);
    }

    // ============================================================
    // Factory Functions
    // ============================================================

    /**
     * @notice Register YES/NO token pair for a condition
     */
    function registerToken(uint256 yesTokenId, uint256 noTokenId, bytes32 conditionId)
        external onlyFactory
    {
        require(!registeredConditions[conditionId], "already registered");

        complements[yesTokenId] = noTokenId;
        complements[noTokenId] = yesTokenId;
        tokenConditions[yesTokenId] = conditionId;
        tokenConditions[noTokenId] = conditionId;
        registeredConditions[conditionId] = true;
    }

    /**
     * @notice Set creator fee for a condition (IMMUTABLE, once only)
     */
    function setCreatorFee(bytes32 conditionId, address creator, uint256 feeBps)
        external onlyFactory
    {
        if (creatorFeeSet[conditionId]) revert CreatorFeeAlreadySet();
        creatorFeeBps[conditionId] = feeBps;
        creatorFeeRecipient[conditionId] = creator;
        creatorFeeSet[conditionId] = true;
    }

    // ============================================================
    // Condition Pause (from ShareToken resolution or admin)
    // ============================================================

    function pauseCondition(bytes32 conditionId) external {
        require(
            msg.sender == address(shareToken) || msg.sender == admin,
            "not shareToken or admin"
        );
        conditionPaused[conditionId] = true;
        emit ConditionPaused(conditionId);
    }

    function unpauseCondition(bytes32 conditionId) external onlyAdmin {
        conditionPaused[conditionId] = false;
        emit ConditionUnpaused(conditionId);
    }

    // ============================================================
    // Fee Withdrawal
    // ============================================================

    function withdrawProtocolFees() external {
        require(msg.sender == protocolFeeRecipient || msg.sender == admin, "not authorized");
        uint256 amount = protocolFeesAccumulated;
        require(amount > 0, "no fees");
        protocolFeesAccumulated = 0;
        vault.withdrawFeePool(protocolFeeRecipient, amount);
    }

    function withdrawCreatorFees(bytes32 conditionId) external {
        address creator = creatorFeeRecipient[conditionId];
        require(msg.sender == creator || msg.sender == admin, "not authorized");
        uint256 amount = creatorFeesAccumulated[conditionId];
        require(amount > 0, "no fees");
        creatorFeesAccumulated[conditionId] = 0;
        vault.withdrawFeePool(creator, amount);
    }

    // ============================================================
    // Admin
    // ============================================================

    function setOperator(address _operator) external onlyAdmin {
        operator = _operator;
    }

    function setFactory(address _factory) external onlyAdmin {
        factory = _factory;
    }

    function setProtocolFeeBps(uint256 _feeBps) external onlyAdmin {
        require(_feeBps <= 500, "fee too high"); // Max 5%
        protocolFeeBps = _feeBps;
    }

    function pause() external onlyAdmin { paused = true; }
    function unpause() external onlyAdmin { paused = false; }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "zero");
        admin = newAdmin;
    }

    // ============================================================
    // Views
    // ============================================================

    function getOrderHash(Order calldata order) external view returns (bytes32) {
        return _hashTypedDataV4(_hashOrder(order));
    }

    function getTotalFeeBps(bytes32 conditionId) external view returns (uint256) {
        return _getTotalFeeBps(conditionId);
    }

    // ============================================================
    // Internal — Order Validation
    // ============================================================

    function _validateOrder(Order calldata order, bytes calldata sig)
        internal view returns (bytes32 orderHash)
    {
        orderHash = _hashOrder(order);
        bytes32 digest = _hashTypedDataV4(orderHash);

        // Check cancelled
        if (ordersCancelled[digest]) revert OrderAlreadyCancelled();

        // Check expiration
        if (order.expiration > 0 && block.timestamp > order.expiration) revert OrderExpired();

        // Check nonce
        if (order.nonce < nonces[order.signer]) revert InvalidNonce();

        // Check token registered
        if (tokenConditions[order.tokenId] == bytes32(0)) revert TokenNotRegistered();

        // Verify signature
        if (order.sigType == SignatureType.EOA) {
            address recovered = ECDSA.recover(digest, sig);
            if (recovered != order.signer) revert InvalidSignature();
        } else {
            // EIP-1271
            (bool success, bytes memory result) = order.signer.staticcall(
                abi.encodeWithSelector(IERC1271.isValidSignature.selector, digest, sig)
            );
            if (!success || result.length < 32) revert InvalidSignature();
            bytes4 magic = abi.decode(result, (bytes4));
            if (magic != EIP1271_MAGIC) revert InvalidSignature();
        }

        // If signer != maker, check delegation
        if (order.signer != order.maker) {
            bytes32 conditionId = tokenConditions[order.tokenId];
            require(
                delegationRegistry.isAuthorized(
                    order.maker, order.signer, address(this), conditionId
                ),
                "not delegated"
            );
        }
    }

    // ============================================================
    // Internal — Match Type Derivation
    // ============================================================

    function _validateMatchType(Order calldata taker, Order calldata maker, MatchType matchType)
        internal view
    {
        bytes32 takerCondition = tokenConditions[taker.tokenId];
        bytes32 makerCondition = tokenConditions[maker.tokenId];
        require(takerCondition == makerCondition, "condition mismatch");

        if (taker.tokenId == maker.tokenId) {
            require(matchType == MatchType.COMPLEMENTARY, "same token must be COMPLEMENTARY");
        } else {
            require(complements[taker.tokenId] == maker.tokenId, "not complement");
            require(
                matchType == MatchType.MINT || matchType == MatchType.MERGE,
                "different tokens must be MINT or MERGE"
            );
        }
    }

    // ============================================================
    // Internal — Settlement
    // ============================================================

    function _settle(
        Order calldata takerOrder,
        Order calldata makerOrder,
        uint256 fillAmount,
        MatchType matchType,
        bytes32 conditionId,
        uint256 totalFee
    ) internal {
        if (matchType == MatchType.COMPLEMENTARY) {
            _settleComplementary(takerOrder, makerOrder, fillAmount, totalFee, conditionId);
        } else if (matchType == MatchType.MINT) {
            _settleMint(takerOrder, makerOrder, fillAmount, totalFee, conditionId);
        } else {
            _settleMerge(takerOrder, makerOrder, fillAmount, totalFee, conditionId);
        }
    }

    function _settleComplementary(
        Order calldata buyer,
        Order calldata seller,
        uint256 fillAmount,
        uint256 totalFeeBps_,
        bytes32 conditionId
    ) internal {
        uint256 priceBps = _getPriceBuy(buyer);
        uint256 usdcAmount = fillAmount * priceBps / BPS;
        uint256 fee = _calculateFee(totalFeeBps_, priceBps, fillAmount);

        // Buyer pays USDC to seller
        vault.transferBetween(buyer.maker, seller.maker, usdcAmount);

        // Seller transfers shares to buyer
        shareToken.safeTransferFrom(seller.maker, buyer.maker, buyer.tokenId, fillAmount, "");

        // Collect fees from both sides
        _collectFees(buyer.maker, seller.maker, fee, conditionId);

        _emitFills(buyer, seller, fillAmount, usdcAmount, fee);
    }

    function _settleMint(
        Order calldata buyer1,
        Order calldata buyer2,
        uint256 fillAmount,
        uint256 totalFeeBps_,
        bytes32 conditionId
    ) internal {
        uint256 price1 = _getPriceBuy(buyer1);
        uint256 price2 = _getPriceBuy(buyer2);
        uint256 usdc1 = fillAmount * price1 / BPS;
        uint256 usdc2 = fillAmount * price2 / BPS;
        uint256 fee1 = _calculateFee(totalFeeBps_, price1, fillAmount);
        uint256 fee2 = _calculateFee(totalFeeBps_, price2, fillAmount);

        // Lock USDC for split (from both buyers combined = fillAmount in USDC face value)
        // splitReserve needs fillAmount (1 share pair = $1)
        vault.lockForSplit(buyer1.maker, usdc1);
        vault.lockForSplit(buyer2.maker, usdc2);

        // Mint shares via ShareToken
        shareToken.splitPosition(conditionId, address(this), fillAmount);

        // Distribute tokens
        shareToken.safeTransferFrom(address(this), buyer1.maker, buyer1.tokenId, fillAmount, "");
        shareToken.safeTransferFrom(address(this), buyer2.maker, buyer2.tokenId, fillAmount, "");

        // Collect fees
        _collectFees(buyer1.maker, buyer2.maker, (fee1 + fee2) / 2, conditionId);

        _emitFills(buyer1, buyer2, fillAmount, usdc1, fee1);
    }

    function _settleMerge(
        Order calldata seller1,
        Order calldata seller2,
        uint256 fillAmount,
        uint256 totalFeeBps_,
        bytes32 conditionId
    ) internal {
        uint256 price1 = _getPriceSell(seller1);
        uint256 price2 = _getPriceSell(seller2);
        uint256 usdc1 = fillAmount * price1 / BPS;
        uint256 usdc2 = fillAmount * price2 / BPS;
        uint256 fee1 = _calculateFee(totalFeeBps_, price1, fillAmount);
        uint256 fee2 = _calculateFee(totalFeeBps_, price2, fillAmount);

        // Transfer shares from sellers to this contract
        shareToken.safeTransferFrom(seller1.maker, address(this), seller1.tokenId, fillAmount, "");
        shareToken.safeTransferFrom(seller2.maker, address(this), seller2.tokenId, fillAmount, "");

        // Merge positions → release USDC from splitReserve
        shareToken.mergePositions(conditionId, address(this), fillAmount);
        vault.releaseFromMerge(address(this), fillAmount);

        // Pay sellers from released USDC (minus fees)
        vault.transferBetween(address(this), seller1.maker, usdc1 - fee1);
        vault.transferBetween(address(this), seller2.maker, usdc2 - fee2);

        // Collect fees
        vault.accumulateFee(address(this), fee1 + fee2);
        _recordFees(fee1 + fee2, conditionId);

        _emitFills(seller1, seller2, fillAmount, usdc1, fee1);
    }

    // ============================================================
    // Internal — Fee Calculation
    // ============================================================

    function _getTotalFeeBps(bytes32 conditionId) internal view returns (uint256) {
        return protocolFeeBps + creatorFeeBps[conditionId];
    }

    function _checkMaxFee(Order calldata order, uint256 totalFee) internal pure {
        if (totalFee > order.maxFeeBps) revert FeeExceedsMax();
    }

    /**
     * @notice Calculate fee: totalFeeBps * min(price, BPS-price) * fillAmount / BPS²
     */
    function _calculateFee(uint256 totalFeeBps_, uint256 priceBps, uint256 fillAmount)
        internal pure returns (uint256)
    {
        uint256 minPrice = priceBps < BPS - priceBps ? priceBps : BPS - priceBps;
        return totalFeeBps_ * minPrice * fillAmount / BPS / BPS;
    }

    /**
     * @notice Get price in BPS — buy order convention (makerAmount=USDC, takerAmount=shares)
     */
    function _getPriceBuy(Order calldata order) internal pure returns (uint256) {
        if (order.takerAmount == 0) return 0;
        return order.makerAmount * BPS / order.takerAmount;
    }

    /**
     * @notice Get price in BPS — sell order convention (makerAmount=shares, takerAmount=USDC)
     */
    function _getPriceSell(Order calldata order) internal pure returns (uint256) {
        if (order.makerAmount == 0) return 0;
        return order.takerAmount * BPS / order.makerAmount;
    }

    /**
     * @notice Get USDC notional for an order given the match context
     * @dev Buy: notional = fillAmount * makerAmount / takerAmount (USDC per share * shares)
     *      Sell: notional = fillAmount * takerAmount / makerAmount (USDC per share * shares)
     */
    function _getNotional(Order calldata order, bool isBuy, uint256 fillAmount) internal pure returns (uint256) {
        if (isBuy) {
            if (order.takerAmount == 0) return 0;
            return fillAmount * order.makerAmount / order.takerAmount;
        } else {
            if (order.makerAmount == 0) return 0;
            return fillAmount * order.takerAmount / order.makerAmount;
        }
    }

    function _getOrderShares(Order calldata order) internal pure returns (uint256) {
        // Shares is always the token amount
        // Buy: takerAmount = shares wanted
        // Sell: makerAmount = shares offered
        return order.takerAmount > order.makerAmount ? order.takerAmount : order.makerAmount;
    }

    function _collectFees(
        address from1,
        address from2,
        uint256 feePerSide,
        bytes32 conditionId
    ) internal {
        if (feePerSide > 0) {
            vault.accumulateFee(from1, feePerSide);
            vault.accumulateFee(from2, feePerSide);
            _recordFees(feePerSide * 2, conditionId);
        }
    }

    function _recordFees(uint256 totalFee, bytes32 conditionId) internal {
        uint256 total = _getTotalFeeBps(conditionId);
        if (total == 0) return;
        uint256 protocolShare = totalFee * protocolFeeBps / total;
        uint256 creatorShare = totalFee - protocolShare;
        protocolFeesAccumulated += protocolShare;
        creatorFeesAccumulated[conditionId] += creatorShare;
    }

    function _emitFills(
        Order calldata order1,
        Order calldata order2,
        uint256 fillAmount,
        uint256 usdcAmount,
        uint256 fee
    ) internal {
        bytes32 hash1 = _hashOrder(order1);
        bytes32 hash2 = _hashOrder(order2);
        emit OrderFilled(hash1, order1.maker, order2.maker, order1.tokenId, fillAmount, usdcAmount, fee, order1.side);
        emit OrderFilled(hash2, order2.maker, order1.maker, order2.tokenId, fillAmount, usdcAmount, fee, order2.side);
    }

    // ============================================================
    // Internal — Order Hashing
    // ============================================================

    function _hashOrder(Order calldata order) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            ORDER_TYPEHASH,
            order.salt,
            order.maker,
            order.signer,
            order.taker,
            order.tokenId,
            order.makerAmount,
            order.takerAmount,
            order.expiration,
            order.nonce,
            order.maxFeeBps,
            uint8(order.side),
            uint8(order.sigType)
        ));
    }

    // ============================================================
    // ERC-1155 Receiver (needed for MINT/MERGE settlement)
    // ============================================================

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external pure returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external pure returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}
