// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPoseidon2} from "poseidon2-evm/IPoseidon2.sol";

abstract contract MerkleTreeWithHistory {

    uint32 public constant LEVELS = 20;
    uint32 public constant ROOTS_HISTORY = 30; // circular buffer size for getLastRoot()

    bytes32[LEVELS] public filledSubtrees;
    bytes32[LEVELS] public zeros;
    bytes32[ROOTS_HISTORY] public roots;  // circular buffer of recent roots

    mapping(bytes32 => bool) private _historicalRoots;

    address public immutable poseidon2;

    uint32 public currentRootIndex;
    uint32 public nextLeafIndex;

    error MerkleTreeFull();

    constructor(address poseidon2_) {
        poseidon2 = poseidon2_;
        _initMerkleTree();
    }

    function _initMerkleTree() internal {
        bytes32 currentZero = bytes32(0);
        for (uint32 i = 0; i < LEVELS; i++) {
            zeros[i] = currentZero;
            filledSubtrees[i] = currentZero;
            currentZero = _hashLeftRight(currentZero, currentZero);
        }

        roots[0] = currentZero;
        _historicalRoots[currentZero] = true;
        currentRootIndex = 0;
        nextLeafIndex = 0;
    }

    function getLastRoot() public view returns (bytes32) {
        return roots[currentRootIndex];
    }

    function isKnownRoot(bytes32 root) public view returns (bool) {
        if (root == bytes32(0)) return false;
        return _historicalRoots[root];
    }

    function _insert(bytes32 leaf) internal returns (uint32 leafIndex, bytes32 newRoot) {
        leafIndex = nextLeafIndex;
        if (leafIndex >= (uint32(1) << LEVELS)) revert MerkleTreeFull();
        nextLeafIndex = leafIndex + 1;

        bytes32 currentHash = leaf;
        uint32 index = leafIndex;

        for (uint32 i = 0; i < LEVELS; i++) {
            if ((index & 1) == 0) {
                filledSubtrees[i] = currentHash;
                currentHash = _hashLeftRight(currentHash, zeros[i]);
            } else {
                currentHash = _hashLeftRight(filledSubtrees[i], currentHash);
            }
            index >>= 1;
        }

        currentRootIndex = (currentRootIndex + 1) % ROOTS_HISTORY;
        roots[currentRootIndex] = currentHash;
        _historicalRoots[currentHash] = true;

        newRoot = currentHash;
    }

    function _hashLeftRight(bytes32 left, bytes32 right) internal view returns (bytes32 out) {
        out = bytes32(IPoseidon2(poseidon2).hash_2(uint256(left), uint256(right)));
    }
}
