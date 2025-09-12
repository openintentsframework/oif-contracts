// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

// Opcodes
bytes1 constant OP_0 = 0x00;
bytes1 constant PUSH_20 = 0x14;
bytes1 constant PUSH_32 = 0x20;
bytes1 constant PUSH_75 = 0x4b;
bytes1 constant OP_PUSHDATA1 = 0x4c;
bytes1 constant OP_PUSHDATA2 = 0x4d;
bytes1 constant OP_PUSHDATA4 = 0x4e;
/**
 * @dev
 * If you want OP_X and have X (X <= 16) then X + OP_1_OFFSET = OP_X.
 * If you want X and have OP_X (OP_0 < OP_X <= OP_16) then OP_X - OP_1_OFFSET = X
 */
bytes1 constant OP_1_OFFSET = 0x50;
bytes1 constant OP_1 = 0x51;
bytes1 constant OP_2 = 0x52;
bytes1 constant OP_16 = 0x60;
bytes1 constant OP_RETURN = 0x6a;
bytes1 constant OP_DUB = 0x76;
bytes1 constant OP_EQUAL = 0x87;
bytes1 constant OP_EQUALVERIFY = 0x88;
bytes1 constant OP_HASH160 = 0xa9;
bytes1 constant OP_CHECKSIG = 0xac;

// Script lengths
uint8 constant P2SH_SCRIPT_LENGTH = 23;
uint8 constant P2PKH_SCRIPT_LENGTH = 25;

// Address indexes
uint8 constant P2SH_ADDRESS_START = 2;
uint8 constant P2SH_ADDRESS_END = 22;

uint8 constant P2PKH_ADDRESS_START = 3;
uint8 constant P2PKH_ADDRESS_END = 23;
