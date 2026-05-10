// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Pluggable yield source: abstracts Aave v4, idle capital (NullStrategy), or any future protocol.
// Token flow: vault transfers tokens to strategy before deploy(); strategy returns them on recall().
// harvest() withdraws ONLY accrued yield and sends it to the vault. Strategy never holds principal.
// The vault address passed to the constructor is the sole counterparty.
interface IYieldStrategy {
    // Vault must transfer `amount` to the strategy before calling.
    function deploy(uint256 amount) external;

    // Withdraw `amount` of principal from the yield source back to the vault.
    function recall(uint256 amount) external;

    // Harvest all accrued yield, send to vault, return the amount harvested.
    function harvest() external returns (uint256 yieldEarned);

    // Principal currently deployed, excluding accrued yield.
    function deployed() external view returns (uint256);

    function currentValue() external view returns (uint256);

    function strategyAsset() external view returns (address);
}
