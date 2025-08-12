/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IInterchainSecurityModule } from "./interfaces/IInterchainSecurityModule.sol";
import { IMailbox } from "./interfaces/IMailbox.sol";
import { IPostDispatchHook } from "./interfaces/hooks/IPostDispatchHook.sol";

/**
 * @notice This smart contract is a simplified version of the
 * [Hyperlane's MailboxClient]
 * (https://github.com/hyperlane-xyz/hyperlane-monorepo/blob/main/solidity/contracts/client/MailboxClient.sol)
 * to make it non-upgradable and ownerless.
 *
 */
abstract contract MailboxClient {
    error InvalidMailbox();
    error SenderNotMailbox();

    IMailbox public immutable MAILBOX;

    uint32 internal immutable _LOCAL_DOMAIN;

    IPostDispatchHook internal immutable _HOOK;

    IInterchainSecurityModule internal immutable _ISM;

    // ============ Modifiers ============
    /**
     * @notice Only accept messages from a Hyperlane Mailbox contract
     */
    modifier onlyMailbox() {
        if (msg.sender != address(MAILBOX)) revert SenderNotMailbox();
        _;
    }

    constructor(address mailbox, address customHook, address ism) {
        if (mailbox == address(0)) revert InvalidMailbox();

        MAILBOX = IMailbox(mailbox);
        _LOCAL_DOMAIN = MAILBOX.localDomain();
        _HOOK = IPostDispatchHook(customHook);
        _ISM = IInterchainSecurityModule(ism);
    }

    function interchainSecurityModule() public view returns (IInterchainSecurityModule) {
        return _ISM;
    }

    function hook() public view returns (IPostDispatchHook) {
        return _HOOK;
    }

    function localDomain() public view returns (uint32) {
        return _LOCAL_DOMAIN;
    }
}
