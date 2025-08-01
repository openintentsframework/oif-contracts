// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { MailboxClient } from "../../../src/oracles/hyperlane/external/hyperlane/MailboxClient.sol";
import { IInterchainSecurityModule } from
    "../../../src/oracles/hyperlane/external/hyperlane/interfaces/IInterchainSecurityModule.sol";
import { IMailbox } from "../../../src/oracles/hyperlane/external/hyperlane/interfaces/IMailbox.sol";
import { IPostDispatchHook } from
    "../../../src/oracles/hyperlane/external/hyperlane/interfaces/hooks/IPostDispatchHook.sol";

contract HyperlaneMailboxClient is MailboxClient {
    uint256 public counter;

    constructor(address mailbox, address customHook, address ism) MailboxClient(mailbox, customHook, ism) { }

    function somethingOnlyMailbox() external onlyMailbox {
        counter++;
    }
}

contract MailboxMock {
    function localDomain() external pure returns (uint32) {
        return uint32(1);
    }
}

contract MailboxClientTest is Test {
    MailboxMock internal _mailbox;
    HyperlaneMailboxClient internal _mailboxClient;

    address internal _kakaroto = makeAddr("kakaroto");
    address internal _karpincho = makeAddr("karpincho");

    function setUp() public {
        _mailbox = new MailboxMock();
        _mailboxClient = new HyperlaneMailboxClient(address(_mailbox), _kakaroto, _karpincho);
    }

    function test_constructor_InvalidMailbox() external {
        vm.expectRevert(abi.encodeWithSignature("InvalidMailbox()"));
        new HyperlaneMailboxClient(address(0), _kakaroto, _karpincho);
    }

    function test_constructor_works() external view {
        vm.assertEq(address(_mailboxClient.MAILBOX()), address(_mailbox));
        vm.assertEq(address(_mailboxClient.hook()), _kakaroto);
        vm.assertEq(address(_mailboxClient.interchainSecurityModule()), _karpincho);
        vm.assertEq(_mailboxClient.localDomain(), _mailbox.localDomain());
    }

    function test_onlyMailbox_SenderNotMailbox() external {
        vm.expectRevert(abi.encodeWithSignature("SenderNotMailbox()"));
        _mailboxClient.somethingOnlyMailbox();
    }

    function test_onlyMailbox_works() external {
        uint256 counterBefore = _mailboxClient.counter();

        vm.prank(address(_mailbox));
        _mailboxClient.somethingOnlyMailbox();

        vm.assertEq(_mailboxClient.counter(), counterBefore + 1);
    }
}
