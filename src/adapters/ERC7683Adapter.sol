// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IOriginSettler, ResolvedCrossChainOrder, OnchainCrossChainOrder, GaslessCrossChainOrder, Output, FillInstruction } from "./interfaces/v0-IERC7683.sol";
import {IInputSettlerEscrow} from "../interfaces/IInputSettlerEscrow.sol";
import { StandardOrder, StandardOrderType } from "../input/types/StandardOrderType.sol";
import { LibAddress } from "../libs/LibAddress.sol";

contract ERC7683EscrowAdapter is IOriginSettler {
    using StandardOrderType for bytes;
    using StandardOrderType for StandardOrder;
    using LibAddress for bytes32;
    using LibAddress for uint256;

    error InvalidOrderDataType();
    error InvalidOrderDeadline();
    error InvalidOriginFillerData();

    bytes32 public constant ORDER_DATA_TYPE = keccak256("StandardOrder(address user,uint256 nonce,uint256 originChainId,uint32 expires,uint32 fillDeadline,address inputOracle,uint256[2][] inputs,MandateOutput[] outputs)");

    event Open(bytes32 indexed orderId, ResolvedCrossChainOrder resolvedOrder);

    IInputSettlerEscrow private immutable _inputSettlerEscrow;

    constructor(IInputSettlerEscrow inputSettlerEscrow_) {
        _inputSettlerEscrow = inputSettlerEscrow_;
    }


    function openFor(GaslessCrossChainOrder calldata order, bytes calldata signature, bytes calldata originFillerData) external {
        if(originFillerData.length > 0) revert InvalidOriginFillerData();
        if(order.orderDataType != ORDER_DATA_TYPE) revert InvalidOrderDataType();

        StandardOrder memory standardOrder = abi.decode(order.orderData, (StandardOrder));

        if(standardOrder.fillDeadline != order.fillDeadline) revert InvalidOrderDeadline();

        _inputSettlerEscrow.openFor(abi.encode(standardOrder), order.user, signature);

        bytes32 orderId = _inputSettlerEscrow.orderIdentifier(standardOrder);

        emit Open(orderId, _resolve(standardOrder));

    }


    function open(OnchainCrossChainOrder calldata order) external {
        if(order.orderDataType != ORDER_DATA_TYPE) revert InvalidOrderDataType();
        StandardOrder memory standardOrder = abi.decode(order.orderData, (StandardOrder));

        if(standardOrder.fillDeadline != order.fillDeadline) revert InvalidOrderDeadline();

        _inputSettlerEscrow.open(abi.encode(standardOrder));
        bytes32 orderId = _inputSettlerEscrow.orderIdentifier(standardOrder);

        emit Open(orderId, _resolve(standardOrder));
        
    }

    function _resolve(StandardOrder memory order) internal view returns (ResolvedCrossChainOrder memory){

        Output[] memory maxSpent = new Output[](order.outputs.length);
        FillInstruction[] memory fillInstructions = new FillInstruction[](order.outputs.length);

        Output[] memory minReceived = new Output[](order.inputs.length);

        for(uint256 i = 0; i < order.inputs.length; i++){
            uint256[2] memory input = order.inputs[i];
            minReceived[i] = Output({
                token: bytes32(input[0]),
                amount: input[1],
                recipient: bytes32(0),
                chainId: order.originChainId
            });
        }

        for(uint256 i = 0; i < order.outputs.length; i++){
            maxSpent[i] = Output({
                token: order.outputs[i].token,
                amount: type(uint256).max,
                recipient: order.outputs[i].recipient,
                chainId: order.outputs[i].chainId
            });

            fillInstructions[i] = FillInstruction({
                destinationChainId: order.outputs[i].chainId,
                destinationSettler: order.outputs[i].settler,
                originData: abi.encode(order.outputs[i])
            });
        }

        return ResolvedCrossChainOrder({
            user: order.user,
            originChainId: order.originChainId,
            openDeadline: order.fillDeadline,
            fillDeadline: order.fillDeadline,
            orderId: _inputSettlerEscrow.orderIdentifier(order),
            maxSpent: maxSpent,
            minReceived: minReceived,
            fillInstructions: fillInstructions
        });
    }
    
    function resolve(OnchainCrossChainOrder calldata order) external view returns (ResolvedCrossChainOrder memory){
        if(order.orderDataType != ORDER_DATA_TYPE) revert InvalidOrderDataType();
        StandardOrder memory standardOrder = abi.decode(order.orderData, (StandardOrder));

        return _resolve(standardOrder);
    }

    function resolveFor(GaslessCrossChainOrder calldata order, bytes calldata originFillerData) external view returns (ResolvedCrossChainOrder memory){
        if(originFillerData.length > 0) revert InvalidOriginFillerData();
        if(order.orderDataType != ORDER_DATA_TYPE) revert InvalidOrderDataType();
        StandardOrder memory standardOrder = abi.decode(order.orderData, (StandardOrder));

        if(standardOrder.fillDeadline != order.fillDeadline) revert InvalidOrderDeadline();

        return _resolve(standardOrder);
    }
    
}