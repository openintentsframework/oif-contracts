// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC3009 } from "../../src/interfaces/IERC3009.sol";

import { ERC20 } from "solady/tokens/ERC20.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { SignatureCheckerLib } from "solady/utils/SignatureCheckerLib.sol";

import { console } from "forge-std/console.sol";

contract MockERC20 is ERC20, IERC3009, EIP712 {
    string internal _name;
    string internal _symbol;
    uint8 internal _decimals;
    bytes32 internal immutable _nameHash;

    function _domainNameAndVersion()
        internal
        view
        virtual
        override
        returns (string memory __name, string memory version)
    {
        __name = name();
        version = "1";
    }

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
        _nameHash = keccak256(bytes(name_));
    }

    function _domainNameAndVersionMayChange() internal pure override returns (bool result) {
        return true;
    }

    function _constantNameHash() internal view virtual override returns (bytes32) {
        return _nameHash;
    }

    function name() public view virtual override returns (string memory) {
        return _name;
    }

    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 value) public virtual {
        _mint(to, value);
    }

    function burn(address from, uint256 value) public virtual {
        _burn(from, value);
    }

    function directTransfer(address from, address to, uint256 amount) public virtual {
        _transfer(from, to, amount);
    }

    function directSpendAllowance(address owner, address spender, uint256 amount) public virtual {
        _spendAllowance(owner, spender, amount);
    }

    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        return super.transferFrom(from, to, amount);
    }

    // --- 3009 --- //

    // keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256
    // validBefore,bytes32 nonce)")
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH =
        0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267;

    // keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256
    // validBefore,bytes32 nonce)")
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;

    mapping(address => mapping(bytes32 => bool)) internal _authorizationStates;

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    string internal constant _INVALID_SIGNATURE_ERROR = "EIP3009: invalid signature";

    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool) {
        return _authorizationStates[authorizer][nonce];
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external override {
        require(block.timestamp > validAfter, "EIP3009: authorization is not yet valid");
        require(block.timestamp < validBefore, "EIP3009: authorization is expired");
        require(!_authorizationStates[from][nonce], "EIP3009: authorization is used");
        require(msg.sender == to, "EIP3009: receive has to be called by to");

        bytes32 data =
            keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce));
        bytes32 digest = _hashTypedData(data);
        bool isValid = SignatureCheckerLib.isValidSignatureNowCalldata(from, digest, signature);
        require(isValid, "Signature invalid");

        _authorizationStates[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);

        _transfer(from, to, value);
    }
}
