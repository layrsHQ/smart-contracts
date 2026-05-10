// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MerkleTreeWithHistory} from "../contracts/zk/MerkleTreeWithHistory.sol";
import {IMarketRegistry} from "../contracts/interfaces/IMarketRegistry.sol";
import {IMarketResolver} from "../contracts/interfaces/IMarketResolver.sol";
import {
    IDepositVerifier,
    IBalanceProofVerifier,
    ITransferSettlementVerifier,
    IMarketClaimVerifier,
    IVaultSpendVerifier,
    IYieldDistributionVerifier
} from "../contracts/interfaces/IVerifiers.sol";
import {IYieldStrategy} from "../Yield_Vaults/interfaces/IYieldStrategy.sol";
import {IPredictionMarketYieldManager} from "../Yield_Vaults/interfaces/IPredictionMarketYieldManager.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Poseidon2Yul_BN254} from "poseidon2-evm/bn254/yul/Poseidon2Yul.sol";

contract PredictionMarketTreasury is MerkleTreeWithHistory, Initializable, UUPSUpgradeable {

    address public immutable asset;

    address public admin;
    address public pendingAdmin;
    bool public paused;
    uint256 public aggregateBalance;
    uint256 public protocolFeesAccrued;

    address public feeRecipient;
    uint16 public claimFeeBps;

    IMarketRegistry public marketRegistry;

    mapping(address => bool) public operators;
    mapping(address => bool) public relayers;  // kept for withdrawWithProof relayer fee routing

    IDepositVerifier public depositVerifier;
    IBalanceProofVerifier public balanceVerifier;
    ITransferSettlementVerifier public settlementVerifier;
    IMarketClaimVerifier public claimVerifier;
    IVaultSpendVerifier public withdrawVerifier;

    uint256 public vaultId;

    mapping(uint64 => uint256) public marketCollateral;
    mapping(uint64 => uint256) public marketClaimed;
    mapping(bytes32 => bool) public nullifierSpent;
    mapping(bytes32 => uint64) public noteLockExpiry;
    mapping(bytes32 => uint256) public noteLockOrderCommitment;

    struct PendingVerifiers {
        address depositVerifier;
        address balanceVerifier;
        address settlementVerifier;
        address claimVerifier;
        address withdrawVerifier;
        uint64 scheduledAt;
        bool exists;
    }
    PendingVerifiers public pendingVerifierUpdate;
    uint64 public immutable VERIFIER_TIMELOCK;

    uint256 public circuitVersion;

    // upgrade
    struct PendingUpgrade {
        address newImpl;
        uint64 readyAt;
    }
    PendingUpgrade public pendingUpgrade;
    uint64 public immutable UPGRADE_TIMELOCK;

    // new storage variables go here, consuming __gap slots before the gap itself
    IPredictionMarketYieldManager public yieldManager;

    uint256[49] private __gap;

    // errors
    error NotAdmin();
    error NotOperator();
    error NotFeeRecipientOrAdmin();
    error Paused();
    error ZeroAddress();
    error ZeroAmount();
    error TransferFailed();
    error BalanceCheckFailed();
    error InvalidProof();
    error NullifierSpent();
    error NoteAlreadyLocked();
    error NoteNotLocked();
    error ExpiryInPast();
    error LockNotExpired();
    error OrderCommitmentMismatch();
    error MarketNotResolved();
    error MarketAlreadyResolved();
    error MarketInvalidated();
    error ClaimNotOpen();
    error InsufficientCollateral();
    error InvalidBps();
    error InvalidTimelock();
    error Reentrancy();
    error VerifierUpdateNotScheduled();
    error VerifierUpdateNotReady();
    error PayoutExceedsCollateral();
    error UpgradeNotScheduled();
    error UpgradeNotReady();
    error InsufficientLiquidity();
    error EpochNotPosted();
    error YieldPoolInsufficient();
    error StrategyNotEmpty();
    error NotYieldManager();

    // events
    event Deposit(address indexed token, uint256 newTotalAssets);
    event CollateralLocked(
        bytes32 indexed noteNullifier,
        uint256 orderCommitment,
        uint64 lockExpiryTs
    );
    event CollateralUnlocked(bytes32 indexed noteNullifier, uint256 orderCommitment);
    event FillSettled(
        uint64 indexed marketId,
        bytes32 indexed spentNullifier,
        uint256 tradeFeeAmount,
        uint256 newMarketCollateral
    );
    event PositionNoteMinted(bytes32 indexed noteCommit, uint64 indexed marketId, uint32 leafIndex, bytes32 newRoot);

    event WinningsClaimed(
        uint64 indexed marketId,
        bytes32 indexed nullifier,
        uint256 grossPayout,
        uint256 claimFee,
        uint256 netPayout,
        address recipient,
        uint256 remainingCollateral
    );
    event VerifierUpdateScheduled(
        address depositVerifier,
        address balanceVerifier,
        address settlementVerifier,
        address claimVerifier,
        address withdrawVerifier,
        uint64 applyAfter
    );
    event VerifiersUpdated(uint256 indexed circuitVersion);
    event VerifierUpdateApplied();
    event VerifierUpdateCancelled();
    event MarketRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event ClaimFeeUpdated(uint16 oldBps, uint16 newBps);
    event RelayerSet(address relayer, bool enabled);
    event FeesWithdrawn(address indexed recipient, uint256 amount);
    event OperatorSet(address operator, bool enabled);
    event AdminTransferInitiated(address indexed current, address indexed pending_);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event VaultPaused(address caller);
    event VaultUnpaused(address caller);
    event Withdrawal(
        bytes32 indexed nullifierHash,
        address indexed recipient,
        uint256 amount,
        uint256 fee
    );
    event UpgradeScheduled(address indexed newImpl, uint64 readyAt);
    event UpgradeApplied(address indexed newImpl);
    event StrategyDeployed(uint256 amount, uint256 totalDeployed);
    event StrategyRecalled(uint256 amount, uint256 totalDeployed);
    event YieldHarvested(uint256 yieldEarned, uint256 newYieldPool);
    event EpochPosted(uint256 epochYield, uint256 totalLocked);
    event YieldDistributed(bytes32 indexed nullifier, uint256 claimedYield, bytes32 newNoteCommitment);
    event FeeYieldBpsUpdated(uint256 oldBps, uint256 newBps);
    event ReserveRatioBpsUpdated(uint256 oldBps, uint256 newBps);
    event YieldStrategyUpdated(address indexed oldStrategy, address indexed newStrategy);
    event YieldManagerUpdated(address indexed oldManager, address indexed newManager);

    // cheaper than OZ ReentrancyGuard on frequent deposit/withdraw paths
    uint256 private _lock = 1;

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier onlyAdmin() { if (msg.sender != admin) revert NotAdmin(); _; }
    modifier onlyOperator() { if (!operators[msg.sender] && msg.sender != admin) revert NotOperator(); _; }
    modifier whenNotPaused() { if (paused) revert Paused(); _; }
    modifier onlyYieldManager() {
        if (msg.sender != address(yieldManager)) revert NotYieldManager();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address asset_, uint64 verifierTimelock_, uint64 upgradeTimelock_) MerkleTreeWithHistory(_deployPoseidon()) {
        if (asset_ == address(0)) revert ZeroAddress();
        if (verifierTimelock_ == 0) revert InvalidTimelock();
        if (upgradeTimelock_ == 0) revert InvalidTimelock();
        asset = asset_;
        VERIFIER_TIMELOCK = verifierTimelock_;
        UPGRADE_TIMELOCK = upgradeTimelock_;
        _disableInitializers();
    }

    function initialize(
        address admin_,
        address marketRegistry_,
        address depositVerifier_,
        address balanceVerifier_,
        address settlementVerifier_,
        address claimVerifier_,
        address withdrawVerifier_,
        address feeRecipient_,
        uint16 claimFeeBps_,
        uint256 vaultId_
    ) external initializer {
        _initVaultState(
            admin_, marketRegistry_,
            depositVerifier_, balanceVerifier_,
            settlementVerifier_, claimVerifier_,
            withdrawVerifier_, feeRecipient_,
            claimFeeBps_, vaultId_
        );
    }

    function _initVaultState(
        address admin_,
        address marketRegistry_,
        address depositVerifier_,
        address balanceVerifier_,
        address settlementVerifier_,
        address claimVerifier_,
        address withdrawVerifier_,
        address feeRecipient_,
        uint16 claimFeeBps_,
        uint256 vaultId_
    ) internal {
        if (admin_ == address(0)) revert ZeroAddress();
        if (marketRegistry_ == address(0)) revert ZeroAddress();
        if (depositVerifier_ == address(0)) revert ZeroAddress();
        if (balanceVerifier_ == address(0)) revert ZeroAddress();
        if (settlementVerifier_ == address(0)) revert ZeroAddress();
        if (claimVerifier_ == address(0)) revert ZeroAddress();
        if (withdrawVerifier_ == address(0)) revert ZeroAddress();
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        if (claimFeeBps_ > 10_000) revert InvalidBps();

        _initMerkleTree();

        admin = admin_;
        marketRegistry = IMarketRegistry(marketRegistry_);
        depositVerifier = IDepositVerifier(depositVerifier_);
        balanceVerifier = IBalanceProofVerifier(balanceVerifier_);
        settlementVerifier = ITransferSettlementVerifier(settlementVerifier_);
        claimVerifier = IMarketClaimVerifier(claimVerifier_);
        withdrawVerifier = IVaultSpendVerifier(withdrawVerifier_);
        feeRecipient = feeRecipient_;
        claimFeeBps = claimFeeBps_;
        vaultId = vaultId_;
        _lock = 1;
    }

    // deposit

    function deposit(
        uint256 assets,
        bytes calldata proof,
        bytes32[6] calldata inputs
    ) external nonReentrant whenNotPaused {
        if (assets == 0) revert ZeroAmount();

        _safeTransferFrom(asset, msg.sender, address(this), assets);

        if (inputs[0] != getLastRoot()) revert InvalidProof();
        if (inputs[1] != bytes32(uint256(uint160(asset)))) revert InvalidProof();
        if (inputs[2] != bytes32(assets)) revert InvalidProof();
        bytes32[] memory _in = new bytes32[](6);
        for (uint256 i; i < 6; ++i) _in[i] = inputs[i];
        if (!depositVerifier.verify(proof, _in)) revert InvalidProof();

        (, bytes32 newRoot) = _insert(inputs[3]); // noteCommitment
        if (newRoot != inputs[5]) revert InvalidProof(); // newRoot must match circuit

        aggregateBalance = _vaultPrincipal();
        emit Deposit(asset, aggregateBalance);
    }

    // withdraw

    function withdrawWithProof(
        bytes calldata proof,
        bytes32[10] calldata inputs
    ) external nonReentrant whenNotPaused {
        if (!isKnownRoot(inputs[0])) revert InvalidProof();

        bytes32 nullifierBytes = inputs[1];
        if (nullifierSpent[nullifierBytes]) revert NullifierSpent();
        if (uint256(inputs[5]) != vaultId) revert InvalidProof();

        bytes32[] memory _in = new bytes32[](10);
        for (uint256 i; i < 10; ++i) _in[i] = inputs[i];
        if (!withdrawVerifier.verify(proof, _in)) revert InvalidProof();

        address recipient = address(uint160(uint256(inputs[6])));
        address relayer = address(uint160(uint256(inputs[7])));
        uint256 fee = uint256(inputs[8]);
        uint256 amount = uint256(inputs[4]);

        nullifierSpent[nullifierBytes] = true;

        _ensureLiquidity(amount);

        if (fee > 0 && relayer != address(0)) {
            _safeTransfer(asset, relayer, fee);
        }
        _safeTransfer(asset, recipient, amount - fee);

        aggregateBalance = _vaultPrincipal();
        emit Withdrawal(nullifierBytes, recipient, amount, fee);
    }

    // collateral

    function lockCollateral(
        uint256 orderCommitment,
        uint256 requiredAmount,
        uint64 lockExpiryTs,
        bytes calldata proof,
        bytes32[6] calldata inputs
    ) external nonReentrant whenNotPaused onlyOperator returns (bytes32 noteNullifier) {
        if (requiredAmount == 0) revert ZeroAmount();
        if (lockExpiryTs <= uint64(block.timestamp)) revert ExpiryInPast();

        if (inputs[0] != getLastRoot()) revert InvalidProof();
        if (inputs[1] != bytes32(uint256(uint160(asset)))) revert InvalidProof();
        if (inputs[2] != bytes32(requiredAmount)) revert InvalidProof();
        if (inputs[3] != bytes32(orderCommitment)) revert InvalidProof();
        bytes32[] memory _in = new bytes32[](6);
        for (uint256 i; i < 6; ++i) _in[i] = inputs[i];
        if (!balanceVerifier.verify(proof, _in)) revert InvalidProof();

        noteNullifier = inputs[4];

        if (nullifierSpent[noteNullifier]) revert NullifierSpent();
        if (noteLockExpiry[noteNullifier] != 0) revert NoteAlreadyLocked();

        noteLockExpiry[noteNullifier] = lockExpiryTs;
        noteLockOrderCommitment[noteNullifier] = orderCommitment;

        emit CollateralLocked(noteNullifier, orderCommitment, lockExpiryTs);
    }

    function unlockCollateral(bytes32 noteNullifier, uint256 orderCommitment) external {
        uint64 expiry = noteLockExpiry[noteNullifier];
        if (expiry == 0) revert NoteNotLocked();
        if (noteLockOrderCommitment[noteNullifier] != orderCommitment) revert OrderCommitmentMismatch();

        bool callerAuthorized = operators[msg.sender] || msg.sender == admin;
        bool isExpired = uint64(block.timestamp) >= expiry;
        if (!callerAuthorized && !isExpired) revert LockNotExpired();

        delete noteLockExpiry[noteNullifier];
        delete noteLockOrderCommitment[noteNullifier];

        emit CollateralUnlocked(noteNullifier, orderCommitment);
    }

    // settlement

    function settleFill(
        uint64 marketId,
        bool positionSide,
        bytes32 spentNullifier,
        uint256 potContribution,
        uint256 positionPayoutUnits,
        uint256 tradeFeeAmount,
        bytes calldata proof,
        bytes32[4] calldata inputs
    ) external nonReentrant whenNotPaused onlyOperator {
        if (potContribution == 0) revert ZeroAmount();
        if (positionPayoutUnits == 0) revert ZeroAmount();

        IMarketResolver resolver = marketRegistry.getResolver(marketId);
        if (resolver.isResolved(marketId)) revert MarketAlreadyResolved();
        if (resolver.isInvalidated(marketId)) revert MarketInvalidated();

        if (noteLockExpiry[spentNullifier] == 0) revert NoteNotLocked();

        if (!isKnownRoot(inputs[0])) revert InvalidProof();
        if (inputs[1] != spentNullifier) revert InvalidProof();
        bytes32[] memory _in = new bytes32[](4);
        for (uint256 i; i < 4; ++i) _in[i] = inputs[i];
        if (!settlementVerifier.verify(proof, _in)) revert InvalidProof();

        if (nullifierSpent[spentNullifier]) revert NullifierSpent();
        nullifierSpent[spentNullifier] = true;
        delete noteLockExpiry[spentNullifier];
        delete noteLockOrderCommitment[spentNullifier];

        uint256 newMarketCollateral = marketCollateral[marketId] + potContribution;
        marketCollateral[marketId] = newMarketCollateral;
        if (tradeFeeAmount > 0) {
            uint256 yieldPortion = 0;
            address manager = address(yieldManager);
            if (manager != address(0)) {
                yieldPortion = (tradeFeeAmount * IPredictionMarketYieldManager(manager).feeYieldBps()) / 10_000;
            }
            uint256 protocolPortion = tradeFeeAmount - yieldPortion;
            if (yieldPortion > 0) {
                _safeTransfer(asset, manager, yieldPortion);
                IPredictionMarketYieldManager(manager).recordTradeFeeYield(yieldPortion);
            }
            if (protocolPortion > 0) protocolFeesAccrued += protocolPortion;
        }

        _insert(inputs[2]);
        if (inputs[3] != bytes32(0)) _insert(inputs[3]);

        emit FillSettled(marketId, spentNullifier, tradeFeeAmount, newMarketCollateral);
    }

    // claim

    function claimWinnings(
        address recipient,
        bytes calldata proof,
        bytes32[7] calldata inputs
    ) external nonReentrant whenNotPaused returns (uint256 netPayout) {
        (uint64 marketId, uint256 grossPayout, bytes32 nullifier) =
            _validateClaimInputs(recipient, proof, inputs);

        if (nullifierSpent[nullifier]) revert NullifierSpent();
        nullifierSpent[nullifier] = true;

        uint256 pool = marketCollateral[marketId];
        if (pool < grossPayout) revert InsufficientCollateral();

        uint256 fee = (grossPayout * claimFeeBps) / 10_000;
        netPayout = grossPayout - fee;

        marketCollateral[marketId] = pool - grossPayout;
        marketClaimed[marketId]   += grossPayout;
        if (fee > 0) protocolFeesAccrued += fee;

        _ensureLiquidity(netPayout);
        aggregateBalance = _vaultPrincipal();

        _safeTransfer(asset, recipient, netPayout);

        emit WinningsClaimed(
            marketId, nullifier, grossPayout, fee, netPayout, recipient,
            marketCollateral[marketId]
        );
    }

    // testnet

    function mintPositionNote(bytes32 noteCommit, uint64 marketId)
        external
        onlyOperator
        returns (uint32 leafIndex, bytes32 newRoot)
    {
        (leafIndex, newRoot) = _insert(noteCommit);
        emit PositionNoteMinted(noteCommit, marketId, leafIndex, newRoot);
    }

    function _validateClaimInputs(
        address recipient,
        bytes calldata proof,
        bytes32[7] calldata inputs
    ) internal view returns (uint64 marketId, uint256 grossPayout, bytes32 nullifier) {
        if (recipient == address(0)) revert ZeroAddress();

        if (!isKnownRoot(inputs[0])) revert InvalidProof();
        if (inputs[1] != bytes32(uint256(uint160(recipient)))) revert InvalidProof();
        bytes32[] memory _in = new bytes32[](7);
        for (uint256 i; i < 7; ++i) _in[i] = inputs[i];
        if (!claimVerifier.verify(proof, _in)) revert InvalidProof();

        if (uint256(inputs[2]) > type(uint64).max) revert InvalidProof();
        marketId = uint64(uint256(inputs[2]));

        bool claimOutcome = inputs[3] == bytes32(uint256(1));
        grossPayout = uint256(inputs[4]);
        nullifier = inputs[5];

        IMarketResolver resolver = marketRegistry.getResolver(marketId);
        if (!resolver.isResolved(marketId)) revert MarketNotResolved();
        if (resolver.isInvalidated(marketId)) revert MarketInvalidated();
        if (uint64(block.timestamp) < resolver.claimableAt(marketId)) revert ClaimNotOpen();
        if (claimOutcome != resolver.getOutcome(marketId)) revert InvalidProof();
    }

    // fees

    function withdrawFees() external nonReentrant {
        if (msg.sender != admin && msg.sender != feeRecipient) revert NotFeeRecipientOrAdmin();
        uint256 amount = protocolFeesAccrued;
        if (amount == 0) revert ZeroAmount();
        protocolFeesAccrued = 0;
        emit FeesWithdrawn(feeRecipient, amount);
        _ensureLiquidity(amount);
        _safeTransfer(asset, feeRecipient, amount);
        aggregateBalance = _vaultPrincipal();
    }

    // yield

    function deployToStrategy(uint256 amount) external nonReentrant onlyOperator {
        if (amount == 0) revert ZeroAmount();
        address manager = address(yieldManager);
        if (manager == address(0)) revert ZeroAddress();

        uint256 treasuryCash = _tokenBalance();
        uint256 treasuryAssets = _vaultPrincipal();
        _safeTransfer(asset, manager, amount);
        uint256 totalDeployed = IPredictionMarketYieldManager(manager).deployToStrategy(
            amount,
            treasuryCash,
            treasuryAssets
        );

        aggregateBalance = _vaultPrincipal();
        emit StrategyDeployed(amount, totalDeployed);
    }

    function harvestYield() external nonReentrant onlyOperator {
        address manager = address(yieldManager);
        if (manager == address(0)) return;
        (uint256 earned, uint256 newYieldPool) = IPredictionMarketYieldManager(manager).harvestYield();
        if (earned == 0) return;
        aggregateBalance = _vaultPrincipal();
        emit YieldHarvested(earned, newYieldPool);
    }

    function postEpoch(uint256 epochYield_, uint256 totalLocked_) external onlyOperator {
        address manager = address(yieldManager);
        if (manager == address(0)) revert ZeroAddress();
        IPredictionMarketYieldManager(manager).postEpoch(epochYield_, totalLocked_);
        emit EpochPosted(epochYield_, totalLocked_);
    }

    function distributeYield(
        bytes calldata proof,
        bytes32[7] calldata inputs
    ) external nonReentrant whenNotPaused {
        address manager = address(yieldManager);
        if (manager == address(0)) revert ZeroAddress();
        (bytes32 nullifier, uint256 claimed, bytes32 newNoteCommitment) =
            IPredictionMarketYieldManager(manager).processYieldDistribution(proof, inputs);

        aggregateBalance = _vaultPrincipal();
        emit YieldDistributed(nullifier, claimed, newNoteCommitment);
    }

    function scheduleVerifierUpdate(
        address depositVerifier_,
        address balanceVerifier_,
        address settlementVerifier_,
        address claimVerifier_,
        address withdrawVerifier_
    ) external onlyAdmin {
        if (depositVerifier_ == address(0)) revert ZeroAddress();
        if (balanceVerifier_ == address(0)) revert ZeroAddress();
        if (settlementVerifier_ == address(0)) revert ZeroAddress();
        if (claimVerifier_ == address(0)) revert ZeroAddress();
        if (withdrawVerifier_ == address(0)) revert ZeroAddress();

        pendingVerifierUpdate = PendingVerifiers({
            depositVerifier: depositVerifier_,
            balanceVerifier: balanceVerifier_,
            settlementVerifier: settlementVerifier_,
            claimVerifier: claimVerifier_,
            withdrawVerifier: withdrawVerifier_,
            scheduledAt: uint64(block.timestamp),
            exists: true
        });

        emit VerifierUpdateScheduled(
            depositVerifier_, balanceVerifier_, settlementVerifier_,
            claimVerifier_, withdrawVerifier_,
            uint64(block.timestamp) + VERIFIER_TIMELOCK
        );
    }

    function applyVerifierUpdate() external onlyAdmin {
        // TODO: consider time-locking applyVerifierUpdate separately from scheduleVerifierUpdate
        PendingVerifiers memory p = pendingVerifierUpdate;
        if (!p.exists) revert VerifierUpdateNotScheduled();
        if (uint64(block.timestamp) < p.scheduledAt + VERIFIER_TIMELOCK) revert VerifierUpdateNotReady();

        circuitVersion++;
        emit VerifiersUpdated(circuitVersion);

        depositVerifier = IDepositVerifier(p.depositVerifier);
        balanceVerifier = IBalanceProofVerifier(p.balanceVerifier);
        settlementVerifier = ITransferSettlementVerifier(p.settlementVerifier);
        claimVerifier = IMarketClaimVerifier(p.claimVerifier);
        withdrawVerifier = IVaultSpendVerifier(p.withdrawVerifier);

        delete pendingVerifierUpdate;
        emit VerifierUpdateApplied();
    }

    function cancelVerifierUpdate() external onlyAdmin {
        if (!pendingVerifierUpdate.exists) revert VerifierUpdateNotScheduled();
        delete pendingVerifierUpdate;
        emit VerifierUpdateCancelled();
    }

    // upgrade

    function scheduleUpgrade(address newImpl) external onlyAdmin {
        if (newImpl == address(0)) revert ZeroAddress();
        uint64 readyAt = uint64(block.timestamp) + UPGRADE_TIMELOCK;
        pendingUpgrade = PendingUpgrade({ newImpl: newImpl, readyAt: readyAt });
        emit UpgradeScheduled(newImpl, readyAt);
    }

    function applyUpgrade() external onlyAdmin {
        PendingUpgrade memory u = pendingUpgrade;
        if (u.newImpl == address(0)) revert UpgradeNotScheduled();
        if (uint64(block.timestamp) < u.readyAt) revert UpgradeNotReady();
        upgradeToAndCall(u.newImpl, "");
    }

    function cancelUpgrade() external onlyAdmin {
        if (pendingUpgrade.newImpl == address(0)) revert UpgradeNotScheduled();
        delete pendingUpgrade;
    }

    function _authorizeUpgrade(address newImpl) internal override onlyAdmin {
        PendingUpgrade memory u = pendingUpgrade;
        if (u.newImpl == address(0)) revert UpgradeNotScheduled();
        if (u.newImpl != newImpl) revert UpgradeNotScheduled();
        if (uint64(block.timestamp) < u.readyAt) revert UpgradeNotReady();
        delete pendingUpgrade;
        emit UpgradeApplied(newImpl);
    }

    // admin

    function setMarketRegistry(address newRegistry) external onlyAdmin {
        if (newRegistry == address(0)) revert ZeroAddress();
        address old = address(marketRegistry);
        marketRegistry = IMarketRegistry(newRegistry);
        emit MarketRegistryUpdated(old, newRegistry);
    }

    function setOperator(address op, bool enabled) external onlyAdmin {
        operators[op] = enabled;
        emit OperatorSet(op, enabled);
    }

    function setRelayer(address relayer, bool enabled) external onlyAdmin {
        relayers[relayer] = enabled;
        emit RelayerSet(relayer, enabled);
    }

    function setFeeRecipient(address newFeeRecipient) external onlyAdmin {
        if (newFeeRecipient == address(0)) revert ZeroAddress();
        address old = feeRecipient;
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(old, newFeeRecipient);
    }

    function setClaimFeeBps(uint16 newBps) external onlyAdmin {
        if (newBps > 10_000) revert InvalidBps();
        uint16 old = claimFeeBps;
        claimFeeBps = newBps;
        emit ClaimFeeUpdated(old, newBps);
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

    function pause() external onlyAdmin {
        paused = true;
        emit VaultPaused(msg.sender);
    }

    function unpause() external onlyAdmin {
        paused = false;
        emit VaultUnpaused(msg.sender);
    }

    function setFeeYieldBps(uint256 bps) external onlyAdmin {
        address manager = address(yieldManager);
        if (manager == address(0)) revert ZeroAddress();
        uint256 old = IPredictionMarketYieldManager(manager).feeYieldBps();
        IPredictionMarketYieldManager(manager).setFeeYieldBps(bps);
        emit FeeYieldBpsUpdated(old, bps);
    }

    function setReserveRatioBps(uint256 bps) external onlyAdmin {
        address manager = address(yieldManager);
        if (manager == address(0)) revert ZeroAddress();
        uint256 old = IPredictionMarketYieldManager(manager).reserveRatioBps();
        IPredictionMarketYieldManager(manager).setReserveRatioBps(bps);
        emit ReserveRatioBpsUpdated(old, bps);
    }

    function setYieldStrategy(address strategy_) external onlyAdmin {
        address manager = address(yieldManager);
        if (manager == address(0)) revert ZeroAddress();
        address old = IPredictionMarketYieldManager(manager).yieldStrategy();
        IPredictionMarketYieldManager(manager).setYieldStrategy(strategy_);
        emit YieldStrategyUpdated(old, strategy_);
    }

    function setYieldVerifier(address verifier_) external onlyAdmin {
        address manager = address(yieldManager);
        if (manager == address(0)) revert ZeroAddress();
        IPredictionMarketYieldManager(manager).setYieldVerifier(verifier_);
    }

    function setYieldManager(address manager_) external onlyAdmin {
        if (manager_ == address(0)) revert ZeroAddress();
        if (IPredictionMarketYieldManager(manager_).asset() != asset) revert InvalidProof();
        address old = address(yieldManager);
        yieldManager = IPredictionMarketYieldManager(manager_);
        emit YieldManagerUpdated(old, manager_);
    }

    function yieldStrategy() public view returns (IYieldStrategy) {
        return IYieldStrategy(address(yieldManager) == address(0) ? address(0) : yieldManager.yieldStrategy());
    }

    function yieldVerifier() public view returns (IYieldDistributionVerifier) {
        return IYieldDistributionVerifier(address(yieldManager) == address(0) ? address(0) : yieldManager.yieldVerifier());
    }

    function yieldPool() public view returns (uint256) {
        return address(yieldManager) == address(0) ? 0 : yieldManager.yieldPool();
    }

    function feeYieldBps() public view returns (uint256) {
        return address(yieldManager) == address(0) ? 0 : yieldManager.feeYieldBps();
    }

    function reserveRatioBps() public view returns (uint256) {
        return address(yieldManager) == address(0) ? 0 : yieldManager.reserveRatioBps();
    }

    function epochYield() public view returns (uint256) {
        return address(yieldManager) == address(0) ? 0 : yieldManager.epochYield();
    }

    function totalLocked() public view returns (uint256) {
        return address(yieldManager) == address(0) ? 0 : yieldManager.totalLocked();
    }

    function isNullifierSpent(bytes32 nullifier) external view returns (bool) {
        return nullifierSpent[nullifier];
    }

    function positionDomain(uint64 marketId, bool side) public view returns (bytes32) {
        return _hashLeftRight(bytes32(uint256(marketId)), bytes32(side ? 1 : 0));
    }

    function vaultPrincipal() external view returns (uint256) {
        return _vaultPrincipal();
    }

    function applyYieldDistributionFromManager(
        bytes32 oldRoot,
        bytes32 nullifier,
        bytes32 newNoteCommitment,
        bytes32 expectedNewRoot
    ) external onlyYieldManager {
        if (!isKnownRoot(oldRoot)) revert InvalidProof();
        if (nullifierSpent[nullifier]) revert NullifierSpent();

        nullifierSpent[nullifier] = true;
        (, bytes32 newRoot) = _insert(newNoteCommitment);
        if (newRoot != expectedNewRoot) revert InvalidProof();
    }

    function _vaultPrincipal() internal view returns (uint256) {
        address manager = address(yieldManager);
        return _tokenBalance() + (manager != address(0) ? IPredictionMarketYieldManager(manager).managedAssets() : 0);
    }

    function _ensureLiquidity(uint256 amount) internal {
        if (_tokenBalance() >= amount) return;
        address manager = address(yieldManager);
        if (manager == address(0)) revert InsufficientLiquidity();
        uint256 shortfall = amount - _tokenBalance();
        IPredictionMarketYieldManager(manager).recallToTreasury(shortfall);
        if (_tokenBalance() < amount) revert InsufficientLiquidity();
    }

    function _tokenBalance() internal view returns (uint256) {
        (bool ok, bytes memory data) =
            asset.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
        if (!ok || data.length != 32) revert BalanceCheckFailed();
        return abi.decode(data, (uint256));
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount));
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _deployPoseidon() internal returns (address poseidon2Addr) {
        poseidon2Addr = address(new Poseidon2Yul_BN254());
    }
}
