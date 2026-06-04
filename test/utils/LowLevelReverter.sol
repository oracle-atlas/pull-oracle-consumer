// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

/**
 * A helper library for Foundry tests to bridge the gap between low-level calls and vm.expectRevert()
 * This utility ensures any failure in a low-level call is re-thrown to be caught by the test runner.
 */
library LowLevelReverter {
    /**
     * Execute a low-level staticcall and revert with the original error if it fails
     */
    function revertingStaticcall(address target, bytes memory payload) internal view returns (bytes memory returnData) {
        _validateTarget(target);

        bool success;
        (success, returnData) = target.staticcall(payload);
        _handleResponse(success, returnData);
    }

    /**
     * Execute a low-level call and revert with the original error if it fails
     */
    function revertingCall(address target, bytes memory payload) internal returns (bytes memory returnData) {
        _validateTarget(target);

        bool success;
        (success, returnData) = target.call(payload);
        _handleResponse(success, returnData);
    }

    /**
     * Validate that the target address is a valid contract
     */
    function _validateTarget(address target) private view {
        // Ensure the target is not the zero address
        require(target != address(0), "LowLevelReverter: call to zero address");

        uint256 size;
        assembly {
            size := extcodesize(target)
        }
        require(size > 0, "LowLevelReverter: call to non-contract address");
    }

    /**
     * Handle the response of a low-level call, bubbling up errors if necessary
     */
    function _handleResponse(bool success, bytes memory returnData) private pure {
        if (!success) {
            // Revert with generic message if no return data is provided
            if (returnData.length == 0) {
                revert("LowLevelReverter: low-level call reverted without data");
            }

            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }
}
