// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Minimal interface implemented by all market resolver contracts.
// Binary markets: YES wins if finalPrice >= strikePrice.
// Categorical markets: N mutually exclusive outcomes, each a separate marketId (Polymarket pattern).
//
// Note: marketType() was intentionally removed. A unified resolver handles both binary and
// categorical markets, making a contract-level type discriminator meaningless. Per-market
// kind is an implementation detail; the treasury only needs the functions below.
interface IMarketResolver {
    function isResolved(uint64 marketId) external view returns (bool);

    // True if invalidated; all positions are refunded at the vault level.
    function isInvalidated(uint64 marketId) external view returns (bool);

    // Unix timestamp after which claimWinnings is callable. 0 if not yet resolved.
    function claimableAt(uint64 marketId) external view returns (uint64);

    // Returns true if the YES/LONG side won. For categorical markets, true only for the winning
    // outcome's marketId. Reverts if not yet resolved.
    function getOutcome(uint64 marketId) external view returns (bool yesWon);

    // Returns payout in basis points (10_000 = 100%) for the given side.
    // Binary: winning side -> 10_000, losing side -> 0.
    // Categorical: winning marketId -> 10_000, any other outcome -> 0. side param ignored.
    // Reverts if not resolved.
    function getPayoutBps(uint64 marketId, bool side) external view returns (uint16);
}
