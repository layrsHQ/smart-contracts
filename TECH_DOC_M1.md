# Layrs Protocol — Technical Documentation (Milestone 1)

## Overview

Layrs is a prediction market protocol that hides user balances and trade positions from the public record. The basic problem: on a transparent chain, anyone can see what you deposited, how large your position is, and which wallet collects the payout. That's fine for sporting bets. It's a problem for markets where position size signals private information — corporate exposure, hedging intent, research conviction.

Milestone 1 delivers the core privacy layer end-to-end on Horizen Caldera testnet (chain 2651420): deposit notes into a private Merkle vault, place collateralised orders through a private CLOB, and withdraw to any address without on-chain linkage between the deposit and the withdrawal. The settlement and claim flows are also circuit-complete, meaning the full trade lifecycle is covered.

The guiding principle is that privacy protects the user, not the operator. The matching engine and relayer are centralized components with known trust assumptions — described honestly below.

## System Architecture

The system has five components:

```
[Browser / Frontend]
      |                    |
  ZK proofs (bb.js)    WS order feed
      |                    |
[vault-service]         [CLOB engine]
  proof generation,       Rust, in-memory
  EVM relayer             order book
      |
[PredictionMarketTreasury — USDC / ZEN]
  Horizen Caldera L3 — chain 2651420
      |
[MarketRegistry · MarketFactory · MarketResolver]
```

The **frontend** handles proof generation using `bb.js` (Barretenberg's WASM port). Proving for deposit, balance, order, and withdrawal circuits all happens in the browser.

The **vault-service** is a Rust backend that generates the third withdrawal proof, routes signed withdrawal requests to the EVM relayer, and serves the Merkle tree state the frontend needs for proofs. It pays gas on behalf of withdrawing users.

The **CLOB engine** is a separate Rust service running an in-memory order book. It receives balance proofs as collateral attestations before matching orders. It sees commitments, not identities.

The **on-chain contracts** are the trust anchor. `PredictionMarketTreasury` holds user assets, enforces nullifier spend, and verifies ZK proofs. Verifier contracts are upgradable behind a 5-minute testnet timelock (48 hours on mainnet). `MarketRegistry`, `MarketFactory`, and `MarketResolver` handle market lifecycle and Pyth oracle resolution.

Trust by component: contracts — trustless, on-chain verifiable; vault-service and CLOB — trusted operator, centralized; frontend — trust what you ship, open source.

## Privacy Model — What We Guarantee and What We Don't

**Cryptographically guaranteed:**

*Deposit-withdrawal unlinkability.* A withdrawal proof contains a Merkle root (any valid historical root accepted by `isKnownRoot`) and a nullifier `H2(owner_key_hash, note_nonce)`. The contract checks the nullifier hasn't been spent, but there's no on-chain path from nullifier back to a leaf index. The deposit transaction creates a leaf commitment at a numbered position; the withdrawal reveals only the root and nullifier. An observer cannot match them without knowing `owner_key_hash` — the private key material that never leaves the user's machine.

*Hidden collateral.* The `pm_balance_proof` circuit proves `note_amount >= required_amount` using a 64-bit range check on the difference: `diff = note_amount - required_amount`, asserted to fit in 64 bits. The CLOB receives a `balance_proof_digest` and a `note_nullifier_hash` as a soft-lock — no amount is revealed to anyone.

*Note ownership without identity disclosure.* The `user_ownership` and `withdrawal_authorization` circuits are off-chain proofs gating backend API access. They prevent third parties from submitting withdrawal requests against someone else's commitment, without requiring wallets to be registered on-chain.

**Operationally enforced (not cryptographic):**

The CLOB operator sees full order parameters at reveal time: market ID, side, price in basis points, size, and expiry timestamp. The commit-reveal scheme in `pm_order_commitment` prevents front-running by other market participants, but the operator running the CLOB sees everything at reveal. We're explicit about this.

Withdrawal recipient and amount are public. The `extDataHash = H5(recipient, relayer, fee, amount, vault_id)` is verified on-chain, which means it's in the transaction record. What's hidden is the connection to the original deposit.

**On anonymity set sizing:** on testnet today there are a few dozen deposits. That's not a meaningful anonymity set — a determined observer can narrow candidates. The path to real privacy is production scale. We're not claiming production-grade unlinkability at this stage; we're claiming the cryptographic construction is correct and the full lifecycle works end-to-end.

## Cryptographic Stack

Circuits are written in Noir and compiled to ACIR, then proven with Barretenberg's UltraHonk backend. We picked Noir because it has the most usable tooling for ZK circuit development and its type system catches more circuit bugs at compile time than Circom does. The `bb` CLI handles key generation and the `bb.js` WASM port handles in-browser proving.

The hash function throughout is Poseidon2 over the bn254 scalar field, using an IV of `N × 2^64` where N is the number of inputs — so `hash_2(a, b)` uses IV `36893488147419103232`, `hash_4` uses `73786976294838206464`, `hash_5` uses `92233720368547758080`. This matches Barretenberg's `poseidon2Hash` precisely. A mismatch here is silent and produces wrong nullifiers, so the IV scheme is pinned identically in every circuit.

The Merkle tree is depth-20, giving 2^20 ≈ 1,048,576 leaf capacity. The tree accepts any known historical root via a bounded ring buffer, which allows concurrent proofs to be generated during active deposit periods without invalidating each other.

On measured numbers: UltraHonk verification costs approximately 2.4M gas on-chain — we measured 2,449,296 on the first live withdrawal. Proof size is roughly 7KB. Frontend proving runs in low single-digit seconds on a modern laptop.

## Circuits

- **`pm_deposit`** — Binds `owner_key_hash`, `note_nonce`, `asset_domain`, and `amount` into a note commitment `H4(owner_key_hash, H2(amount, amount_blind), asset_domain, note_nonce)`, then inserts that commitment at an empty Merkle leaf. Public inputs: `old_root`, `asset_domain`, `amount`. Public outputs: `note_commitment`, `amount_commitment`, `new_root`. Verified on-chain by the deposit verifier.

- **`pm_balance_proof`** — Proves `note_amount >= required_amount` without revealing the amount. Emits `note_nullifier_hash` as a CLOB soft-lock. Does not consume the note. Public inputs: `old_root`, `asset_domain`, `required_amount`, `order_commitment`. Verified on-chain at order placement.

- **`pm_order_commitment`** — Commit-reveal for anti-front-running. Phase 1: the user submits a commitment hash without revealing order parameters. Phase 2: the user reveals parameters alongside this proof, tying the reveal to a specific `balance_proof_digest`. Price is encoded as integer basis points in `[1, 9999]`. Verified off-chain by the CLOB engine.

- **`pm_settlement`** — Proves conservation across a trade fill: `input_amount == receiver_amount + change_amount`. Nullifies the input note and commits two outputs (position note and change note). Append-only model — the contract inserts both commitments sequentially and computes the new root. Public inputs: `old_root`. Outputs: `nullifier`, `receiver_commitment`, `change_commitment`. Verified on-chain.

- **`pm_claim`** — Proves ownership of a winning position using `positionDomain = H2(market_id, outcome)`. Claims are pure payouts — no new note is created, no reinsertion needed. Nullifier prevents double-spend. Verified on-chain against any known historical root.

- **`pm_withdraw`** — Proves note membership and binds the withdrawal to a specific recipient, relayer, fee, amount, and vault via `extDataHash = H5(recipient, relayer, fee, amount, vault_id)`. Nullifier is `H2(owner_key_hash, note_nonce)`. Exposes exactly 10 public inputs consumed by the `withdrawWithProof(bytes, bytes32[10])` ABI. Verified on-chain.

- **`user_ownership` and `withdrawal_authorization`** — Off-chain auth proofs gating backend submission. `user_ownership` proves the caller knows the private key for a committed note. `withdrawal_authorization` signs off on a specific withdrawal request before vault-service will relay it. Neither has a deployed on-chain verifier contract.

## End-to-End Withdrawal Flow

Starting from a user clicking "withdraw":

1. The frontend fetches current Merkle tree state from vault-service and reconstructs the Merkle path for the user's note (depth-20 sibling array and path indices).

2. Two ZK proofs are generated in-browser with `bb.js`: `user_ownership` and `withdrawal_authorization`. These gate backend access.

3. Both proofs, plus withdrawal parameters (recipient, amount, fee, relayer address), are posted to vault-service.

4. vault-service verifies the auth proofs, then generates the `pm_withdraw` proof server-side via `prove_noir_honk.mjs`.

5. The operator-relayer calls `withdrawWithProof(bytes proof, bytes32[10] publicInputs)` on `PredictionMarketTreasury`.

6. On-chain: the contract verifies the UltraHonk proof against all 10 public inputs, calls `isKnownRoot(root)`, checks `nullifierHashes[nullifierHash] == false`, marks the nullifier spent, and transfers `amount` to `recipient`.

The gas cost for step 6 on the first live withdrawal was 2,449,296 — transaction `0x0c2095deafd6b8e38217a94b36bbf53280288eafa64fe3b33e1e6dafe5f99999` on Horizen Caldera. The recipient was a fresh address with no prior on-chain history. No link to the depositing address is visible in the transaction record.

## Smart Contracts and Off-Chain Components

`PredictionMarketTreasury` runs a proxy pattern with five swappable verifier slots: deposit, balance, settlement, claim, and withdraw. Verifier upgrades use a `scheduleVerifierUpdate` / `applyVerifierUpdate` two-step with a configurable timelock. Each slot holds an auto-generated UltraHonk verifier contract whose correctness is anchored to a `VK_HASH` constant embedded in its bytecode — replacing the verifier with a different VK requires a new deployment, not just a pointer swap. The nullifier store is an on-chain mapping. Root history is a bounded ring buffer of the last N accepted roots.

Active vaults on testnet:

| Asset | Vault | Token |
|-------|-------|-------|
| USDC  | `0x85b49269b872463dd3ffcff1d8b9e92d29b0cb5e` | `0x73301067ADBcA514b8Ff972206582488ac7E53dC` |
| ZEN   | `0xa7756df82a0160f05527057097e62910b7f0c0d1` | `0x002D749E444620630f84B9feC340B066a5DF84aE` |

The CLOB matching engine is a Rust service with an in-memory order book. Matched trades are batched and settled on-chain via the settlement circuit. It is not fault-tolerant across restarts in this milestone — the recovery path for in-flight orders against soft-locked nullifiers has a known edge case described below.

The operator-relayer pays gas for all withdrawals. The threat model is narrow: the operator can refuse to relay (censorship), but cannot steal funds. A user's note stays unspent in the Merkle tree until they find another relay path.

## Roadmap and Known Limitations

Honest list of what's rough today:

- **Anonymity set is small on testnet.** A few dozen deposits does not constitute a meaningful anonymity set. Privacy guarantees grow with usage, and production scale is the fix.
- **CLOB restart-recovery edge case.** In-flight orders against soft-locked nullifiers can get stuck if the engine restarts mid-batch. A manual recovery path exists but it isn't automated yet.
- **Operator-relayer is a centralized trust assumption.** Censorship resistance today is limited to the user's note remaining unspent. TEE migration is the fix.

**Milestone 1.1 (weeks):** settlement worker hardening, async-batch finality reliability, ZEN vault withdraw verifier update.

**Milestone 2:** standalone proving service for horizontal scale; CLOB matching engine inside AWS Nitro Enclaves so the operator cannot read order contents; formal circuit and contract audit.

**Milestone 3:** vault yield strategy activation, mainnet launch.
