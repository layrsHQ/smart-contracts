// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MarketRegistry} from "./MarketRegistry.sol";
import {MarketResolver} from "./MarketResolver.sol";

contract MarketFactory {

    MarketRegistry public immutable registry;
    MarketResolver public immutable resolver;

    address public admin;
    address public pendingAdmin;
    mapping(address => bool) public operators;

    error NotAdmin();
    error NotOperator();
    error ZeroAddress();
    error InvalidOutcomeCount();

    event BinaryMarketCreated(
        uint64 indexed marketId,
        bytes32 questionHash,
        uint128 strikePrice,
        uint64 expiryTs
    );
    event CategoricalGroupCreated(
        bytes32 indexed groupId,
        bytes32 questionHash,
        uint8 outcomeCount,
        uint64 expiryTs,
        uint64[] marketIds
    );
    event OperatorSet(address indexed operator, bool enabled);
    event AdminTransferInitiated(address indexed current, address indexed pending_);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    modifier onlyAdmin() { if (msg.sender != admin) revert NotAdmin(); _; }
    modifier onlyOperator() { if (!operators[msg.sender] && msg.sender != admin) revert NotOperator(); _; }

    constructor(address registry_, address resolver_, address admin_) {
        if (registry_ == address(0)) revert ZeroAddress();
        if (resolver_ == address(0)) revert ZeroAddress();
        if (admin_ == address(0)) revert ZeroAddress();
        registry = MarketRegistry(registry_);
        resolver = MarketResolver(resolver_);
        admin = admin_;
    }

    function createBinaryMarket(
        bytes32 questionHash,
        uint128 strikePrice,
        uint64 expiryTs
    ) external onlyOperator returns (uint64 marketId) {
        marketId = registry.registerMarket(address(resolver));
        resolver.createBinaryMarket(marketId, questionHash, strikePrice, expiryTs);
        emit BinaryMarketCreated(marketId, questionHash, strikePrice, expiryTs);
    }

    function createCategoricalMarket(
        bytes32 questionHash,
        uint64 expiryTs,
        string[] calldata outcomeLabels
    ) external onlyOperator returns (bytes32 groupId, uint64[] memory marketIds) {
        uint8 n = uint8(outcomeLabels.length);
        if (n < 2 || n > 32) revert InvalidOutcomeCount();

        // groupId is deterministic from registry state; if registry is redeployed this changes
        (groupId, marketIds) = registry.registerGroup(address(resolver), n);
        resolver.registerCategoricalGroup(groupId, marketIds, questionHash, expiryTs, outcomeLabels);

        emit CategoricalGroupCreated(groupId, questionHash, n, expiryTs, marketIds);
    }

    function setOperator(address op, bool enabled) external onlyAdmin {
        if (op == address(0)) revert ZeroAddress();
        operators[op] = enabled;
        emit OperatorSet(op, enabled);
    }

    function transferAdmin(address newAdmin_) external onlyAdmin {
        pendingAdmin = newAdmin_;
        emit AdminTransferInitiated(admin, newAdmin_);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotAdmin();
        emit AdminTransferred(admin, msg.sender);
        admin = msg.sender;
        pendingAdmin = address(0);
    }
}
