// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {PullOracleSignature} from "libraries/PullOracleSignature.sol";

contract PullOracleSignatureMock {
    /**
     * Expose internal recovery logic for unit testing
     */
    function recoverSigner(uint256 payloadStart, uint256 payloadEnd) external view returns (address) {
        return PullOracleSignature._recoverSigner(payloadStart, payloadEnd);
    }
}
