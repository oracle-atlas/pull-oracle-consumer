// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {PullOracleReferenceHooks} from "libraries/PullOracleReferenceHooks.sol";

/*
 * Provide external access to internal hook functions for unit testing
 */
contract PullOracleReferenceHooksMock {
    /*
     * Expose timestamp validation logic to external testing environment
     */
    function validateTimestamp(bytes4 feedId, uint256 parsedTimestamp) external view {
        PullOracleReferenceHooks.validateTimestamp(feedId, parsedTimestamp);
    }

    /*
     * Expose signer authorization lookup for reference implementation check
     */
    function isAuthorizedSigner(address recoveredSigner) external pure returns (bool) {
        return PullOracleReferenceHooks.isAuthorizedSigner(recoveredSigner);
    }
}
