// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { EfficiencyLib } from "the-compact/src/lib/EfficiencyLib.sol";

import { CoinFiller } from "../../../src/fillers/coin/CoinFiller.sol";
import { GaslessCrossChainOrder } from "../../../src/interfaces/IERC7683.sol";
import { ISettler7683 } from "../../../src/interfaces/ISettler7683.sol";
import { MandateERC7683 } from "../../../src/settlers/7683/Order7683Type.sol";
import { Settler7683 } from "../../../src/settlers/7683/Settler7683.sol";
import { AllowOpenType } from "../../../src/settlers/types/AllowOpenType.sol";
import { MandateOutput } from "../../../src/settlers/types/MandateOutputType.sol";
import { OrderPurchase } from "../../../src/settlers/types/OrderPurchaseType.sol";
import { StandardOrder } from "../../../src/settlers/types/StandardOrderType.sol";

import { AlwaysYesOracle } from "../../mocks/AlwaysYesOracle.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { Permit2Test } from "./Permit2.t.sol";

interface EIP712 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface ISettler7683Harness is ISettler7683 {
    function validateFills(
        StandardOrder calldata order,
        bytes32 orderId,
        bytes32[] calldata solvers,
        uint32[] calldata timestamps
    ) external view;

    function validateFills(
        StandardOrder calldata order,
        bytes32 orderId,
        bytes32 solver,
        uint32[] calldata timestamps
    ) external view;
}

contract Settler7683Harness is Settler7683, ISettler7683Harness {
    function validateFills(
        StandardOrder calldata order,
        bytes32 orderId,
        bytes32[] calldata solvers,
        uint32[] calldata timestamps
    ) external view {
        _validateFills(order, orderId, solvers, timestamps);
    }

    function validateFills(
        StandardOrder calldata order,
        bytes32 orderId,
        bytes32 solver,
        uint32[] calldata timestamps
    ) external view {
        _validateFills(order, orderId, solver, timestamps);
    }
}

contract Settler7683TestBase is Permit2Test {
    event Transfer(address from, address to, uint256 amount);
    event Transfer(address by, address from, address to, uint256 id, uint256 amount);
    event CompactRegistered(address indexed sponsor, bytes32 claimHash, bytes32 typehash);
    event NextGovernanceFee(uint64 nextGovernanceFee, uint64 nextGovernanceFeeTime);
    event GovernanceFeeChanged(uint64 oldGovernanceFee, uint64 newGovernanceFee);

    uint64 constant GOVERNANCE_FEE_CHANGE_DELAY = 7 days;
    uint64 constant MAX_GOVERNANCE_FEE = 10 ** 18 * 0.05; // 10%

    address settler7683;
    CoinFiller coinFiller;

    address alwaysYesOracle;

    address owner;

    uint256 swapperPrivateKey;
    address swapper;
    uint256 solverPrivateKey;
    address solver;
    uint256 testGuardianPrivateKey;
    address testGuardian;

    MockERC20 token;
    MockERC20 anotherToken;

    address alwaysOKAllocator;
    bytes12 alwaysOkAllocatorLockTag;
    bytes32 DOMAIN_SEPARATOR;

    bytes expectedCalldata;

    function inputsFilled(
        uint256[2][] calldata,
        /* inputs */
        bytes calldata cdat
    ) external virtual {
        assertEq(expectedCalldata, cdat, "Calldata does not match");
    }

    function setUp() public virtual override {
        super.setUp();
        settler7683 = address(new Settler7683Harness());

        DOMAIN_SEPARATOR = EIP712(settler7683).DOMAIN_SEPARATOR();

        coinFiller = new CoinFiller();

        token = new MockERC20("Mock ERC20", "MOCK", 18);
        anotherToken = new MockERC20("Mock2 ERC20", "MOCK2", 18);

        (swapper, swapperPrivateKey) = makeAddrAndKey("swapper");
        (solver, solverPrivateKey) = makeAddrAndKey("solver");

        alwaysYesOracle = address(new AlwaysYesOracle());

        token.mint(swapper, 1e18);

        anotherToken.mint(solver, 1e18);

        vm.prank(swapper);
        token.approve(address(permit2), type(uint256).max);
        vm.prank(solver);
        anotherToken.approve(address(coinFiller), type(uint256).max);
    }

    function witnessHash(
        GaslessCrossChainOrder memory order
    ) internal pure returns (bytes32) {
        MandateERC7683 memory orderData = abi.decode(order.orderData, (MandateERC7683));
        return keccak256(
            abi.encode(
                keccak256(
                    bytes(
                        "GaslessCrossChainOrder(address originSettler,address user,uint256 nonce,uint256 originChainId,uint32 openDeadline,uint32 fillDeadline,bytes32 orderDataType,MandateERC7683 orderData)MandateERC7683(uint32 expiry,address localOracle,uint256[2][] inputs,MandateOutput[] outputs)MandateOutput(bytes32 remoteOracle,bytes32 remoteFiller,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes remoteCall,bytes fulfillmentContext)"
                    )
                ),
                order.originSettler,
                order.user,
                order.nonce,
                order.originChainId,
                order.openDeadline,
                order.fillDeadline,
                order.orderDataType,
                keccak256(
                    abi.encode(
                        keccak256(
                            bytes(
                                "MandateERC7683(uint32 expiry,address localOracle,uint256[2][] inputs,MandateOutput[] outputs)MandateOutput(bytes32 remoteOracle,bytes32 remoteFiller,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes remoteCall,bytes fulfillmentContext)"
                            )
                        ),
                        orderData.expiry,
                        orderData.localOracle,
                        keccak256(abi.encodePacked(orderData.inputs)),
                        outputsHash(orderData.outputs)
                    )
                )
            )
        );
    }

    function outputsHash(
        MandateOutput[] memory outputs
    ) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](outputs.length);
        for (uint256 i = 0; i < outputs.length; ++i) {
            MandateOutput memory output = outputs[i];
            hashes[i] = keccak256(
                abi.encode(
                    keccak256(
                        bytes(
                            "MandateOutput(bytes32 remoteOracle,bytes32 remoteFiller,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes remoteCall,bytes fulfillmentContext)"
                        )
                    ),
                    output.remoteOracle,
                    output.remoteFiller,
                    output.chainId,
                    output.token,
                    output.amount,
                    output.recipient,
                    keccak256(output.remoteCall),
                    keccak256(output.fulfillmentContext)
                )
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function getOrderOpenSignature(
        uint256 privateKey,
        bytes32 orderId,
        bytes32 destination,
        bytes calldata call
    ) external view returns (bytes memory sig) {
        bytes32 domainSeparator = EIP712(settler7683).DOMAIN_SEPARATOR();
        bytes32 msgHash = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, AllowOpenType.hashAllowOpen(orderId, destination, call))
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }

    function getPermit2Signature(
        uint256 privateKey,
        GaslessCrossChainOrder memory order
    ) internal view returns (bytes memory sig) {
        MandateERC7683 memory orderData = abi.decode(order.orderData, (MandateERC7683));

        uint256[2][] memory inputs = orderData.inputs;
        bytes memory tokenPermissionsHashes = hex"";
        for (uint256 i; i < inputs.length; ++i) {
            uint256[2] memory input = inputs[i];
            address inputToken = EfficiencyLib.asSanitizedAddress(input[0]);
            uint256 amount = input[1];
            tokenPermissionsHashes = abi.encodePacked(
                tokenPermissionsHashes,
                keccak256(abi.encode(keccak256("TokenPermissions(address token,uint256 amount)"), inputToken, amount))
            );
        }
        bytes32 domainSeparator = EIP712(permit2).DOMAIN_SEPARATOR();
        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(
                    abi.encode(
                        keccak256(
                            "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,GaslessCrossChainOrder witness)GaslessCrossChainOrder(address originSettler,address user,uint256 nonce,uint256 originChainId,uint32 openDeadline,uint32 fillDeadline,bytes32 orderDataType,MandateERC7683 orderData)MandateERC7683(uint32 expiry,address localOracle,uint256[2][] inputs,MandateOutput[] outputs)MandateOutput(bytes32 remoteOracle,bytes32 remoteFiller,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes remoteCall,bytes fulfillmentContext)TokenPermissions(address token,uint256 amount)"
                        ),
                        keccak256(tokenPermissionsHashes),
                        settler7683,
                        order.nonce,
                        order.openDeadline,
                        witnessHash(order)
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }

    error InvalidProofSeries();

    mapping(bytes proofSeries => bool valid) _validProofSeries;

    function efficientRequireProven(
        bytes calldata proofSeries
    ) external view {
        if (!_validProofSeries[proofSeries]) revert InvalidProofSeries();
    }
}
