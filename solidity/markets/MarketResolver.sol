// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IMarketResolver} from "./interfaces/IMarketResolver.sol";

contract MarketResolver is IMarketResolver {

    enum MarketKind { Binary, Categorical }

    struct BinaryMarket {
        bytes32 questionHash;
        uint128 strikePrice;   // 8-decimal USD (Coinbase format)
        uint64 expiryTs;
        uint64 createdAt;
        uint128 finalPrice;
        uint64 resolvedAt;
        uint64 claimableAt;    // resolvedAt + disputeWindowSecs
        bool resolved;
        bool invalidated;
    }

    struct OutcomeEntry {
        bytes32 groupId;
        uint8 outcomeIndex;
    }

    struct CategoricalGroup {
        bytes32 questionHash;
        uint64 expiryTs;
        uint64 createdAt;
        uint64 resolvedAt;
        uint64 claimableAt;
        uint8 outcomeCount;
        uint8 winningOutcome; // valid only when resolved == true
        bool resolved;
        bool invalidated;
    }

    address public admin;
    address public pendingAdmin;
    bool public paused;
    uint64 public disputeWindowSecs;

    mapping(address => bool) public operators;

    // Kind registry - set once at creation, never changed.
    mapping(uint64 => bool) private _registered;
    mapping(uint64 => MarketKind) private _kinds;

    // Binary state
    mapping(uint64 => BinaryMarket) private _binary;

    // Categorical state
    mapping(uint64 => OutcomeEntry) private _outcomes;
    mapping(bytes32 => CategoricalGroup) private _groups;
    mapping(bytes32 => string[]) private _labels;

    // errors

    error NotAdmin();
    error NotOperator();
    error Paused();
    error ZeroValue();
    error ZeroAddress();
    error ExpiryNotFuture();
    error MarketAlreadyExists();
    error MarketNotExist();
    error GroupAlreadyExists();
    error GroupNotExist();
    error AlreadyResolved();
    error NotExpiredYet();
    error NotResolved();
    error AlreadyInvalidated();
    error DisputeWindowClosed();
    error InvalidOutcomeIndex();
    error InvalidOutcomeCount();
    error LabelMismatch();
    error InvalidWindow();
    error WrongMarketKind();

    // events

    event BinaryMarketCreated(
        uint64 indexed marketId,
        bytes32 questionHash,
        uint128 strikePrice,
        uint64 expiryTs,
        uint64 createdAt
    );
    event BinaryMarketResolved(
        uint64 indexed marketId,
        uint128 finalPrice,
        bool outcome,
        uint64 claimableAt,
        uint64 resolvedAt
    );
    event BinaryMarketInvalidated(uint64 indexed marketId, uint64 invalidatedAt, address caller);

    event CategoricalGroupCreated(
        bytes32 indexed groupId,
        bytes32 questionHash,
        uint8 outcomeCount,
        uint64 expiryTs,
        uint64[] marketIds
    );
    event CategoricalGroupResolved(
        bytes32 indexed groupId,
        uint8 winningOutcome,
        uint64 claimableAt,
        uint64 resolvedAt
    );
    event CategoricalGroupInvalidated(bytes32 indexed groupId, uint64 invalidatedAt, address caller);

    event OperatorSet(address indexed operator, bool enabled);
    event DisputeWindowUpdated(uint64 oldWindow, uint64 newWindow);
    event AdminTransferInitiated(address indexed current, address indexed pending_);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event ContractPaused(address caller);
    event ContractUnpaused(address caller);

    modifier onlyAdmin() { if (msg.sender != admin) revert NotAdmin(); _; }
    modifier onlyOperator() { if (!operators[msg.sender] && msg.sender != admin) revert NotOperator(); _; }
    modifier whenNotPaused() { if (paused) revert Paused(); _; }

    constructor(address admin_) {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
        disputeWindowSecs = 900; // 15 minutes default
    }

    function isResolved(uint64 marketId) external view override returns (bool) {
        _requireRegistered(marketId);
        if (_kinds[marketId] == MarketKind.Binary) {
            return _binary[marketId].resolved;
        }
        return _groups[_outcomes[marketId].groupId].resolved;
    }

    function isInvalidated(uint64 marketId) external view override returns (bool) {
        _requireRegistered(marketId);
        if (_kinds[marketId] == MarketKind.Binary) {
            return _binary[marketId].invalidated;
        }
        return _groups[_outcomes[marketId].groupId].invalidated;
    }

    function claimableAt(uint64 marketId) external view override returns (uint64) {
        _requireRegistered(marketId);
        if (_kinds[marketId] == MarketKind.Binary) {
            return _binary[marketId].claimableAt;
        }
        return _groups[_outcomes[marketId].groupId].claimableAt;
    }

    function getOutcome(uint64 marketId) external view override returns (bool yesWon) {
        _requireRegistered(marketId);
        if (_kinds[marketId] == MarketKind.Binary) {
            BinaryMarket storage m = _binary[marketId];
            if (!m.resolved) revert NotResolved();
            return m.finalPrice >= m.strikePrice;
        }
        OutcomeEntry storage oe = _outcomes[marketId];
        CategoricalGroup storage g = _groups[oe.groupId];
        if (!g.resolved) revert NotResolved();
        return g.winningOutcome == oe.outcomeIndex;
    }

    function getPayoutBps(uint64 marketId, bool side) external view override returns (uint16) {
        _requireRegistered(marketId);
        if (_kinds[marketId] == MarketKind.Binary) {
            BinaryMarket storage m = _binary[marketId];
            if (!m.resolved) revert NotResolved();
            bool yesWon = m.finalPrice >= m.strikePrice;
            return (side == yesWon) ? 10_000 : 0;
        }
        OutcomeEntry storage oe = _outcomes[marketId];
        CategoricalGroup storage g = _groups[oe.groupId];
        if (!g.resolved) revert NotResolved();
        return (g.winningOutcome == oe.outcomeIndex) ? 10_000 : 0;
    }

    // binary markets

    function createBinaryMarket(
        uint64 marketId,
        bytes32 questionHash,
        uint128 strikePrice,
        uint64 expiryTs
    ) external onlyOperator whenNotPaused {
        if (strikePrice == 0) revert ZeroValue();
        if (expiryTs <= uint64(block.timestamp)) revert ExpiryNotFuture();
        if (_registered[marketId]) revert MarketAlreadyExists();

        _registered[marketId] = true;
        _kinds[marketId] = MarketKind.Binary;
        _binary[marketId] = BinaryMarket({
            questionHash: questionHash,
            strikePrice: strikePrice,
            expiryTs: expiryTs,
            createdAt: uint64(block.timestamp),
            finalPrice: 0,
            resolvedAt: 0,
            claimableAt: 0,
            resolved: false,
            invalidated: false
        });

        emit BinaryMarketCreated(marketId, questionHash, strikePrice, expiryTs, uint64(block.timestamp));
    }

    function resolveBinaryMarket(uint64 marketId, uint128 finalPrice)
        external onlyOperator whenNotPaused
    {
        if (finalPrice == 0) revert ZeroValue();
        _requireKind(marketId, MarketKind.Binary);
        BinaryMarket storage m = _binary[marketId];
        if (m.resolved) revert AlreadyResolved();
        if (uint64(block.timestamp) < m.expiryTs) revert NotExpiredYet();

        bool outcome = finalPrice >= m.strikePrice;
        uint64 resolvedAt_ = uint64(block.timestamp);
        uint64 claimableAt_ = resolvedAt_ + disputeWindowSecs;

        m.finalPrice = finalPrice;
        m.resolved = true;
        m.resolvedAt = resolvedAt_;
        m.claimableAt = claimableAt_;

        emit BinaryMarketResolved(marketId, finalPrice, outcome, claimableAt_, resolvedAt_);
    }

    function invalidateBinaryMarket(uint64 marketId) external onlyAdmin {
        _requireKind(marketId, MarketKind.Binary);
        BinaryMarket storage m = _binary[marketId];
        if (!m.resolved) revert NotResolved();
        if (m.invalidated) revert AlreadyInvalidated();
        if (uint64(block.timestamp) >= m.claimableAt) revert DisputeWindowClosed();

        m.invalidated = true;
        emit BinaryMarketInvalidated(marketId, uint64(block.timestamp), msg.sender);
    }

    // categorical markets

    function registerCategoricalGroup(
        bytes32 groupId,
        uint64[] calldata marketIds,
        bytes32 questionHash,
        uint64 expiryTs,
        string[] calldata outcomeLabels
    ) external onlyOperator whenNotPaused {
        uint8 n = uint8(marketIds.length);
        if (n < 2 || n > 32) revert InvalidOutcomeCount();
        if (outcomeLabels.length != n) revert LabelMismatch();
        if (expiryTs <= uint64(block.timestamp)) revert ExpiryNotFuture();
        if (_groups[groupId].createdAt != 0) revert GroupAlreadyExists();

        _groups[groupId] = CategoricalGroup({
            questionHash: questionHash,
            expiryTs: expiryTs,
            createdAt: uint64(block.timestamp),
            resolvedAt: 0,
            claimableAt: 0,
            outcomeCount: n,
            winningOutcome: 0,
            resolved: false,
            invalidated: false
        });

        for (uint8 i = 0; i < n; i++) {
            uint64 mid = marketIds[i];
            if (_registered[mid]) revert MarketAlreadyExists();
            _registered[mid] = true;
            _kinds[mid] = MarketKind.Categorical;
            _outcomes[mid] = OutcomeEntry({ groupId: groupId, outcomeIndex: i });
        }

        string[] storage labels = _labels[groupId];
        for (uint8 i = 0; i < n; i++) {
            labels.push(outcomeLabels[i]);
        }

        emit CategoricalGroupCreated(groupId, questionHash, n, expiryTs, marketIds);
    }

    function resolveCategoricalGroup(bytes32 groupId, uint8 winningOutcome)
        external onlyOperator whenNotPaused
    {
        CategoricalGroup storage g = _requireGroup(groupId);
        if (g.resolved) revert AlreadyResolved();
        if (uint64(block.timestamp) < g.expiryTs) revert NotExpiredYet();
        if (winningOutcome >= g.outcomeCount) revert InvalidOutcomeIndex();

        uint64 resolvedAt_ = uint64(block.timestamp);
        uint64 claimableAt_ = resolvedAt_ + disputeWindowSecs;

        g.winningOutcome = winningOutcome;
        g.resolved = true;
        g.resolvedAt = resolvedAt_;
        g.claimableAt = claimableAt_;

        emit CategoricalGroupResolved(groupId, winningOutcome, claimableAt_, resolvedAt_);
    }

    function invalidateCategoricalGroup(bytes32 groupId) external onlyAdmin {
        CategoricalGroup storage g = _requireGroup(groupId);
        if (!g.resolved) revert NotResolved();
        if (g.invalidated) revert AlreadyInvalidated();
        if (uint64(block.timestamp) >= g.claimableAt) revert DisputeWindowClosed();

        g.invalidated = true;
        emit CategoricalGroupInvalidated(groupId, uint64(block.timestamp), msg.sender);
    }

    function marketKind(uint64 marketId) external view returns (MarketKind) {
        _requireRegistered(marketId);
        return _kinds[marketId];
    }

    function getBinaryMarket(uint64 marketId) external view returns (BinaryMarket memory) {
        _requireKind(marketId, MarketKind.Binary);
        return _binary[marketId];
    }

    function getCategoricalGroup(bytes32 groupId) external view returns (CategoricalGroup memory) {
        return _groups[groupId];
    }

    function getOutcomeLabels(bytes32 groupId) external view returns (string[] memory) {
        return _labels[groupId];
    }

    function getOutcomeEntry(uint64 marketId) external view returns (OutcomeEntry memory) {
        _requireKind(marketId, MarketKind.Categorical);
        return _outcomes[marketId];
    }

    // admin

    function setOperator(address op, bool enabled) external onlyAdmin {
        if (op == address(0)) revert ZeroAddress();
        operators[op] = enabled;
        emit OperatorSet(op, enabled);
    }

    function setDisputeWindow(uint64 secs) external onlyAdmin {
        if (secs < 60 || secs > 7 days) revert InvalidWindow();
        emit DisputeWindowUpdated(disputeWindowSecs, secs);
        disputeWindowSecs = secs;
    }

    function transferAdmin(address newAdmin_) external onlyAdmin {
        if (newAdmin_ == address(0)) revert ZeroAddress();
        pendingAdmin = newAdmin_;
        emit AdminTransferInitiated(admin, newAdmin_);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotAdmin();
        emit AdminTransferred(admin, msg.sender);
        pendingAdmin = address(0);
        admin = msg.sender;
    }

    function pause() external onlyAdmin { paused = true; emit ContractPaused(msg.sender); }
    function unpause() external onlyAdmin { paused = false; emit ContractUnpaused(msg.sender); }

    function _requireRegistered(uint64 marketId) internal view {
        if (!_registered[marketId]) revert MarketNotExist();
    }

    function _requireKind(uint64 marketId, MarketKind expected) internal view {
        if (!_registered[marketId]) revert MarketNotExist();
        if (_kinds[marketId] != expected) revert WrongMarketKind();
    }

    function _requireGroup(bytes32 groupId) internal view returns (CategoricalGroup storage g) {
        g = _groups[groupId];
        if (g.createdAt == 0) revert GroupNotExist();
    }
}
