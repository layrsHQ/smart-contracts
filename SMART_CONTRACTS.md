# Smart Contracts

All contracts deployed on Horizen Caldera testnet (chain 2651420).

## Privacy vault treasuries

| Asset | Vault address | Underlying token |
|-------|---------------|------------------|
| USDC | `0x85b49269b872463dd3ffcff1d8b9e92d29b0cb5e` | `0x73301067ADBcA514b8Ff972206582488ac7E53dC` |
| ZEN | `0xa7756df82a0160f05527057097e62910b7f0c0d1` | `0x002D749E444620630f84B9feC340B066a5DF84aE` |

## On-chain verifier contracts

Auto-generated from Noir circuits via Aztec's Barretenberg backend (`bb write_solidity_verifier`).

### USDC vault

| Circuit | Verifier address |
|---------|------------------|
| pm_deposit | `0x3Fa6daF85b2f6DfB7127D6C8913A4582f8784D96` |
| pm_balance_proof | `0xa4ed10c9cd185a1d38Dd6397FDD5480e4b0fA4c2` |
| pm_settlement | `0x17BbAa7aE5A977C4596959E395C0B50EcBbb5BEB` |
| pm_claim | `0xC04d8f1bdDD55f625AC4BeAd68B119E267E97ACa` |
| pm_withdraw | `0x00c08c9BC2292Ed649d6887c9E4823B4D06C66eb` |

### ZEN vault

| Circuit | Verifier address |
|---------|------------------|
| pm_deposit | `0x3Fa6daF85b2f6DfB7127D6C8913A4582f8784D96` |
| pm_balance_proof | `0x90a42Ec8140fd44F2D11C6F4d7442fD7fF2FaA25` |
| pm_settlement | `0x14664ED1df2Fc381619fe3CFf9e9B8173495b588` |
| pm_claim | `0xC418E5dc522B0c8893C42C25f5480f651F6d21c8` |
| pm_withdraw | `0x5f933e751Ca280F200699212579a1897884d3E3b` |

## Market infrastructure

| Contract | Address | Purpose |
|----------|---------|---------|
| MarketRegistry | `0x89dc60b2be9189fa0a582ab7eb8023e11b13786e` | Registers prediction markets |
| MarketFactory | `0x56d09673b3c8d42634232f116134f19faa8e9fdf` | Deploys new markets |
| MarketResolver | `0x2f5903352bb912c94b7d7b5db4f07293fad1ea54` | Resolves markets against Pyth oracle |
