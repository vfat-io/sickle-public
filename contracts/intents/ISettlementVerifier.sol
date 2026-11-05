// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IntentTypes } from "./IntentTypes.sol";

interface ISettlementVerifier {
    function verifySettlement(
        address intentRouter,
        IntentTypes.Intent calldata intent,
        IntentTypes.Settlement calldata settlement
    ) external view;
}
