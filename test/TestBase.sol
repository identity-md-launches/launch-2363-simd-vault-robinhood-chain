// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SIMDVault} from "../src/SIMDVault.sol";
import {HolderRewards} from "../src/HolderRewards.sol";
import {JobsVault} from "../src/JobsVault.sol";
import {CompensationVault} from "../src/CompensationVault.sol";
import {VaultChild} from "../src/VaultChild.sol";
import {Network} from "../src/Network.sol";
import {OracleAttestation} from "../src/oracle/OracleAttestation.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {MockToken, MockIntake, MockFactory, MockManager, TestSigner} from "./mocks/Mocks.sol";

abstract contract TestBase is Test {
    uint256 internal constant PRICE = 0.5 ether;
    uint256 internal constant TEST_SIGNER_KEY = 0xa11ce;
    address internal alice;
    address internal bob;
    MockToken internal imd;
    MockToken internal token;
    MockIntake internal intake;
    MockFactory internal factory;
    MockManager internal manager;
    SIMDVault internal vault;
    HolderRewards internal rewards;
    JobsVault internal jobs;
    CompensationVault internal compensation;
    PoolKey internal key;

    function setUp() public virtual {
        vm.chainId(4663);
        vm.warp(1_800_000_000);
        vm.roll(30_000_000);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vm.etch(Network.IMD, address(new MockToken(18)).code);
        vm.etch(Network.INTAKE, address(new MockIntake()).code);
        vm.etch(Network.FACTORY, address(new MockFactory()).code);
        vm.etch(Network.POOL_MANAGER, address(new MockManager()).code);
        vm.etch(Network.ORACLE_SIGNER, address(new TestSigner(vm.addr(TEST_SIGNER_KEY))).code);
        imd = MockToken(Network.IMD);
        intake = MockIntake(Network.INTAKE);
        factory = MockFactory(payable(Network.FACTORY));
        manager = MockManager(Network.POOL_MANAGER);
        manager.setInitialized(true);
        intake.setPrice(PRICE);
        token = new MockToken(18);
        key = poolFor(address(token));
        vault = new SIMDVault();
        rewards = vault.holderRewards();
        jobs = vault.jobsVault();
        compensation = vault.compensationVault();
        factory.configure(key, address(vault));
        token.mint(Network.POOL_MANAGER, 1e32);
    }

    function poolFor(address t) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(t < Network.IMD ? t : Network.IMD),
            currency1: Currency.wrap(t < Network.IMD ? Network.IMD : t),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function bind() internal {
        vm.prank(Network.DEV);
        vault.bindLaunch(7, address(token));
    }

    function deposit(uint256 amount) internal returns (uint256 id) {
        imd.mint(address(rewards), amount);
        vm.prank(address(vault));
        rewards.onDeposit(amount);
        return rewards.currentEpoch();
    }

    function leaf(address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    function pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function proof(bytes32 sibling) internal pure returns (bytes32[] memory result) {
        result = new bytes32[](1);
        result[0] = sibling;
    }

    function answer(uint256 id, bytes32 root) internal view returns (OracleAttestation.Attestation memory a) {
        HolderRewards.Epoch memory e = rewards.getEpoch(id);
        a = OracleAttestation.Attestation({
            requestId: keccak256(abi.encode("oracle UUID", id, e.requestId)),
            chainId: block.chainid,
            questionHash: e.questionHash,
            answerType: 2,
            answer: abi.encode(root),
            figure: 0,
            fromBlock: uint64(e.snapshotBlock),
            toBlock: uint64(e.snapshotBlock),
            blockHash: keccak256("snapshot block"),
            panelJobId: keccak256("panel"),
            panelSize: 30,
            quorum: 20,
            agreed: 25,
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp() + 7 days)
        });
    }

    function signature(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_SIGNER_KEY, rewards.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function deliver(uint256 id, bytes32 root) internal {
        OracleAttestation.Attestation memory a = answer(id, root);
        bytes memory sig = signature(a);
        assertTrue(
            intake.deliver(
                rewards.getEpoch(id).requestId, abi.encode(rewards.getEpoch(id).requestId, a, sig)
            ),
            "oracle callback must complete under 200k gas"
        );
    }
}
