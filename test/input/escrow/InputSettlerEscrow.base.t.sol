// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { EfficiencyLib } from "the-compact/src/lib/EfficiencyLib.sol";

import { InputSettlerEscrow } from "../../../src/input/escrow/InputSettlerEscrow.sol";
import { LibAddress } from "../../../src/libs/LibAddress.sol";

import { AllowOpenType } from "../../../src/input/types/AllowOpenType.sol";
import { MandateOutput } from "../../../src/input/types/MandateOutputType.sol";
import { StandardOrder } from "../../../src/input/types/StandardOrderType.sol";
import { IInputSettlerEscrow } from "../../../src/interfaces/IInputSettlerEscrow.sol";
import { OutputSettlerCoin } from "../../../src/output/coin/OutputSettlerCoin.sol";

import { AlwaysYesOracle } from "../../mocks/AlwaysYesOracle.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { Permit2Test } from "./Permit2.t.sol";

interface EIP712 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

contract InputSettlerEscrowTestBase is Permit2Test {
    using LibAddress for uint256;

    event Transfer(address from, address to, uint256 afmount);
    event Transfer(address by, address from, address to, uint256 id, uint256 amount);
    event CompactRegistered(address indexed sponsor, bytes32 claimHash, bytes32 typehash);
    event NextGovernanceFee(uint64 nextGovernanceFee, uint64 nextGovernanceFeeTime);
    event GovernanceFeeChanged(uint64 oldGovernanceFee, uint64 newGovernanceFee);

    uint64 constant GOVERNANCE_FEE_CHANGE_DELAY = 7 days;
    uint64 constant MAX_GOVERNANCE_FEE = 10 ** 18 * 0.05; // 10%

    address inputSettlerEscrow;
    OutputSettlerCoin outputSettlerCoin;

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

    function orderFinalised(
        uint256[2][] calldata,
        /* inputs */
        bytes calldata cdat
    ) external virtual {
        assertEq(expectedCalldata, cdat, "Calldata does not match");
    }

    function setUp() public virtual override {
        super.setUp();
        inputSettlerEscrow = address(new InputSettlerEscrow());

        DOMAIN_SEPARATOR = EIP712(inputSettlerEscrow).DOMAIN_SEPARATOR();

        outputSettlerCoin = new OutputSettlerCoin();

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
        anotherToken.approve(address(outputSettlerCoin), type(uint256).max);
    }

    function witnessHash(
        StandardOrder memory order
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    bytes(
                        "Permit2Witness(uint32 expires,address inputOracle,MandateOutput[] outputs)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes call,bytes context)"
                    )
                ),
                order.expires,
                order.inputOracle,
                outputsHash(order.outputs)
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
                            "MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes call,bytes context)"
                        )
                    ),
                    output.oracle,
                    output.settler,
                    output.chainId,
                    output.token,
                    output.amount,
                    output.recipient,
                    keccak256(output.call),
                    keccak256(output.context)
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
        bytes32 domainSeparator = EIP712(inputSettlerEscrow).DOMAIN_SEPARATOR();
        bytes32 msgHash = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, AllowOpenType.hashAllowOpen(orderId, destination, call))
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }

    function getPermit2Signature(
        uint256 privateKey,
        StandardOrder memory order
    ) internal view returns (bytes memory sig) {
        uint256[2][] memory inputs = order.inputs;
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
                            "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,Permit2Witness witness)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes call,bytes context)TokenPermissions(address token,uint256 amount)Permit2Witness(uint32 expires,address inputOracle,MandateOutput[] outputs)"
                        ),
                        keccak256(tokenPermissionsHashes),
                        inputSettlerEscrow,
                        order.nonce,
                        order.fillDeadline,
                        witnessHash(order)
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }

    function get3009Signature(
        uint256 privateKey,
        address inputSettler,
        uint256 inputIndex,
        StandardOrder memory order
    ) internal view returns (bytes memory sig) {
        uint256[2] memory input = order.inputs[inputIndex];
        bytes32 domainSeparator = EIP712(input[0].fromIdentifier()).DOMAIN_SEPARATOR();
        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(
                    abi.encode(
                        keccak256(
                            "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
                        ),
                        order.user,
                        inputSettler,
                        input[1],
                        0,
                        order.fillDeadline,
                        InputSettlerEscrow(inputSettler).orderIdentifier(order)
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
