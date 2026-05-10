// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPredictionMarketYieldManager {
    function asset() external view returns (address);
    function yieldStrategy() external view returns (address);
    function yieldVerifier() external view returns (address);
    function yieldPool() external view returns (uint256);
    function feeYieldBps() external view returns (uint256);
    function reserveRatioBps() external view returns (uint256);
    function epochYield() external view returns (uint256);
    function totalLocked() external view returns (uint256);
    function managedAssets() external view returns (uint256);

    function setYieldStrategy(address strategy_) external;
    function setYieldVerifier(address verifier_) external;
    function setFeeYieldBps(uint256 bps) external;
    function setReserveRatioBps(uint256 bps) external;

    function recordTradeFeeYield(uint256 amount) external;
    function deployToStrategy(uint256 amount, uint256 treasuryCash, uint256 treasuryAssets)
        external
        returns (uint256 totalDeployed);
    function harvestYield() external returns (uint256 earned, uint256 newYieldPool);
    function postEpoch(uint256 epochYield_, uint256 totalLocked_) external;
    function processYieldDistribution(bytes calldata proof, bytes32[7] calldata inputs)
        external
        returns (bytes32 nullifier, uint256 claimed, bytes32 newNoteCommitment);
    function recallToTreasury(uint256 amount) external returns (uint256 totalDeployed);

    function setYieldPoolForTest(uint256 amount) external;
}