// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Admin } from "contracts/base/Admin.sol";
import { IGasCostAdapter } from "contracts/interfaces/IGasCostAdapter.sol";

interface IOpStackGasPriceOracle {
    function getL1Fee(
        bytes calldata data
    ) external view returns (uint256);

    function getL1FeeUpperBound(
        uint256 unsignedTxSize
    ) external view returns (uint256);
}

interface IOpStackL1Block {
    function operatorFeeScalar() external view returns (uint32);
    function operatorFeeConstant() external view returns (uint64);
}

interface IScrollL1GasPriceOracle {
    function getL1Fee(
        bytes calldata data
    ) external view returns (uint256);
}

abstract contract GasCostAdapterBase is Admin, IGasCostAdapter {
    /// ERRORS ///

    error L1FeeOracleUnavailable();

    /// EVENTS ///

    event OverheadSet(uint256 oldOverhead, uint256 newOverhead);

    /// STORAGE ///

    uint256 public overhead;

    constructor(
        address admin_,
        uint256 overhead_
    ) Admin(admin_) {
        overhead = overhead_;
        emit OverheadSet(0, overhead_);
    }

    function setOverhead(
        uint256 newOverhead
    ) external onlyAdmin {
        emit OverheadSet(overhead, newOverhead);
        overhead = newOverhead;
    }

    function _executionCost(
        uint256 l2GasUsed
    ) internal view returns (uint256) {
        return _chargeableGasUsed(l2GasUsed) * tx.gasprice;
    }

    function _chargeableGasUsed(
        uint256 l2GasUsed
    ) internal view returns (uint256) {
        return l2GasUsed + overhead;
    }
}

/// @title EvmGasCostAdapter
/// @notice Adapter for L1 and EVM chains where tx.gasprice covers total cost.
contract EvmGasCostAdapter is GasCostAdapterBase {
    constructor(
        address admin_,
        uint256 overhead_
    ) GasCostAdapterBase(admin_, overhead_) { }

    function txCost(
        uint256 l2GasUsed,
        bytes calldata,
        uint256
    ) external view returns (uint256) {
        return _executionCost(l2GasUsed);
    }
}

/// @title OpStackGasCostAdapter
/// @notice Adapter for OP-Stack chains where L1 data fee is charged separately.
contract OpStackGasCostAdapter is GasCostAdapterBase {
    address internal constant GAS_PRICE_ORACLE =
        0x420000000000000000000000000000000000000F;
    address internal constant L1_BLOCK =
        0x4200000000000000000000000000000000000015;

    constructor(
        address admin_,
        uint256 overhead_
    ) GasCostAdapterBase(admin_, overhead_) { }

    function txCost(
        uint256 l2GasUsed,
        bytes calldata data,
        uint256 batchSize
    ) external view returns (uint256) {
        uint256 gasUsed = _chargeableGasUsed(l2GasUsed);
        return gasUsed * tx.gasprice + _l1Fee(data)
            + _operatorFee(gasUsed, batchSize);
    }

    function _l1Fee(
        bytes calldata data
    ) internal view returns (uint256) {
        (bool success, bytes memory result) = GAS_PRICE_ORACLE.staticcall(
            abi.encodeWithSelector(
                IOpStackGasPriceOracle.getL1Fee.selector, data
            )
        );
        if (success && result.length >= 32) {
            return abi.decode(result, (uint256));
        }

        (success, result) = GAS_PRICE_ORACLE.staticcall(
            abi.encodeWithSelector(
                IOpStackGasPriceOracle.getL1FeeUpperBound.selector, data.length
            )
        );
        if (success && result.length >= 32) {
            return abi.decode(result, (uint256));
        }

        revert L1FeeOracleUnavailable();
    }

    function _operatorFee(
        uint256 gasUsed,
        uint256 batchSize
    ) internal view returns (uint256) {
        (bool scalarSuccess, bytes memory scalarResult) = L1_BLOCK.staticcall(
            abi.encodeWithSelector(IOpStackL1Block.operatorFeeScalar.selector)
        );
        if (!scalarSuccess || scalarResult.length < 32) return 0;

        (bool constantSuccess, bytes memory constantResult) = L1_BLOCK.staticcall(
            abi.encodeWithSelector(IOpStackL1Block.operatorFeeConstant.selector)
        );
        if (!constantSuccess || constantResult.length < 32) return 0;

        uint256 scalar = abi.decode(scalarResult, (uint256));
        uint256 constantFee = abi.decode(constantResult, (uint256));

        // Current OP Stack chains use the post-Jovian operator fee formula.
        // The scalar term is genuinely marginal (it scales with this op's
        // gas), but `constantFee` is levied once per TRANSACTION. Charging it
        // whole to every item made a batch of N bill N times a cost the keeper
        // paid once. Truncation leaves the total at or just under the real
        // constant, which under-reimburses by at most `batchSize - 1` wei.
        return constantFee / batchSize + gasUsed * scalar * 100;
    }
}

/// @title ArbitrumGasCostAdapter
/// @notice Adapter for Arbitrum where tx.gasprice already includes L1 cost.
contract ArbitrumGasCostAdapter is GasCostAdapterBase {
    constructor(
        address admin_,
        uint256 overhead_
    ) GasCostAdapterBase(admin_, overhead_) { }

    function txCost(
        uint256 l2GasUsed,
        bytes calldata,
        uint256
    ) external view returns (uint256) {
        return _executionCost(l2GasUsed);
    }
}

/// @title ScrollGasCostAdapter
/// @notice Adapter for Scroll where L1 data fee is exposed via Scroll's oracle.
contract ScrollGasCostAdapter is GasCostAdapterBase {
    address internal constant L1_GAS_PRICE_ORACLE =
        0x5300000000000000000000000000000000000002;

    constructor(
        address admin_,
        uint256 overhead_
    ) GasCostAdapterBase(admin_, overhead_) { }

    function txCost(
        uint256 l2GasUsed,
        bytes calldata data,
        uint256
    ) external view returns (uint256) {
        return _executionCost(l2GasUsed) + _l1Fee(data);
    }

    function _l1Fee(
        bytes calldata data
    ) internal view returns (uint256) {
        (bool success, bytes memory result) = L1_GAS_PRICE_ORACLE.staticcall(
            abi.encodeWithSelector(
                IScrollL1GasPriceOracle.getL1Fee.selector, data
            )
        );
        if (success && result.length >= 32) {
            return abi.decode(result, (uint256));
        }

        revert L1FeeOracleUnavailable();
    }
}

/// @title EtherlinkGasCostAdapter
/// @notice Adapter for Etherlink's execution fee plus data-inclusion fee.
contract EtherlinkGasCostAdapter is GasCostAdapterBase {
    /// EVENTS ///

    event InclusionFeeParamsSet(
        uint256 oldInclusionFeePerByte,
        uint256 newInclusionFeePerByte,
        uint256 oldInclusionFixedBytes,
        uint256 newInclusionFixedBytes
    );

    /// STORAGE ///

    uint256 public inclusionFeePerByte;
    uint256 public inclusionFixedBytes;

    constructor(
        address admin_,
        uint256 overhead_,
        uint256 inclusionFeePerByte_,
        uint256 inclusionFixedBytes_
    ) GasCostAdapterBase(admin_, overhead_) {
        inclusionFeePerByte = inclusionFeePerByte_;
        inclusionFixedBytes = inclusionFixedBytes_;
        emit InclusionFeeParamsSet(
            0, inclusionFeePerByte_, 0, inclusionFixedBytes_
        );
    }

    function setInclusionFeeParams(
        uint256 newInclusionFeePerByte,
        uint256 newInclusionFixedBytes
    ) external onlyAdmin {
        emit InclusionFeeParamsSet(
            inclusionFeePerByte,
            newInclusionFeePerByte,
            inclusionFixedBytes,
            newInclusionFixedBytes
        );

        inclusionFeePerByte = newInclusionFeePerByte;
        inclusionFixedBytes = newInclusionFixedBytes;
    }

    function txCost(
        uint256 l2GasUsed,
        bytes calldata data,
        uint256 batchSize
    ) external view returns (uint256) {
        // `data.length` is this op's own payload and is marginal, but
        // `inclusionFixedBytes` is the transaction envelope — one per
        // transaction, not one per operation — so it is shared across the
        // batch rather than charged whole to each item.
        //
        // Price the envelope FIRST, then divide. Dividing the byte count
        // instead would drop a whole `inclusionFeePerByte` for every truncated
        // byte: at 4e12 wei/byte with 150 fixed bytes, a 4-item batch would
        // allocate 37 bytes each — 148 of 150 — and silently lose 8e12 wei.
        // Dividing the priced fee bounds the shortfall at `batchSize - 1` wei.
        return _executionCost(l2GasUsed)
            + (inclusionFeePerByte * inclusionFixedBytes) / batchSize
            + inclusionFeePerByte * data.length;
    }
}
