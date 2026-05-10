// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IMarketResolver} from "./IMarketResolver.sol";

interface IMarketRegistry {
    // Returns the resolver for the given marketId. Reverts if not registered.
    function getResolver(uint64 marketId) external view returns (IMarketResolver);

    function isRegistered(uint64 marketId) external view returns (bool);

    // Returns all marketIds belonging to a categorical group; empty for binary markets.
    function groupMarkets(bytes32 groupId) external view returns (uint64[] memory);
}
