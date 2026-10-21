// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {VaultChild} from "./VaultChild.sol";
import {Network} from "./Network.sol";
import {IIntake} from "./interfaces/IIntake.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./oracle/OracleAttestation.sol";
import {OracleQuestion} from "./oracle/OracleQuestion.sol";

interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}

contract HolderRewards is VaultChild, OracleAttestationConsumer {
    using SafeERC20 for IERC20;

    uint256 public constant CLAIM_WINDOW = 28 days;
    uint256 public constant RETRY_DELAY = 1 days;
    uint16 public constant PANEL_SIZE = 30;
    uint16 public constant QUORUM = 20;
    uint256 public constant VALID_FOR = 7 days;
    uint256 public constant ORACLE_REQUEST_GAS_LIMIT = 3_000_000;

    struct Epoch {
        uint256 pot;
        uint256 claimed;
        uint256 snapshotPot;
        uint256 carry;
        uint256 snapshotBlock;
        uint256 createdAt;
        uint256 requestedAt;
        bytes32 requestId;
        bytes32 questionHash;
        bytes32 root;
        bool ready;
        bool closed;
    }

    error OnlySelf();
    error InvalidEpoch();
    error EpochClosed();
    error NotReady();
    error AlreadyClaimed();
    error BadProof();
    error PotExceeded();
    error TooEarly();
    error OnlyIntake();
    error UnknownRequest();
    error InvalidAnswer();
    error AlreadyAnswered();
    error InsufficientDeposit();
    error BlockNumberUnavailable();

    address public immutable jobsVault;
    address public immutable compensationVault;
    uint256 public currentEpoch;
    uint256 public totalReserved;
    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;
    mapping(bytes32 => uint256) public pending;

    event EpochOpened(uint256 indexed epoch, uint256 deposit, uint256 snapshotBlock);
    event OracleRequested(
        uint256 indexed epoch, bytes32 indexed requestId, bytes32 questionHash, uint256 price
    );
    event OracleDeferred(uint256 indexed epoch);
    event RootReceived(uint256 indexed epoch, bytes32 root);
    event Claimed(uint256 indexed epoch, address indexed account, uint256 amount);
    event RolledOver(uint256 indexed fromEpoch, uint256 indexed toEpoch, uint256 amount);

    constructor(address vault_, address jobsVault_, address compensationVault_)
        VaultChild(vault_)
        OracleAttestationConsumer(Network.ORACLE_SIGNER)
    {
        require(jobsVault_ != address(0) && compensationVault_ != address(0), "zero sibling");
        jobsVault = jobsVault_;
        compensationVault = compensationVault_;
    }

    function setToken(address token_) external onlyVault {
        _setToken(token_);
    }

    /// @notice Called immediately after SIMDVault transfers this week's IMD.
    function onDeposit(uint256 amount) external onlyVault nonReentrant {
        if (token == address(0)) revert NotConfigured();
        if (IERC20(Network.IMD).balanceOf(address(this)) < totalReserved + amount) {
            revert InsufficientDeposit();
        }
        uint256 carry;
        if (currentEpoch != 0) {
            Epoch storage previous = epochs[currentEpoch];
            carry = previous.carry;
            previous.pot -= carry;
            previous.carry = 0;
        }
        uint256 id = _openEpoch(amount + carry);
        totalReserved += amount;
        // This isolated self-call rolls back fee/accounting/approval together on any Intake error.
        // The request is paid from this epoch's own pot: the new deposit plus the carry that just
        // moved into it. It never spends another open epoch's reserve.
        try this.requestDepositedEpoch{gas: ORACLE_REQUEST_GAS_LIMIT}(id, amount + carry) {}
        catch {
            emit OracleDeferred(id);
        }
    }

    function requestDepositedEpoch(uint256 id, uint256 budget) external {
        if (msg.sender != address(this)) revert OnlySelf();
        uint256 price = IIntake(Network.INTAKE).priceOf(Network.ORACLE_ACTION, Network.IMD);
        if (price == 0 || price >= budget) revert InsufficientDeposit();
        Epoch storage e = epochs[id];
        e.pot -= price;
        e.snapshotPot -= price;
        totalReserved -= price;
        _ask(id, price);
    }

    /// @notice Anyone can sponsor another attempt; retries never consume reward pots.
    /// @dev Uses the same deposit block and payout budget, so every request of an epoch asks the
    /// same question. Earlier requests stay valid: the first answer delivered installs the root and
    /// later ones are refused, so a sponsor can never invalidate an answer the pot already paid for.
    function retryOracle(uint256 id) external nonReentrant {
        Epoch storage e = epochs[id];
        _requireOpen(id);
        if (e.ready || e.snapshotPot == 0) revert NotReady();
        if (e.requestedAt != 0 && block.timestamp < e.requestedAt + RETRY_DELAY) revert TooEarly();
        uint256 price = IIntake(Network.INTAKE).priceOf(Network.ORACLE_ACTION, Network.IMD);
        if (price == 0) revert InsufficientDeposit();
        IERC20(Network.IMD).safeTransferFrom(msg.sender, address(this), price);
        _ask(id, price);
    }

    function onOracleResult(
        bytes32 requestId,
        OracleAttestation.Attestation calldata a,
        bytes calldata signature
    ) external nonReentrant {
        if (msg.sender != Network.INTAKE) revert OnlyIntake();
        uint256 id = pending[requestId];
        if (id == 0) revert UnknownRequest();
        _requireOpen(id);
        Epoch storage e = epochs[id];
        if (e.ready) revert AlreadyAnswered();
        if (
            a.questionHash != e.questionHash || a.chainId != block.chainid || a.fromBlock != e.snapshotBlock
                || a.toBlock != e.snapshotBlock || a.panelSize < PANEL_SIZE || a.quorum < QUORUM
                || a.agreed < a.quorum || a.agreed > a.panelSize || a.quorum > a.panelSize
                || a.issuedAt < e.createdAt || a.expiresAt < a.issuedAt || a.answer.length != 32
        ) revert InvalidAnswer();
        _verifyAttestation(a, signature);
        _consume(a.requestId);
        bytes32 root = decodeBytes32(a);
        delete pending[requestId];
        e.ready = true;
        e.root = root;
        emit RootReceived(id, root);
    }

    /// @notice amount is the IMD entitlement derived from the snapshot, in base units.
    function claim(uint256 id, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        _requireOpen(id);
        Epoch storage e = epochs[id];
        if (!e.ready) revert NotReady();
        if (hasClaimed[id][msg.sender]) revert AlreadyClaimed();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, amount))));
        if (!MerkleProof.verifyCalldata(proof, e.root, leaf)) revert BadProof();
        // Rollover carry is not in this epoch's original tree. Even an oversized signed tree
        // cannot spend it or any other epoch's reserve.
        if (amount > e.pot - e.claimed || amount > e.snapshotPot - e.claimed) revert PotExceeded();
        hasClaimed[id][msg.sender] = true;
        e.claimed += amount;
        totalReserved -= amount;
        IERC20(Network.IMD).safeTransfer(msg.sender, amount);
        emit Claimed(id, msg.sender, amount);
    }

    /// @notice Moves exactly the unclaimed balance into the current epoch and closes the old one.
    /// @dev Existing Merkle entitlements never change. The current epoch holds the carry until the
    /// next vault deposit includes it in a fresh snapshot. A latest-only rollover opens a carry epoch.
    function rollover(uint256 id) external nonReentrant {
        if (id == 0 || id > currentEpoch) revert InvalidEpoch();
        Epoch storage e = epochs[id];
        if (e.closed) revert EpochClosed();
        if (block.timestamp < e.createdAt + CLAIM_WINDOW) revert TooEarly();
        uint256 remaining = e.pot - e.claimed;
        e.closed = true;
        e.carry = 0;
        // Any other request id of this epoch still maps to it and is refused as closed.
        delete pending[e.requestId];
        if (id == currentEpoch) _openEpoch(0);
        Epoch storage destination = epochs[currentEpoch];
        destination.pot += remaining;
        destination.carry += remaining;
        emit RolledOver(id, currentEpoch, remaining);
    }

    function getEpoch(uint256 id) external view returns (Epoch memory) {
        return epochs[id];
    }

    /// @notice Deterministic question, definitions and body, inspectable before a retry.
    function question(uint256 id) public view returns (OracleQuestion.Question memory q) {
        Epoch storage e = epochs[id];
        q.question = string.concat(
            "What is the OpenZeppelin StandardMerkleTree root of IMD reward entitlements for token ",
            Strings.toHexString(token),
            " at the end of Robinhood Chain block ",
            Strings.toString(e.snapshotBlock),
            " for HolderRewards ",
            Strings.toHexString(address(this)),
            " epoch ",
            Strings.toString(id),
            " with reward budget ",
            Strings.toString(e.snapshotPot),
            " IMD base units, using the definitions?"
        );
        q.chainId = block.chainid;
        q.fromBlock = e.snapshotBlock;
        q.toBlock = e.snapshotBlock;
        q.answerType = OracleAttestation.ANSWER_BYTES32;
        q.definitions = new OracleQuestion.Definition[](4);
        q.definitions[0] = OracleQuestion.Definition(
            "allocation",
            "For every eligible positive token balance b, amount=floor(rewardBudget*b/sumEligibleBalances). Use raw ERC20 balanceOf units at the end of the snapshot block. Zero entitlements may be omitted. Return bytes32(0) if no eligible balance exists."
        );
        q.definitions[1] = OracleQuestion.Definition(
            "excluded",
            string.concat(
                "Exclude all liquidity pools holding this token, zero and burn addresses, and these addresses: ",
                Strings.toHexString(Network.POOL_MANAGER),
                ",",
                Strings.toHexString(Network.FACTORY),
                ",",
                Strings.toHexString(vault),
                ",",
                Strings.toHexString(address(this)),
                ",",
                Strings.toHexString(jobsVault),
                ",",
                Strings.toHexString(compensationVault),
                "."
            )
        );
        q.definitions[2] = OracleQuestion.Definition(
            "holders",
            "Enumerate addresses from this token's Transfer logs through the snapshot block; verify their balanceOf at that block. A liquidity pool is an AMM contract holding reserves of this token, verifiable from its code and initialization events. Exclude reserves, not LP owners."
        );
        q.definitions[3] = OracleQuestion.Definition(
            "tree",
            "OpenZeppelin StandardMerkleTree.of(values,['address','uint256']) with default sortLeaves=true; each value is [account,amount]. Leaf=keccak256(bytes.concat(keccak256(abi.encode(account,amount)))); hash each pair in ascending bytes32 order. Publish values and proofs as evidence."
        );
    }

    function oracleBody(uint256 id) external view returns (bytes memory) {
        return OracleQuestion.body(question(id), PANEL_SIZE, QUORUM, VALID_FOR);
    }

    function _ask(uint256 id, uint256 price) private {
        OracleQuestion.Question memory q = question(id);
        bytes32 hash = OracleQuestion.hash(q);
        bytes memory body = OracleQuestion.body(q, PANEL_SIZE, QUORUM, VALID_FOR);
        IERC20(Network.IMD).forceApprove(Network.INTAKE, price);
        bytes32 requestId = IIntake(Network.INTAKE)
            .request(
                Network.ORACLE_ACTION,
                body,
                IIntake.Callback(address(this), this.onOracleResult.selector),
                Network.IMD,
                price
            );
        IERC20(Network.IMD).forceApprove(Network.INTAKE, 0);
        if (requestId == bytes32(0) || pending[requestId] != 0) revert UnknownRequest();
        Epoch storage e = epochs[id];
        e.questionHash = hash;
        e.requestId = requestId;
        e.requestedAt = block.timestamp;
        pending[requestId] = id;
        emit OracleRequested(id, requestId, hash, price);
    }

    function _openEpoch(uint256 amount) private returns (uint256 id) {
        id = ++currentEpoch;
        Epoch storage e = epochs[id];
        e.pot = amount;
        e.snapshotPot = amount;
        e.snapshotBlock = snapshotHead();
        e.createdAt = block.timestamp;
        emit EpochOpened(id, amount, e.snapshotBlock);
    }

    /// @notice Orbit's own block number. On a plain EVM with no ArbSys implementation, use NUMBER.
    /// @dev A low-level call permits precompiles with no EVM bytecode. Foundry's offline EVM can
    /// lack ArbSys even with chainId 4663; its NUMBER and any native ArbSys emulation use vm.roll.
    /// A present but failing ArbSys is never silently replaced with the L1 block number.
    function snapshotHead() public view returns (uint256) {
        (bool ok, bytes memory data) = address(100).staticcall(abi.encodeCall(IArbSys.arbBlockNumber, ()));
        if (ok && data.length == 32) return abi.decode(data, (uint256));
        if (ok && data.length == 0 && address(100).code.length == 0) return block.number;
        revert BlockNumberUnavailable();
    }

    function _requireOpen(uint256 id) private view {
        if (id == 0 || id > currentEpoch) revert InvalidEpoch();
        Epoch storage e = epochs[id];
        if (e.closed) revert EpochClosed();
    }
}
