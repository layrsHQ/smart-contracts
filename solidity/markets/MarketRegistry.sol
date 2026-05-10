// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IMarketRegistry} from "./interfaces/IMarketRegistry.sol";
import {IMarketResolver} from "./interfaces/IMarketResolver.sol";

contract MarketRegistry is IMarketRegistry {

    address public admin;
    address public pendingAdmin;

    uint64 public nextMarketId;

    mapping(uint64 => address) private _resolvers;
    mapping(address => bool) public approvedFactories;
    mapping(bytes32 => uint64[]) private _groups;

    error NotAdmin();
    error NotApprovedFactory();
    error ZeroAddress();
    error NotRegistered();
    error InvalidOutcomeCount();

    event MarketRegistered(uint64 indexed marketId, address indexed resolver, address indexed factory);
    event GroupRegistered(bytes32 indexed groupId, uint64[] marketIds, address indexed factory);
    event FactoryApproved(address indexed factory, bool approved);
    event AdminTransferInitiated(address indexed current, address indexed pending_);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyFactory() {
        if (!approvedFactories[msg.sender]) revert NotApprovedFactory();
        _;
    }

    constructor(address admin_) {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
    }

    function getResolver(uint64 marketId) external view returns (IMarketResolver) {
        address r = _resolvers[marketId];
        if (r == address(0)) revert NotRegistered();
        return IMarketResolver(r);
    }

    function isRegistered(uint64 marketId) external view returns (bool) {
        return _resolvers[marketId] != address(0);
    }

    function groupMarkets(bytes32 groupId) external view returns (uint64[] memory) {
        return _groups[groupId];
    }

    function registerMarket(address resolver) external onlyFactory returns (uint64 marketId) {
        if (resolver == address(0)) revert ZeroAddress();
        marketId = nextMarketId++;
        _resolvers[marketId] = resolver;
        emit MarketRegistered(marketId, resolver, msg.sender);
    }

    function registerGroup(address resolver, uint8 outcomeCount)
        external
        onlyFactory
        returns (bytes32 groupId, uint64[] memory marketIds)
    {
        if (resolver == address(0)) revert ZeroAddress();
        if (outcomeCount < 2 || outcomeCount > 32) revert InvalidOutcomeCount();

        marketIds = new uint64[](outcomeCount);
        uint64 firstId = nextMarketId;

        for (uint8 i = 0; i < outcomeCount; i++) {
            uint64 mid = nextMarketId++;
            _resolvers[mid] = resolver;
            marketIds[i] = mid;
        }

        groupId = keccak256(abi.encodePacked(address(this), firstId, outcomeCount));
        _groups[groupId] = marketIds;

        emit GroupRegistered(groupId, marketIds, msg.sender);
    }

    function approveFactory(address factory, bool approved) external onlyAdmin {
        if (factory == address(0)) revert ZeroAddress();
        approvedFactories[factory] = approved;
        emit FactoryApproved(factory, approved);
    }

    function transferAdmin(address newAdmin_) external onlyAdmin {
        if (newAdmin_ == address(0)) revert ZeroAddress();
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
