// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {HolderRewards} from "../src/HolderRewards.sol";
import {Network} from "../src/Network.sol";
import {OracleAttestation} from "../src/oracle/OracleAttestation.sol";
import {OracleQuestion} from "../src/oracle/OracleQuestion.sol";
import {TestSigner} from "./mocks/Mocks.sol";

contract OracleVerificationHarness is HolderRewards {
    constructor() HolderRewards(address(1), address(2), address(3)) {}

    function verify(OracleAttestation.Attestation calldata a, bytes calldata sig) external {
        _verifyAttestation(a, sig);
        _consume(a.requestId);
    }
}

contract OracleConformanceTest is Test {
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    /// @dev anvil's second account: the vector's attester. A test key, never a real one.
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;

    /// @dev The callback's canonical signature. Its selector is what the intake calls: a struct that
    /// differs from the protocol's by one field has another selector and is never reached.
    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";

    OracleVerificationHarness consumer;

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        deployCodeTo("OracleConformance.t.sol:OracleVerificationHarness", VECTOR_CONSUMER);
        consumer = OracleVerificationHarness(VECTOR_CONSUMER);
        // Test-only ERC1271 adapter for the published vector signer; production has no signer setter.
        vm.etch(Network.ORACLE_SIGNER, address(new TestSigner(SIGNER)).code);
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    function testDigestMatchesPublishedProtocolVector() public view {
        assertEq(consumer.attestationDigest(vector()), VECTOR_DIGEST);
    }

    function testPublishedProtocolSignatureVerifiesInActualConsumerBase() public {
        consumer.verify(vector(), VECTOR_SIGNATURE);
        assertTrue(consumer.consumed(vector().requestId));
    }

    function testCallbackSelectorMatchesCanonicalFifteenFieldTuple() public view {
        assertEq(consumer.onOracleResult.selector, bytes4(keccak256(bytes(CALLBACK))));
    }

    function testQuestionHashMatchesPublishedProtocolVector() public pure {
        OracleQuestion.Question memory q;
        q.question = "Which Uniswap v4 pool did the most WETH volume in the last day?";
        q.chainId = 1;
        q.fromBlock = 100;
        q.toBlock = 200;
        q.answerType = 5;
        q.head = 1;
        q.definitions = new OracleQuestion.Definition[](1);
        q.definitions[0] = OracleQuestion.Definition(
            "denomination", "WETH, summed as the absolute swapped amount on the WETH side"
        );
        assertEq(OracleQuestion.hash(q), 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb);
    }
}
