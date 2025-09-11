// SPDX-License-Identifier: Apache-2.0
/*
 * Copyright 2024, Polymer Labs
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

pragma solidity ^0.8.15;

import {BitMaps} from "openzeppelin/utils/structs/BitMaps.sol";
import {IRegistry} from "../../../interfaces/IRegistry.sol";
import {L2Configuration, L1Configuration, Type} from "../../../libs/RegistryTypes.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";
import {Pausable} from "openzeppelin/security/Pausable.sol";
import {AccessControl} from "openzeppelin/access/AccessControl.sol";

/**
 * @title Registry
 * @dev Manages L1 and L2 chain configurations with role-based access control.
 * @notice This contract allows authorized entities to update chain configurations for L1 and L2.
 * @notice L2s which rollup to the L1 where this contract is deployed can permissionlessly prove state in this registry
 * using l1 block info through the NativeProver contract.
 */
contract Registry is IRegistry, Ownable, Pausable, AccessControl {
    struct InitialL2Configuration {
        uint256 chainID;
        L2Configuration config;
    }

    struct InitialL1Configuration {
        uint256 chainID;
        L1Configuration config;
    }

    mapping(uint256 => bytes32) public l2ChainConfigurationHashMap;

    mapping(uint256 => L2Configuration) public l2ChainConfigurations;

    mapping(uint256 => bytes32) public l1ChainConfigurationHashMap;

    mapping(uint256 => L1Configuration) public l1ChainConfigurations;

    // Bitmap from keccak256("CHAIN_ROLE_PREFIX" + owner + bool(true)) to track hashes which are irrevocable
    BitMaps.BitMap internal _irrevocableChainIDBitmap;

    bytes32 private constant _CHAIN_ROLE_PREFIX = keccak256("CHAIN_ROLE");

    event L2ChainConfigurationUpdated(uint256 indexed chainID, bytes32 indexed configHash);

    event L1ChainConfigurationUpdated(uint256 indexed chainID, bytes32 indexed configHash);

    error InvalidRange(uint256 startChainID, uint256 stopChainID);

    /**
     * @dev Modifier to ensure a chain ID is not irrevocable
     * @param _chainID The chain ID to check
     */
    modifier isRevocable(uint256 _chainID) {
        require(
            BitMaps.get(_irrevocableChainIDBitmap, uint256(_getChainRole(_chainID, true))) == false,
            "ChainID is irrevocable"
        );

        _;
    }

    /**
     * @dev Modifier to ensure the caller is a grantee for a specific chain ID
     * @param _chainID The chain ID to check
     * @notice This modifier checks if the caller is a grantee or an irrevocable grantee for the specified chain ID.
     * If the caller is not authorized, it reverts with "Not authorized".
     */
    modifier canConfigChain(uint256 _chainID) {
        require(
            _isGrantee(msg.sender, _chainID) || _isIrrevocableGrantee(msg.sender, _chainID), "Registry: Not authorized"
        );
        _;
    }

    /**
     * @dev Constructor to initialize the Registry contract.
     * @param _initialOwner The address that will be granted ownership
     * @param _initialL2Configurations Array of initial L2 chain configurations
     * @param _initialL1Configurations Array of initial L1 chain configurations
     */
    constructor(
        address _initialOwner,
        InitialL2Configuration[] memory _initialL2Configurations,
        InitialL1Configuration[] memory _initialL1Configurations
    ) {
        if (_initialOwner == address(0)) {
            revert("Ownable: new owner is the zero address");
        }
        _transferOwnership(_initialOwner);

        // Grant the default admin role to the owner
        _setupRole(DEFAULT_ADMIN_ROLE, _initialOwner);

        // Initialize configurations
        for (uint256 i = 0; i < _initialL2Configurations.length; ++i) {
            _setL2ChainConfiguration(_initialL2Configurations[i].chainID, _initialL2Configurations[i].config);
        }
        for (uint256 i = 0; i < _initialL1Configurations.length; ++i) {
            _setL1ChainConfiguration(_initialL1Configurations[i].chainID, _initialL1Configurations[i].config);
        }
    }

    /**
     * @notice Updates the L1 chain configuration for a specific chain ID
     * @dev Only authorized grantees for the chain ID can call this function
     * @param _chainID The chain ID to update the configuration for
     * @param _config The new L1 configuration to set
     */
    function updateL1ChainConfiguration(uint256 _chainID, L1Configuration calldata _config)
        external
        canConfigChain(_chainID)
    {
        _setL1ChainConfiguration(_chainID, _config);
    }

    /**
     * @notice Updates the L2 chain configuration for a specific chain ID
     * @dev Only authorized grantees for the chain ID can call this function
     * @param _chainID The chain ID to update the configuration for
     * @param _config The new L2 configuration to set
     */
    function updateL2ChainConfiguration(uint256 _chainID, L2Configuration calldata _config)
        external
        canConfigChain(_chainID)
    {
        _setL2ChainConfiguration(_chainID, _config);
    }

    /**
     * @notice Grants a grantee permission to manage a specific chain ID
     * @dev Can only be called by the contract owner, and only for revocable chain IDs
     * @param _grantee The address to grant permissions to
     * @param _chainID The chain ID to grant permissions for
     */
    function grantChainID(address _grantee, uint256 _chainID) external onlyOwner isRevocable(_chainID) {
        return _grantChainID(_grantee, _chainID);
    }

    /**
     * @notice Grants a grantee irrevocable permission to manage a specific chain ID
     * @dev Can only be called by the contract owner, and only for currently revocable chain IDs
     * @param _grantee The address to grant permissions to
     * @param _chainID The chain ID to grant irrevocable permissions for
     */
    function grantChainIDIrrevocable(address _grantee, uint256 _chainID) external onlyOwner isRevocable(_chainID) {
        return _grantChainIDIrrevocable(_grantee, _chainID);
    }

    /**
     * @notice Revokes _grantee's revocable role for chainID
     * @dev Can only be called by the contract owner, and can only remove revocable roles
     * @param _grantee The address to revoke permissions from
     * @param _chainID The chain ID to revoke permissions for
     */
    function revokeChainID(address _grantee, uint256 _chainID) external onlyOwner {
        // Revoke the revocable role for the grantee
        _revokeRole(_getChainRole(_chainID, false), _grantee);
    }

    /**
     * @notice Grants a grantee permission to manage a range of chain IDs
     * @dev Can only be called by the contract owner
     * @param _grantee The address to grant permissions to
     * @param _startChainID The starting chain ID of the range (inclusive)
     * @param _stopChainID The ending chain ID of the range (inclusive)
     */
    function grantChainIDRange(address _grantee, uint256 _startChainID, uint256 _stopChainID) external onlyOwner {
        if (_startChainID > _stopChainID) {
            revert InvalidRange(_startChainID, _stopChainID);
        }
        for (uint256 i = _startChainID; i <= _stopChainID; i++) {
            _grantChainID(_grantee, i);
        }
    }

    /**
     * @notice Grants a grantee irrevocable permission to manage a range of chain IDs
     * @dev Can only be called by the contract owner
     * @param _grantee The address to grant irrevocable permissions to
     * @param _startChainID The starting chain ID of the range (inclusive)
     * @param _stopChainID The ending chain ID of the range (inclusive)
     */
    function grantChainIDRangeIrrevocable(address _grantee, uint256 _startChainID, uint256 _stopChainID)
        external
        onlyOwner
    {
        if (_startChainID > _stopChainID) {
            revert InvalidRange(_startChainID, _stopChainID);
        }
        for (uint256 i = _startChainID; i <= _stopChainID; i++) {
            _grantChainIDIrrevocable(_grantee, i);
        }
    }

    /**
     * @notice Gets the addresses from an L2 chain configuration
     * @param _chainID The chain ID to get configuration for
     * @return address[] Array of addresses from the L2 configuration
     */
    function getL2ConfigAddresses(uint256 _chainID) external view returns (address[] memory) {
        return l2ChainConfigurations[_chainID].addresses;
    }

    /**
     * @notice Gets the storage slots from an L2 chain configuration
     * @param _chainID The chain ID to get configuration for
     * @return uint256[] Array of storage slots from the L2 configuration
     */
    function getL2ConfigStorageSlots(uint256 _chainID) external view returns (uint256[] memory) {
        return l2ChainConfigurations[_chainID].storageSlots;
    }

    /**
     * @notice Gets the L2 type from an L2 chain configuration
     * @param _chainID The chain ID to get configuration for
     * @return Type The L2 type from the configuration
     */
    function getL2ConfigType(uint256 _chainID) external view returns (Type) {
        return l2ChainConfigurations[_chainID].l2Type;
    }

    /**
     * @notice Gets the block hash oracle address from an L1 chain configuration
     * @param _chainID The chain ID to get configuration for
     * @return address The block hash oracle address from the L1 configuration
     */
    function getL1BlockHashOracle(uint256 _chainID) external view returns (address) {
        return l1ChainConfigurations[_chainID].blockHashOracle;
    }

    /**
     * @notice Checks if an address is a grantee for a specific chain ID
     * @param _grantee The address to check
     * @param _chainID The chain ID to check for
     * @return bool True if the address is a grantee for the chain ID, false otherwise
     */
    function isRevocableGrantee(address _grantee, uint256 _chainID) external view returns (bool) {
        return _isGrantee(_grantee, _chainID);
    }

    /**
     * @notice Checks if an address is an irrevocable grantee for a specific chain ID
     * @param _grantee The address to check
     * @param _chainID The chain ID to check for
     * @return bool True if the address is an irrevocable grantee for the chain ID, false otherwise
     */
    function isIrrevocableGrantee(address _grantee, uint256 _chainID) external view returns (bool) {
        return _isIrrevocableGrantee(_grantee, _chainID);
    }

    /**
     * @dev Empty implementation to override OZ's access control method to ensure that admins can't revoke roles.
     */
    function revokeRole(bytes32 role, address account) public override {
        revert("Registry: Cannot revoke roles directly");
    }

    /**
     * @dev Empty implementation to override OZ's access control method to ensure that admins can't add more than a
     * single irrevocable grantee per chain ID.
     */
    function grantRole(bytes32 role, address account) public virtual override {
        revert("Registry: Cannot grant roles directly");
    }

    /**
     * @dev Internal function to set an L1 chain configuration
     * @param _chainID The chain ID to set configuration for
     * @param _config The L1 configuration to set
     */
    function _setL1ChainConfiguration(uint256 _chainID, L1Configuration memory _config) internal {
        bytes32 _hash = keccak256(abi.encode(_config));
        l1ChainConfigurationHashMap[_chainID] = _hash;
        l1ChainConfigurations[_chainID] = _config;
        emit L1ChainConfigurationUpdated(_chainID, _hash);
    }

    /**
     * @dev Internal function to set an L2 chain configuration
     * @param _chainID The chain ID to set configuration for
     * @param _config The L2 configuration to set
     */
    function _setL2ChainConfiguration(uint256 _chainID, L2Configuration memory _config) internal {
        bytes32 _hash = keccak256(abi.encode(_config));
        l2ChainConfigurationHashMap[_chainID] = _hash;
        l2ChainConfigurations[_chainID] = _config;
        emit L2ChainConfigurationUpdated(_chainID, _hash);
    }

    /**
     * @dev Internal function to grant a grantee permission to manage a specific chain ID
     * @param _grantee The address to grant permissions to
     * @param _chainID The chain ID to grant permissions for
     */
    function _grantChainID(address _grantee, uint256 _chainID) internal isRevocable(_chainID) {
        _grantRole(_getChainRole(_chainID, false), _grantee);
    }

    /**
     * @dev Internal function to grant a grantee irrevocable permission to manage a specific chain ID
     * @param _grantee The address to grant irrevocable permissions to
     * @param _chainID The chain ID to grant irrevocable permissions for
     */
    function _grantChainIDIrrevocable(address _grantee, uint256 _chainID) internal isRevocable(_chainID) {
        bytes32 role = _getChainRole(_chainID, true);
        BitMaps.set(_irrevocableChainIDBitmap, uint256(role));
        _grantRole(role, _grantee);
    }

    /**
     * @dev Internal function to check if an address is a grantee for a specific chain ID
     * @param _grantee The address to check
     * @param _chainID The chain ID to check for
     * @return bool True if the address is a grantee for the chain ID, false otherwise
     */
    function _isGrantee(address _grantee, uint256 _chainID) internal view returns (bool) {
        return hasRole(_getChainRole(_chainID, false), _grantee);
    }

    /**
     * @dev Internal function to check if an address is a grantee for a specific chain ID
     * @param _grantee The address to check
     * @param _chainID The chain ID to check for
     * @return bool True if the address is a grantee for the chain ID, false otherwise
     */
    function _isIrrevocableGrantee(address _grantee, uint256 _chainID) internal view returns (bool) {
        return hasRole(_getChainRole(_chainID, true), _grantee);
    }

    /**
     * @dev Get chain-specific role identifier based on chain ID
     * @param _chainID The chain ID to get the role for
     * @param irrevocable The chain ID to get the role for
     * @return bytes32 The role identifier for the chain ID
     */
    function _getChainRole(uint256 _chainID, bool irrevocable) internal pure returns (bytes32) {
        return keccak256(abi.encode(_CHAIN_ROLE_PREFIX, _chainID, irrevocable));
    }
}
