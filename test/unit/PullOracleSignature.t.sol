// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {BaseTest} from "test/utils/BaseTest.t.sol";
import {LowLevelReverter} from "test/utils/LowLevelReverter.sol";
import {PullOracleSignatureMock} from "test/mocks/PullOracleSignatureMock.sol";
import {IPullOracleBase} from "interfaces/IPullOracleBase.sol";
import {MAX_LOW_S_VALUE} from "constants/Constants.sol";

/**
 * Verify cryptographic integrity and EIP-2 compliance of the recovery engine
 */
contract PullOracleSignatureTest is BaseTest {
    using LowLevelReverter for address;

    PullOracleSignatureMock internal mock = new PullOracleSignatureMock();

    /* ————————————————————————————————————————————————————————————————————————
                                HAPPY PATH TESTS
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * Validate successful signer recovery using the dynamic payload factory
     * Test with a multi-package scenario (e.g., 3 packages) to verify pointer arithmetic.
     */
    function test_RecoverSigner_Success() public view {
        uint8 count = 3;

        // Generate the full call environment with 3 mock packages and a valid signature
        bytes memory fullPayload = _prepareRecoverSignerCall(PRIMARY_SIGNER_PK, count);

        (bool success, bytes memory returnData) = address(mock).staticcall(fullPayload);
        assertTrue(success);

        address recovered = abi.decode(returnData, (address));
        assertEq(recovered, PRIMARY_SIGNER);
    }

    /**
     * Verify that tampering with even a single byte of package data results in a wrong signer
     */
    function test_RecoverSigner_TamperedData_ReturnsWrongAddress() public view {
        uint8 count = 1;
        bytes memory payload = _prepareRecoverSignerCall(PRIMARY_SIGNER_PK, count);

        // Flip bits in the first byte of the package data (located at payloadStart = 68)
        payload[68] ^= 0xff;

        (bool success, bytes memory returnData) = address(mock).staticcall(payload);
        assertTrue(success);

        address recovered = abi.decode(returnData, (address));
        assertNotEq(recovered, PRIMARY_SIGNER);
    }

    /**
     * Validate recovery resilience across a random number of packages
     */
    function test_RecoverSigner_Fuzz(uint8 count) public view {
        uint8 packageCount = uint8(bound(count, 1, type(uint8).max));

        bytes memory fullPayload = _prepareRecoverSignerCall(PRIMARY_SIGNER_PK, packageCount);
        (bool success, bytes memory returnData) = address(mock).staticcall(fullPayload);
        assertTrue(success);

        address recovered = abi.decode(returnData, (address));
        assertEq(recovered, PRIMARY_SIGNER);
    }

    /* ————————————————————————————————————————————————————————————————————————
                                    NEGATIVE TESTS
        ————————————————————————————————————————————————————————————————————————— */

    /**
     * Verify revert when a High-S value is provided to prevent malleability
     */
    function test_Revert_InvalidSignatureS() public {
        uint8 count = 1;
        uint256 invalidS = MAX_LOW_S_VALUE + 1;

        // Generate a valid base payload
        bytes memory payload = _prepareRecoverSignerCall(PRIMARY_SIGNER_PK, count);

        // Overwrite the 's' value in the calldata buffer (35B from end)
        // Offset: 35B from the end (Marker(2) + v(1) + s(32) = 35)
        uint256 sOffset = payload.length - 35;
        assembly {
            // Memory address = payload pointer + 32B (length slot) + relative offset
            mstore(add(add(payload, 0x20), sOffset), invalidS)
        }

        vm.expectRevert(IPullOracleBase.InvalidSignatureS.selector);
        address(mock).revertingStaticcall(payload);
    }

    /**
     * Ensure that an invalid 'v' value results in SignatureRecoveryFailed revert
     */
    function test_RecoverSigner_InvalidV_Revert_SignatureRecoveryFailed() public {
        uint8 count = 1;
        bytes memory payload = _prepareRecoverSignerCall(PRIMARY_SIGNER_PK, count);

        // Calculate offset for 'v' byte (Marker: 2B + v: 1B = 3B from end)
        uint256 vOffset = payload.length - 3;

        // Corrupt 'v' byte by setting it to a value other than 27 or 28 (e.g., 0)
        payload[vOffset] = bytes1(uint8(26));

        vm.expectRevert(IPullOracleBase.SignatureRecoveryFailed.selector);
        address(mock).revertingStaticcall(payload);
    }

    /**
     * Ensure that setting r to invalid ranges results in SignatureRecoveryFailed revert
     * ecrecover returns empty data if r is 0 or r >= n (where n is the curve order)
     */
    function test_RecoverSigner_InvalidR_Revert_SignatureRecoveryFailed() public {
        uint8 count = 1;
        bytes memory payload = _prepareRecoverSignerCall(PRIMARY_SIGNER_PK, count);

        // Calculate offset for 'r' byte (Marker: 2B + v: 1B + s: 32B + r: 32B = 67B from end)
        uint256 rOffset = payload.length - 67;

        // Set r to the secp256k1 curve order n (invalid: r must be in [1, n-1])
        bytes32 invalidR = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        assembly {
            // Memory address = payload pointer + 32B length slot + relative offset
            mstore(add(add(payload, 0x20), rOffset), invalidR)
        }

        vm.expectRevert(IPullOracleBase.SignatureRecoveryFailed.selector);
        address(mock).revertingStaticcall(payload);

        // Set r to zero (invalid: r must be in [1, n-1])
        payload = _prepareRecoverSignerCall(PRIMARY_SIGNER_PK, count);
        invalidR = 0;
        assembly {
            mstore(add(add(payload, 0x20), rOffset), invalidR)
        }

        vm.expectRevert(IPullOracleBase.SignatureRecoveryFailed.selector);
        address(mock).revertingStaticcall(payload);
    }

    /**
     * Demonstrate that ecrecover precompile returns empty data (returndatasize == 0)
     * when given an invalid v value, proving that scratch space is NOT overwritten.
     * This confirms the audit finding: staticcall succeeds but writes nothing to 0x00.
     */
    function test_EcrecoverPrecompile_InvalidV_ReturnsEmptyData() public view {
        // Prepare a valid signature
        bytes32 digest = keccak256("test message");
        (, bytes32 r, bytes32 s) = vm.sign(PRIMARY_SIGNER_PK, digest);

        // Corrupt v to an invalid value (not 27 or 28)
        uint8 invalidV = 26;

        uint256 returnSize;
        uint256 callSuccess;
        address recovered;

        assembly {
            let ptr := mload(0x40)
            mstore(ptr, digest)
            mstore(add(ptr, 0x20), invalidV)
            mstore(add(ptr, 0x40), r)
            mstore(add(ptr, 0x60), s)

            // Write a known non-zero marker to 0x00 before the call
            // to prove ecrecover does NOT clear it on failure
            mstore(0x00, 0xDEADBEEF)

            callSuccess := staticcall(gas(), 0x01, ptr, 128, 0x00, 32)
            returnSize := returndatasize()
            recovered := mload(0x00)
        }

        // staticcall succeeds (returns 1) even though recovery failed
        assertEq(callSuccess, 1, "staticcall should succeed");

        // returndatasize is 0 — ecrecover wrote NOTHING to the output buffer
        assertEq(returnSize, 0, "returndatasize should be 0 for invalid v");

        // 0x00 retains the stale marker — scratch space was NOT cleared
        assertEq(recovered, address(0xDEADBEEF), "scratch space should retain stale value");
    }

    /**
     * Build and sign a complete calldata payload with dynamic package generation
     * @param signerPk The private key to sign the metadata
     * @param count The number of feed packages to generate and include
     * @return fullPayload The final concatenated calldata for the staticcall
     */
    function _prepareRecoverSignerCall(uint256 signerPk, uint8 count) internal view returns (bytes memory fullPayload) {
        bytes memory packages;

        // Generate N unique 20-byte mock packages using a loop
        for (uint256 i = 0; i < count; ) {
            bytes20 mockPackage = bytes20(keccak256(abi.encode("mockPackage", i)));
            packages = abi.encodePacked(packages, mockPackage);
            unchecked {
                ++i;
            }
        }

        // Generate the cryptographic digest: [Packages(N*20B)][Count(1B)]
        bytes32 digest = keccak256(abi.encodePacked(packages, uint8(count)));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);

        // Define physical offsets (4B Selector + 32B * 2 Args = 68B)
        uint256 payloadStart = 68;
        uint256 payloadEnd = payloadStart + uint256(count) * 20;

        // Assemble the Oracle Metadata suffix
        bytes memory extraData = abi.encodePacked(packages, uint8(count), r, s, v, MAGIC_MARKER);

        return
            _attachExtraData(abi.encodeWithSelector(mock.recoverSigner.selector, payloadStart, payloadEnd), extraData);
    }
}
