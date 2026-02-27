// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {MarketParams, MarketConfigV2, MarketInfo} from "./interfaces/Types.sol";
import {ShareToken} from "./ShareToken.sol";
import {VaultV2} from "./VaultV2.sol";
import {Exchange} from "./Exchange.sol";
import {BackstopRouter} from "./BackstopRouter.sol";
import {DelegationRegistry} from "./DelegationRegistry.sol";
import {MarketLMSR} from "./MarketLMSR.sol";

/**
 * @title FactoryV2
 * @notice Creates v2 prediction markets with Hybrid CLOB + LMSR architecture
 * @dev Uses EIP-1167 minimal proxies for MarketLMSR clones (~45 bytes each).
 *
 * Three creation modes (Agent API compatible):
 *   1. createMarket() — msg.sender = creator (direct)
 *   2. createMarketFor() — EIP-712 meta-tx, signer = creator (Mode A)
 *   3. createMarketForDelegated() — EIP-712 meta-tx with DelegationRegistry (Mode B)
 *
 * EIP-712 typehashes are IDENTICAL to v1 FactoryLMSR for Agent API backwards compatibility.
 *
 * Internal flow (_createMarketInternal):
 *   1. Validate params
 *   2. Compute b = seed / ln(2)
 *   3. shareToken.prepareCondition() → conditionId, yesTokenId, noTokenId
 *   4. exchange.setCreatorFee(conditionId, creator, creatorFeeBps)
 *   5. exchange.registerToken(yesTokenId, noTokenId, conditionId)
 *   6. Clones.clone(marketImplementation) → market
 *   7. MarketLMSR(market).initConfig(configV2)
 *   8. shareToken.addAuthorizedCaller(market) — for split/merge
 *   9. backstopRouter.registerBackstop(conditionId, market)
 *  10. vault.addWhitelistedMarket(market)
 *  11. vault.pullForNewMarket(creator, market, seedUsdc)
 *  12. MarketLMSR(market).initialize(b, seedUsdc, initialPriceYesBps)
 *
 * See HYBRID_SPEC_v5.2 §9 for full specification.
 */
contract FactoryV2 is EIP712 {
    using ECDSA for bytes32;

    // ============================================================
    // Constants — EIP-712 Typehashes (SAME as v1 for Agent API compat)
    // ============================================================

    /// @notice CreateMarket typehash (Mode A: owner signs directly)
    bytes32 public constant CREATE_MARKET_TYPEHASH = keccak256(
        "CreateMarket(bytes32 paramsHash,uint256 seedUsdc,uint256 initialPriceYesBps,"
        "uint256 nonce,uint256 deadline,bytes32 requestId)"
    );

    /// @notice DelegatedCreateMarket typehash (Mode B: session key signs on behalf of owner)
    bytes32 public constant DELEGATED_CREATE_TYPEHASH = keccak256(
        "DelegatedCreateMarket(bytes32 paramsHash,uint256 seedUsdc,uint256 initialPriceYesBps,"
        "uint256 nonce,uint256 deadline,bytes32 requestId,address owner)"
    );

    // ============================================================
    // State — Immutable
    // ============================================================

    /// @notice EIP-1167: address of the deployed MarketLMSR implementation
    address public immutable marketImplementation;

    // ============================================================
    // State — Core References
    // ============================================================

    ShareToken public shareToken;
    VaultV2 public vault;
    Exchange public exchange;
    BackstopRouter public backstopRouter;
    DelegationRegistry public delegationRegistry;

    // ============================================================
    // State — Config
    // ============================================================

    struct Config {
        address admin;
        address protocolAddress;
        uint16 defaultCreatorFeeBps;
        uint16 defaultMakerFeeBps;
        uint16 defaultTakerFeeBps;
        uint64 minMarketDuration;
        uint64 maxMarketDuration;
    }

    Config public config;
    bool public creationPaused;
    uint64 public nextMarketId;

    // ============================================================
    // State — Markets
    // ============================================================

    mapping(uint64 => MarketInfo) public markets;
    mapping(address => uint64) public marketIdByAddress;
    mapping(bytes32 => address) public marketByConditionId;

    // ============================================================
    // State — Meta-Tx / Replay Protection
    // ============================================================

    /// @notice Nonces for EIP-712 replay protection (per-signer)
    mapping(address => uint256) public nonces;

    /// @notice On-chain idempotency: tracks used requestIds
    mapping(bytes32 => bool) public usedRequestIds;

    /// @notice Trusted relayers that can submit meta-transactions
    mapping(address => bool) public trustedRelayers;

    // ============================================================
    // Events
    // ============================================================

    event MarketV2Created(
        uint64 indexed marketId,
        address indexed market,
        address indexed creator,
        bytes32 conditionId,
        int256 b,
        uint256 seedUsdc,
        uint256 initialPriceYesBps,
        uint64 deadline
    );

    event MarketCreatedViaRelayer(
        uint64 indexed marketId,
        address indexed market,
        address indexed creator,
        address relayer,
        bytes32 requestId
    );

    event CreationPaused(address indexed admin);
    event CreationUnpaused(address indexed admin);
    event AdminTransferred(address oldAdmin, address newAdmin);
    event RelayerAdded(address indexed relayer);
    event RelayerRemoved(address indexed relayer);

    // ============================================================
    // Errors
    // ============================================================

    error NotAdmin();
    error CreationIsPaused();
    error SeedTooLow();
    error SeedTooHigh();
    error PriceOutOfRange();
    error DurationTooShort();
    error DurationTooLong();
    error QuestionRequired();
    error SignatureExpired();
    error InvalidSignature();
    error RequestAlreadyUsed();
    error NotRelayer();
    error NotDelegated();

    // ============================================================
    // Modifiers
    // ============================================================

    modifier onlyAdmin() {
        if (msg.sender != config.admin) revert NotAdmin();
        _;
    }

    // ============================================================
    // Constructor
    // ============================================================

    constructor(
        address _admin,
        address _protocolAddress,
        address _marketImplementation,
        address _vault,
        address _shareToken,
        address _exchange,
        address _backstopRouter,
        address _delegationRegistry,
        uint16 _defaultCreatorFeeBps,
        uint16 _defaultMakerFeeBps,
        uint16 _defaultTakerFeeBps,
        uint64 _minMarketDuration,
        uint64 _maxMarketDuration
    ) EIP712("FlipCoin Factory", "1") {
        require(_admin != address(0), "zero admin");
        require(_marketImplementation != address(0), "zero impl");
        require(_vault != address(0), "zero vault");
        require(_shareToken != address(0), "zero shareToken");
        require(_exchange != address(0), "zero exchange");
        require(_backstopRouter != address(0), "zero backstopRouter");

        marketImplementation = _marketImplementation;
        vault = VaultV2(_vault);
        shareToken = ShareToken(_shareToken);
        exchange = Exchange(_exchange);
        backstopRouter = BackstopRouter(_backstopRouter);
        delegationRegistry = DelegationRegistry(_delegationRegistry);

        config = Config({
            admin: _admin,
            protocolAddress: _protocolAddress,
            defaultCreatorFeeBps: _defaultCreatorFeeBps,
            defaultMakerFeeBps: _defaultMakerFeeBps,
            defaultTakerFeeBps: _defaultTakerFeeBps,
            minMarketDuration: _minMarketDuration,
            maxMarketDuration: _maxMarketDuration
        });

        nextMarketId = 1;
    }

    // ============================================================
    // Mode 0: Direct Market Creation
    // ============================================================

    /**
     * @notice Create a market (msg.sender = creator)
     * @param params Market parameters (question, description, etc.)
     * @param seedUsdc Initial USDC liquidity (6 decimals)
     * @param initialPriceYesBps Initial YES price in basis points (100-9900)
     * @return market Address of the new MarketLMSR clone
     */
    function createMarket(
        MarketParams calldata params,
        uint256 seedUsdc,
        uint256 initialPriceYesBps
    ) external returns (address market) {
        return _createMarketInternal(params, seedUsdc, initialPriceYesBps, msg.sender);
    }

    // ============================================================
    // Mode A: Meta-Tx createMarketFor (owner signs directly)
    // ============================================================

    /**
     * @notice Create a market via EIP-712 meta-transaction (Mode A)
     * @dev Agent API compatible — same typehash as v1 FactoryLMSR
     * @param params Market parameters
     * @param seedUsdc Initial USDC liquidity
     * @param initialPriceYesBps Initial YES price (bps)
     * @param creator The signer / creator address
     * @param deadline Signature expiry timestamp
     * @param requestId On-chain idempotency key
     * @param v ECDSA v
     * @param r ECDSA r
     * @param s ECDSA s
     */
    function createMarketFor(
        MarketParams calldata params,
        uint256 seedUsdc,
        uint256 initialPriceYesBps,
        address creator,
        uint256 deadline,
        bytes32 requestId,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (address market) {
        if (!trustedRelayers[msg.sender]) revert NotRelayer();
        if (block.timestamp > deadline) revert SignatureExpired();
        require(creator != address(0), "zero creator");
        if (usedRequestIds[requestId]) revert RequestAlreadyUsed();

        // Verify EIP-712 signature
        bytes32 paramsHash = _computeParamsHash(params);
        uint256 currentNonce = nonces[creator];

        bytes32 structHash = keccak256(abi.encode(
            CREATE_MARKET_TYPEHASH,
            paramsHash,
            seedUsdc,
            initialPriceYesBps,
            currentNonce,
            deadline,
            requestId
        ));

        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = ECDSA.recover(digest, v, r, s);
        if (recovered != creator) revert InvalidSignature();

        // Effects
        usedRequestIds[requestId] = true;
        nonces[creator] = currentNonce + 1;

        // Create market
        market = _createMarketInternal(params, seedUsdc, initialPriceYesBps, creator);

        emit MarketCreatedViaRelayer(
            marketIdByAddress[market], market, creator, msg.sender, requestId
        );
    }

    // ============================================================
    // Mode B: Meta-Tx createMarketForDelegated (session key signs)
    // ============================================================

    /**
     * @notice Create a market via delegated EIP-712 meta-transaction (Mode B)
     * @dev Uses DelegationRegistry instead of local delegatedSigners mapping.
     *      Agent API compatible — same typehash as v1 FactoryLMSR.
     * @param params Market parameters
     * @param seedUsdc Initial USDC liquidity
     * @param initialPriceYesBps Initial YES price (bps)
     * @param owner The funds owner (creator = owner)
     * @param signer The delegated session key
     * @param deadline Signature expiry timestamp
     * @param requestId On-chain idempotency key
     * @param v ECDSA v
     * @param r ECDSA r
     * @param s ECDSA s
     */
    function createMarketForDelegated(
        MarketParams calldata params,
        uint256 seedUsdc,
        uint256 initialPriceYesBps,
        address owner,
        address signer,
        uint256 deadline,
        bytes32 requestId,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (address market) {
        if (!trustedRelayers[msg.sender]) revert NotRelayer();
        if (block.timestamp > deadline) revert SignatureExpired();
        require(owner != address(0), "zero owner");
        require(signer != address(0), "zero signer");
        if (usedRequestIds[requestId]) revert RequestAlreadyUsed();

        // Check delegation via DelegationRegistry (v2 replaces local mapping)
        if (!delegationRegistry.isAuthorized(owner, signer, address(this), bytes32(0))) {
            revert NotDelegated();
        }

        // Verify EIP-712 signature
        bytes32 paramsHash = _computeParamsHash(params);
        uint256 currentNonce = nonces[signer];

        bytes32 structHash = keccak256(abi.encode(
            DELEGATED_CREATE_TYPEHASH,
            paramsHash,
            seedUsdc,
            initialPriceYesBps,
            currentNonce,
            deadline,
            requestId,
            owner
        ));

        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = ECDSA.recover(digest, v, r, s);
        if (recovered != signer) revert InvalidSignature();

        // Effects
        usedRequestIds[requestId] = true;
        nonces[signer] = currentNonce + 1;

        // Create market (creator = owner, NOT signer)
        market = _createMarketInternal(params, seedUsdc, initialPriceYesBps, owner);

        // Record delegation spend (seedUsdc as notional)
        delegationRegistry.recordSpend(owner, signer, seedUsdc);

        emit MarketCreatedViaRelayer(
            marketIdByAddress[market], market, owner, msg.sender, requestId
        );
    }

    // ============================================================
    // Views
    // ============================================================

    function getMarketById(uint64 id) external view returns (address) {
        return markets[id].market;
    }

    function getMarketByCondition(bytes32 conditionId) external view returns (address) {
        return marketByConditionId[conditionId];
    }

    function getMarketInfo(uint64 id) external view returns (MarketInfo memory) {
        return markets[id];
    }

    // ============================================================
    // Admin Functions
    // ============================================================

    function pauseCreation() external onlyAdmin {
        require(!creationPaused, "already paused");
        creationPaused = true;
        emit CreationPaused(msg.sender);
    }

    function unpauseCreation() external onlyAdmin {
        require(creationPaused, "not paused");
        creationPaused = false;
        emit CreationUnpaused(msg.sender);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "zero address");
        address oldAdmin = config.admin;
        config.admin = newAdmin;
        emit AdminTransferred(oldAdmin, newAdmin);
    }

    function addRelayer(address relayer) external onlyAdmin {
        require(relayer != address(0), "zero address");
        require(!trustedRelayers[relayer], "already relayer");
        trustedRelayers[relayer] = true;
        emit RelayerAdded(relayer);
    }

    function removeRelayer(address relayer) external onlyAdmin {
        require(trustedRelayers[relayer], "not relayer");
        trustedRelayers[relayer] = false;
        emit RelayerRemoved(relayer);
    }

    // ============================================================
    // Internal — Core Market Creation
    // ============================================================

    function _createMarketInternal(
        MarketParams calldata params,
        uint256 seedUsdc,
        uint256 initialPriceYesBps,
        address creator
    ) internal returns (address market) {
        if (creationPaused) revert CreationIsPaused();

        // ── 1. Validate params ──
        _validateParams(params);
        _validateSeedAndPrice(seedUsdc, initialPriceYesBps);

        // Explicit deadline check: must be in the future (prevents underflow in duration calc)
        require(params.deadline > uint64(block.timestamp), "deadline in the past");

        uint64 duration = params.deadline - uint64(block.timestamp);
        if (duration < config.minMarketDuration) revert DurationTooShort();
        if (duration > config.maxMarketDuration) revert DurationTooLong();

        // ── 2. Compute b = seed / ln(2) in SD59x18 ──
        int256 b = int256((seedUsdc * 1e18 * 1e12) / 693147180559945309);
        require(b > 0, "invalid b");

        // ── 3. Prepare condition in ShareToken ──
        bytes32 questionId = keccak256(abi.encode(
            params.question,
            params.description,
            params.deadline,
            creator,
            block.timestamp
        ));

        address usdc = address(vault.usdc());
        bytes32 conditionId = shareToken.prepareCondition(
            config.admin, // oracle = admin
            questionId,
            usdc,
            params.deadline
        );

        // Get token IDs from ShareToken
        (uint256 yesId, uint256 noId) = shareToken.getTokenIds(conditionId, usdc);

        // ── 4. Register in Exchange (immutable creator fee) ──
        exchange.setCreatorFee(conditionId, creator, config.defaultCreatorFeeBps);
        exchange.registerToken(yesId, noId, conditionId);

        // ── 5. Clone MarketLMSR via EIP-1167 ──
        market = Clones.clone(marketImplementation);

        // ── 6. Configure the clone ──
        MarketConfigV2 memory mc = MarketConfigV2({
            admin: config.admin,
            creator: creator,
            vault: address(vault),
            factory: address(this),
            backstopRouter: address(backstopRouter),
            shareToken: address(shareToken),
            protocolAddress: config.protocolAddress,
            conditionId: conditionId,
            yesTokenId: yesId,
            noTokenId: noId,
            totalFeeBps: config.defaultCreatorFeeBps + config.defaultMakerFeeBps + config.defaultTakerFeeBps,
            creatorFeeBps: config.defaultCreatorFeeBps,
            protocolFeeBps: config.defaultMakerFeeBps + config.defaultTakerFeeBps,
            deadline: params.deadline,
            question: params.question,
            description: params.description,
            category: params.category,
            resolutionRules: params.resolutionRules,
            resolutionSource: params.resolutionSource,
            imageUrl: params.imageUrl
        });

        MarketLMSR(market).initConfig(mc);

        // ── 7. Authorize market clone for split/merge ──
        shareToken.addAuthorizedCaller(market);

        // ── 8. Register backstop in BackstopRouter ──
        backstopRouter.registerBackstop(conditionId, market);

        // ── 9. Whitelist market in Vault ──
        vault.addWhitelistedMarket(market);

        // ── 10. Pull seed liquidity from creator to market ──
        vault.pullForNewMarket(creator, market, seedUsdc);

        // ── 11. Initialize LMSR ──
        MarketLMSR(market).initialize(b, seedUsdc, initialPriceYesBps);

        // ── 12. Record market ──
        uint64 marketId = nextMarketId++;
        markets[marketId] = MarketInfo({
            marketId: marketId,
            market: market,
            creator: creator,
            conditionId: conditionId,
            deadline: params.deadline,
            createdAt: uint64(block.timestamp)
        });
        marketIdByAddress[market] = marketId;
        marketByConditionId[conditionId] = market;

        emit MarketV2Created(
            marketId, market, creator, conditionId,
            b, seedUsdc, initialPriceYesBps, params.deadline
        );
    }

    // ============================================================
    // Internal — Validation
    // ============================================================

    function _validateParams(MarketParams calldata params) internal pure {
        if (bytes(params.question).length == 0) revert QuestionRequired();
        require(bytes(params.question).length <= 200, "question too long");
        require(bytes(params.description).length <= 1000, "description too long");
        require(bytes(params.category).length <= 50, "category too long");
        require(bytes(params.resolutionRules).length > 0, "resolutionRules required");
        require(bytes(params.resolutionRules).length <= 500, "resolutionRules too long");
        require(bytes(params.resolutionSource).length > 0, "resolutionSource required");
        require(bytes(params.resolutionSource).length <= 300, "resolutionSource too long");
        require(bytes(params.imageUrl).length <= 300, "imageUrl too long");
        require(_startsWithHttps(params.resolutionSource), "resolutionSource must be https");
    }

    function _validateSeedAndPrice(uint256 seedUsdc, uint256 initialPriceYesBps) internal pure {
        if (seedUsdc < 10_000_000) revert SeedTooLow();       // min 10 USDC
        if (seedUsdc > 10_000_000_000) revert SeedTooHigh();   // max 10,000 USDC
        if (initialPriceYesBps < 100 || initialPriceYesBps > 9900) revert PriceOutOfRange();
    }

    // ============================================================
    // Internal — Hashing
    // ============================================================

    function _computeParamsHash(MarketParams calldata params) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            keccak256(bytes(params.question)),
            keccak256(bytes(params.description)),
            keccak256(bytes(params.category)),
            keccak256(bytes(params.resolutionRules)),
            keccak256(bytes(params.resolutionSource)),
            keccak256(bytes(params.imageUrl)),
            params.deadline
        ));
    }

    // ============================================================
    // Internal — Utilities
    // ============================================================

    function _startsWithHttps(string calldata str) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        if (strBytes.length < 8) return false;
        return (
            strBytes[0] == "h" && strBytes[1] == "t" && strBytes[2] == "t" &&
            strBytes[3] == "p" && strBytes[4] == "s" && strBytes[5] == ":" &&
            strBytes[6] == "/" && strBytes[7] == "/"
        );
    }
}
