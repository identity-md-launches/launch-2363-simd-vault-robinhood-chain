// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {SIMDVault} from "../src/SIMDVault.sol";

contract ConstructorProbe {
    function deploy(bytes memory code) external returns (address deployed) {
        assembly ("memory-safe") { deployed := create2(0, add(code, 32), mload(code), 0) }
        require(deployed != address(0), "constructor failed");
    }
}

contract DeploymentTest is Test {
    function testFactoryCreate2DeploymentOnEmptyChainLinksAllChildrenAndHasNoOwners() public {
        ConstructorProbe factory = new ConstructorProbe();
        bytes memory code = vm.getCode("SIMDVault.sol:SIMDVault");
        assertLe(code.length, 49152);
        SIMDVault vault = SIMDVault(payable(factory.deploy(code)));
        assertEq(vault.holderRewards().vault(), address(vault));
        assertEq(vault.jobsVault().vault(), address(vault));
        assertEq(vault.compensationVault().vault(), address(vault));
        address[4] memory applications = [
            address(vault),
            address(vault.holderRewards()),
            address(vault.jobsVault()),
            address(vault.compensationVault())
        ];
        for (uint256 i; i < applications.length; ++i) {
            assertGt(applications[i].code.length, 0);
            assertLe(applications[i].code.length, 24576);
            (bool owned,) = applications[i].staticcall(abi.encodeWithSignature("owner()"));
            assertFalse(owned);
            _checkOpcodes(applications[i].code);
        }
    }

    function _checkOpcodes(bytes memory code) private pure {
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) {
                reachable = false;
            }
        }
    }
}
