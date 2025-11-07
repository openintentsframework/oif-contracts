// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { MandateOutput } from "../../../src/input/types/MandateOutputType.sol";
import { BroadcasterOracle } from "../../../src/integrations/oracles/broadcaster/BroadcasterOracle.sol";
import { LibAddress } from "../../../src/libs/LibAddress.sol";
import { MandateOutputEncodingLib } from "../../../src/libs/MandateOutputEncodingLib.sol";
import { MessageEncodingLib } from "../../../src/libs/MessageEncodingLib.sol";
import { OutputSettlerSimple } from "../../../src/output/simple/OutputSettlerSimple.sol";
import { MockERC20 } from "../../../test/mocks/MockERC20.sol";
import { BlockHeaders } from "broadcaster-test/utils/BlockHeaders.sol";
import { BlockHashProverPointer } from "broadcaster/BlockHashProverPointer.sol";
import { Broadcaster } from "broadcaster/Broadcaster.sol";
import { Receiver } from "broadcaster/Receiver.sol";
import { IReceiver } from "broadcaster/interfaces/IReceiver.sol";
import { ChildToParentProver as ArbChildToParentProver } from "broadcaster/provers/arbitrum/ChildToParentProver.sol";
import { Test, console } from "forge-std/Test.sol";
import { RLP } from "openzeppelin/utils/RLP.sol";

interface IBuffer {
    error UnknownParentChainBlockHash(uint256 parentChainBlockNumber);

    function receiveHashes(
        uint256 firstBlockNumber,
        bytes32[] memory blockHashes
    ) external;

    function parentChainBlockHash(
        uint256 parentChainBlockNumber
    ) external view returns (bytes32);
}

contract MockBuffer is IBuffer {
    mapping(uint256 => bytes32) public parentChainBlockHashes;

    function receiveHashes(
        uint256 firstBlockNumber,
        bytes32[] memory blockHashes
    ) external {
        // Implementation
        for (uint256 i = 0; i < blockHashes.length; i++) {
            parentChainBlockHashes[firstBlockNumber + i] = blockHashes[i];
        }
    }

    function parentChainBlockHash(
        uint256 parentChainBlockNumber
    ) external view returns (bytes32) {
        // Implementation

        if (parentChainBlockHashes[parentChainBlockNumber] == bytes32(0)) {
            revert UnknownParentChainBlockHash(parentChainBlockNumber);
        }

        return parentChainBlockHashes[parentChainBlockNumber];
    }
}

contract BroadcasterOracleTest is Test {
    using LibAddress for address;

    BroadcasterOracle public broadcasterOracle;

    uint256 public ethereumForkId;
    uint256 public arbitrumForkId;

    uint256 parentChainId;
    uint256 childChainId;

    address owner = makeAddr("owner");

    IBuffer public buffer;

    function setUp() public {
        address bufferAddress = 0x0000000048C4Ed10cF14A02B9E0AbDDA5227b071;
        deployCodeTo("MockBuffer", bufferAddress);

        buffer = IBuffer(bufferAddress);
    }

    function encodeMessageCalldata(
        bytes32 identifier,
        bytes[] calldata payloads
    ) external pure returns (bytes memory) {
        return MessageEncodingLib.encodeMessage(identifier, payloads);
    }

    function _getInputForVerifyMessage()
        internal
        returns (bytes memory input, uint256 expectedSlot, bytes32 blockHash, address knownAccount)
    {
        bytes32 message = 0xbd64b342ddb178f28ccbff1f868eaab0fce1beee88c46c4f732462e2b72ca440; //
        address publisher = 0x11e14F08Bd326521A3C1f59eE4Be0EB64C04908D; // broadcaster oracle

        expectedSlot = uint256(keccak256(abi.encode(message, publisher)));

        bytes[] memory accountProofList = new bytes[](8);

        accountProofList[0] = RLP.encode(
            hex"f90211a09251229b5814fb7e35219aa2a0ef077bd0c4fa8664b63d08c977ee53f1f488e8a0134ff3a3971b84e351515b29c7daedda34bb858a873c3e2393c2f6e461ca86dca0d759123dad9c5a050f14b4346b0ec400261aba01ee7d43b06a43e88b518805cda0bbd81d0f71907bf6675ab38831638ebd012dc786b03b829bdc4831f189aa4437a01fa56836a66f54fc76e27c61f002175c3a9a3ff0cf6f5bbd3c3a9845e49dc329a04a6d7cb6a1257c0464c04b97d3df47c26ebff987bd0e1c3a7ebf7f2482b0ddeca0b9100a6215ab3549837dbcef3a7ee1110bd4bc1394d437fb64fa02ee85c5e7bca041f5881568382b9204c12b5ba5139f82e7d8bfe583a3a19bb42a416893b1c36ba07ea571c0fd2326b45af5a277c0753ee2843b1141f486d69ce48e336daa0cc00fa02bc66ca32feb7b2ee92120ec7daf85f7f5d0b88e31db355f9dea66f4db407f53a0507ec3f3c79dbf7f47ff0e6791a6b49cbee7b2ad172e4ae5afae8c1f7ff702e2a0a70bdcd57b76182a46945b11555d4ae9da66f76028161e09bfa968a39ecb6b54a033d9394bcd6ad34bd21836e4e96e3b9156e8a5c01770b39c7c15f017a8a3ec20a08724a45c82e2c36b43b8e29e04d134e8ac28fcc42587ffc13724baac5d93c10da0a47df826ffdc93162ba492b5895c7eb438fda3c1a54e52548431b5413fbbe818a08ad58a5fc90340a1fdcf6dd36f0a224329c8d15d8c384e16e67228dd98aabbec80"
        );
        accountProofList[1] = RLP.encode(
            hex"f90211a0f4f822a07a34dd6dc04e5486e8955dcb19d01166265f98d98cc08915521a4f20a02c70c0b9d2df3a07c68d95dcf74cebd5b4a5a49710be779d455ccc943945c709a05a11a035b94610478c9cd1c637efb34dadc07c35e9dd2a6f554f3599bfef844aa02abc489e6f36dbc9eb164706e7c850e8813460fe2e54a2db3c6c64feea981d98a00dd139195357afcf1d4c69b4e087b9c7aaf9c2855ac74426b5184b8cdf7a07b6a0e9165302e3336e2c3dd3bfa2a7b704fe7800ebe830befa8a2ca61b7c9c30d0a9a02105ebfe63ef563071e4d7bf46809817f205a920465803231517f093dfc725e7a0a557be5578ef23170f1932fcb60bf5ce51f60405f1e167b24c05e97d7b4040fba0f7bc1a097362ca54fe7d9da15d73f2489ac9c4e36b65ac39bebadf72c3b8ed58a00b99fa07926fe9d81511c0d7e993d24fbbf68745e56480e428ea0e74ddd1656da034d9438300afbf0c3ae873ca6936cd75214a869d1715da19420253194b554d50a03d3c1946b6cc85f017960210fac7eb53f1a8237184db2358223f8161d98e563ca0e91f2ece690ef09baa0f216a7e52a66321af50763fcf1be8b32f4cff58c19392a06ddbb01b623e7efdc24f418ebac750f87517b9454b5a539338caf8fbcdd624caa0f77ea50102db52ae2e50248fb54397233b3906cda069ba4b9ee20a49f2b5c606a0b1765776b1f196c4100d77d009db83a3d4c3e318b2d0e559162484f22290725280"
        );
        accountProofList[2] = RLP.encode(
            hex"f90211a0e64b02b2f34e10443fa101ff1624ead4a06125120908dfc897721c3062edbb99a07455238829775dc3c170f24867f0fad9f0f6237173d7a38995b74b3f15d4b036a0008212a1bb0622cc5aa2534ee4ec8d94736ca6f8eb116ecadc143ca180077a46a07039446aa111bed152ae59dffdd89891ca5b3b1d608acecd44ecad9afe2e5fa7a019af06a36a5b34aa524eb6e7b9b3681852699ba7631f41fdccf08ba82bfe23b7a0006091d032340dd2b475665018e87b4b3e762bfbd9beb93cf661949c80aa8490a053609c1520683f788f9e7a4a2940e9a4b8510eb2b4d8a220f29db903cd975c37a0c553d7d92688bd27a4bd48cf3f2d2b9dbf3466e8f93723a79a192e6ef9b2c727a0e8478fae626fa37b46819680aa2e9d51988c30c3767c1246954d48e368469b23a00b6ae6d384dfe0f7ecafed40dc8439f71a5742fc6f8ca2e81b2b1666dd9fab9ba03fc2a7a408b6ee490176db42fb9285120297ab83d258657a0e003daf582ec12fa056a7e37eb0adcb5919889120222614671c16d92f1463e33747c6742a27c43aaea05f31e18ed5553b3fe2520c0706a4091b21ced874f08f8e9d9c5276960a602e13a0bce978f9cd80a9228508e03baa45a6d4939a29381142c906ddae01d0500d8b48a02a2b10f1e6a1bd18a006cb1f0c825c7d8af9cb6dccd309c54e419fc8101459c2a09c9076143c41ccc2e692d77886c6d071a6c6ea690014bea63ed826e7dd14bf7880"
        );
        accountProofList[3] = RLP.encode(
            hex"f90211a0623a8514a3d9711385d82f64f2b55e0ea591d6ea71577ddcdd2a4040d01a4f14a004436272ee04afeaccfe9c3377293d58be2423c2505bad6d8790dfa6fa91b19ea01bf11b07201376f6a7ea27e6602da7cc440c738373277aeb0a548e8610657581a01aea569d80300bc9e7e2da1e5c9703fde5cb2651fc1f313a2f3aa5a9c06c7485a0dc9be134470cebd665939c20d7fdf3b527432dcd96a246c5b9d1365259427fc9a00b4c25adba3bcb2326556cdab5f2b3c2a82f14eee85e67a7fcf6cca0efd40b94a0aa5906e73cc1370b7228b0ddab4fea9653514eb59cb6bdf12ab8a3382d08ad77a015b5473174e5db0e8158f051928c155060947f737b08ae006af2d5b6ed1b6319a016503e66b0b417bc130207b84b29b2b1a2471047b2d26b97d8318087d8b28a90a099ac34ac9cb3a974f7ae49585bf0ccf241a95f1f72d10a5c1fbed950659f6f00a0dab1d00bed366a64cd99a725fc8c7b36eb55ee8ff95209838208c1398d9b8f5ea0d5a83ee818c045ec079d81289c8145254bdefe62ae12bd5e71b0ac203438d85ca02e8c44786b50c85d418502f02f08bf8fc27cc34a5590fe937496e3159827d915a0992a71b491277b0c93609c417432aa675691478bd9eb29fb394520aa1cb4a289a0e45241b73f4d329f4fe909401f9aa76b7e46162e6fc3dd81be819d1c06acff51a0212236e6fc481e5d8440f49fa5fcf32fdd9ca67d166b0729fc1fc77d71431acb80"
        );
        accountProofList[4] = RLP.encode(
            hex"f90211a0e54f82daf54b26973f584016ca833654dee0a659464428fe1ce53097380bc2d0a097a696b4cd659cb0fe2f87d9a5f8fee87a032ff6ac95489fb985103bf232aca5a001b9af9e74ac1132eb2f9c20ac950178ea066a1bf67898b2bfa908b374881015a0592e35261c24a24435af64b11a177cbc346f4a0c91d4eb9b229ac373e8a9e5eea0a6d5d2e84b5e6a32f5aeaddb2635e7c78de78c8a45c2a609e628364ac88fd1e4a0a1ce8455d7a9a560bef917b5bab4be927586f070ba515c75a1b58d86883679a7a03b1e2c4c3adb9611b891605f206f6feba27c1e8f0dc971785d871f8aa5a6c71ca04a12c19d53b609908211a5dd890adf67bbfc981348e4f465781d59a983cd87bea0b6d9868a2d57dc6f9bbbf47ccc6f5f427db830c1276ee7efac4fa904f38ffb06a088bed8ddd0b03ad9d519643589e106daf8b0a6ee7510efb3ffc436b6d08c385aa0cfa4a71af2c4ee6856b64199be680df4f04987d28dc707b9b81b1ae2135342aca007f48265cb2cb83f63518a4f813f344836cc4ccf969eff0a0d8bf98bf4570d90a0f189aeb9c6a9c5517d6940b57a5bf3c61fa9a589a35bab963a15176731d3ab76a00e51492b77450e0544151e6b16c9a24e6b1d316a5cc992bd0f52bb846dae23bfa07dbb93677320d84faf7b1dabb859d063f30bdffab9ff585b41b2e469743cd45ca02ca0c5810e279a986c31d251c1d3413cb505a03bc85c172bdce8a6b35e276dfb80"
        );
        accountProofList[5] = RLP.encode(
            hex"f90211a02614da908a4849f529b99e68ca69202ced4848b3bf6d1588d107535056e63eeca00477bfd2aecc7a0914f087efee823ae72a6b723d960a55e6c0c931917410b91ba000b6602e9ad6a574bda8edd73f36dc19bf59e8f07cbef550c6e62ad8d7837275a080181a744c9ce8bfb3ac8ea4f5fde39c5dd5123d768cd672ad8724e70d7d263fa06f4f223a69c0872022884fb78088456e2871fabb67946a5c3aa1c2fc97067f53a0789e4ffbb34e200bb32122488867a04c6af28be25d7ce3627219eeb27da1d1e6a083bcf68bd3418e85c3ffe8721a9e98aa51eb1f8eb96e0b8c8c94084636e8b9fda01d55714ed9e4b5394924f8e7514374cfe5757a4e512a66bc6b61ed6bd99ae3d4a0328667d4b3060ad405ba75b0e956259fb475c1a150d01928f1b68b477fd24f37a059b843bad4688ecb2ddee56c13a7c990ed84efe655eb0fee8d06cbd4f52886fba017e2ac27459cbf0133cc9f9c2623e029c71137764368f57e2de62070011b74dda0d77d24119a2950d6b4f90eebbd4d5342f592f3c8f9980debed42ebd0004d5ecda0c64c80f579948559cd119490389c1370348b031a1ab72ec84ae18a783dfd49aea04fcff07c044cbc30b26ca0fc41d2ec474506fab38bbbbb582519f09543e2ea13a0ffbb5ce620fc8e2b39ee70b18dab1fd31dabf7a1361232db072b5534d6c45ea3a047aec790619add4898883dd60be479887cd8bb312ffb92c7f253c5162a9d33a180"
        );
        accountProofList[6] = RLP.encode(
            hex"f8b1a0c7491b416a7a20bfc78fe1f7a4518958524b539c331c25ebb60cb7d651e94c4b8080808080808080a0cc7ab3e5e7e4f8e25483bf7124cd51ea3e4aee5bf8abbce28499b9c95913fe4d8080a082a3f66f1fdba2188333439a63fea1632b0a504d1735fe45dcdbc750c980d74aa0e76eeb8f7a7ff529ca36d01f44bffa3e85b363a8d6a2b2c9d25c2114dac70689a043b641bafe98b738fff861b3875f87245830c1d29a7c0d411d1da3958fa0f3e18080"
        );
        accountProofList[7] = RLP.encode(
            hex"f8669d35ea91a4f74675160ac2ae6e03f04be23fbf7e800eb88db12c6f5904c0b846f8440180a08a4519ee79b29767fdb24ade5193f2c4cc00d62f11bdbb59347c614756a2eac5a03debe8ce6033a7570465c1bd57dfe3c0ca9dba458721039d4d47c10d5025252b"
        );

        bytes memory accountProof = RLP.encode(accountProofList);

        bytes[] memory storageProofList = new bytes[](2);

        storageProofList[0] = RLP.encode(
            hex"f85180808080808080a0f6c85214110cface7a349ddfdae2248f0170a5e14c4b96f905aee1d7086b9747808080808080a0abb3480cb2d0359a6684ae69b72bb6fe2e6c2681609d78ad24ee18e0863ac7548080"
        );
        storageProofList[1] =
            RLP.encode(hex"e7a0316836aeeaed064a6f60af78a37fa358935ed600b194a8a3246c3d0a005c8d90858468ff80bc");

        bytes memory storageProof = RLP.encode(storageProofList);

        bytes memory rlpBlockHeader = _getRlpBlockHeader();

        knownAccount = 0xAb23DF3fd78F45E54466d08926c3A886211aC5A1; // broadcaster

        input = abi.encode(rlpBlockHeader, knownAccount, expectedSlot, accountProof, storageProof);
        return (input, expectedSlot, keccak256(rlpBlockHeader), knownAccount);
    }

    function _getRlpBlockHeader() internal returns (bytes memory rlpBlockHeader) {
        BlockHeaders.L1BlockHeader memory blockHeader = BlockHeaders.L1BlockHeader({
            parentHash: 0x9c58771b8262377a4b04efd4c0cd54965b6992634876a9ff0637bdfe181a4710,
            sha3Uncles: 0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347,
            miner: 0x9B984D5a03980D8dc0a24506c968465424c81DbE,
            stateRoot: 0x4792648a12709dc56b5fc0a76323010f635e36725c8fd826ed1aba20f4d8c83e,
            transactionsRoot: 0xdd4342405ac034d7bb6d816fe6de873e6395a6f0382245628a4075269925eb4d,
            receiptsRoot: 0x5a10e07a28173a44a5065a63f98b8c4bb18b376d1917c93038ce2cf8c0d8ad00,
            logsBloom: hex"04210636030004042881800114a00000801000050102010001802041498a840024100064a009282092000104002102022005850066024080c0412890202c260200000802080009000004808a50308280004301000144002008006080a40001010614c01822a0208820420420c100084402000000202014000000801098042544014a0008025000082004124002a200440a8006871029000c800102045400cc01221820431084080100011700004020400040000116088000845420241010080140920006800014001a00500000401082211040010020080110029806000064025050190820803922814012016180008260030204088020c49480000600804000",
            difficulty: 0,
            number: 9502200,
            gasLimit: 60000000,
            gasUsed: 9457470,
            timestamp: 1761576408,
            extraData: hex"d883011005846765746888676f312e32342e39856c696e7578",
            mixHash: 0x025741f9f4c8a56a85c7701682cc3426ccbd5b7569dad72245c89a2a95d1092b,
            nonce: 0x0000000000000000,
            baseFeePerGas: 15,
            withdrawalsRoot: 0x37874325f10cec3a03b0bd8477c54409f7bd48ba1c4d24633b4fc177bd2ac60b,
            blobGasUsed: 1048576,
            excessBlobGas: 0,
            parentBeaconBlockRoot: 0x3ac5df027e9de81ebd1a8d76808ec01877d871a5932fb3c1f292d5bf7d00899c,
            requestsHash: 0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        });

        rlpBlockHeader = BlockHeaders.encode(blockHeader);

        return rlpBlockHeader;
    }

    function _getPayloadForVerifyMessage()
        internal
        returns (bytes memory payload, address broadcasterOracleSubmitter, address outputSettler)
    {
        broadcasterOracleSubmitter = 0x11e14F08Bd326521A3C1f59eE4Be0EB64C04908D;
        outputSettler = 0x674Cd8B4Bec9b6e9767FAa8d897Fd6De0729dd66;
        MockERC20 token = MockERC20(0x287E1E51Dad0736Dc5de7dEaC0751C21b3d88d6e);

        uint256 amount = 0.01 ether;
        address filler = 0x9a56fFd72F4B526c523C733F1F74197A51c495E1;
        MandateOutput memory output = MandateOutput({
            oracle: address(broadcasterOracleSubmitter).toIdentifier(),
            settler: address(outputSettler).toIdentifier(),
            chainId: block.chainid,
            token: bytes32(abi.encode(address(token))),
            amount: amount,
            recipient: bytes32(abi.encode(filler)),
            callbackData: bytes(""),
            context: bytes("")
        });

        payload = MandateOutputEncodingLib.encodeFillDescriptionMemory(
            filler.toIdentifier(),
            keccak256(bytes("orderId")),
            uint32(1761574848),
            output.token,
            output.amount,
            output.recipient,
            bytes(""),
            bytes("")
        );

        return (payload, broadcasterOracleSubmitter, outputSettler);
    }

    function test_verifyMessage() public {
        //vm.selectFork(arbitrumForkId);
        Receiver receiver = new Receiver();

        ArbChildToParentProver childToParentProver = new ArbChildToParentProver(block.chainid);

        BlockHashProverPointer blockHashProverPointer = new BlockHashProverPointer(owner);

        broadcasterOracle = new BroadcasterOracle(receiver, new Broadcaster(), owner);

        vm.prank(owner);
        blockHashProverPointer.setImplementationAddress(address(childToParentProver));

        bytes32 expectedValue = 0x0000000000000000000000000000000000000000000000000000000068ff80bc;

        uint256 blockNumber = 9502200; // block number on parent chain

        (bytes memory input, uint256 expectedSlot, bytes32 blockHash, address knownAccount) =
            _getInputForVerifyMessage();

        bytes32 expectedBlockHash = 0xf5823c7b8d8cca94817b68fc7d1ecfa24ce36803cfdf714f8002add2eb1854ea;

        assertEq(blockHash, expectedBlockHash);

        address aliasedPusher = 0x6B6D4f3d0f0eFAeED2aeC9B59b67Ec62a4667e99;
        bytes32[] memory blockHashes = new bytes32[](1);
        blockHashes[0] = blockHash;

        vm.prank(aliasedPusher);
        buffer.receiveHashes(blockNumber, blockHashes);

        IReceiver.RemoteReadArgs memory remoteReadArgs;
        {
            address[] memory route = new address[](1);
            route[0] = address(blockHashProverPointer);

            bytes[] memory bhpInputs = new bytes[](1);
            bhpInputs[0] = abi.encode(blockNumber);

            remoteReadArgs = IReceiver.RemoteReadArgs({ route: route, bhpInputs: bhpInputs, storageProof: input });
        }

        bytes[] memory payloads = new bytes[](1);
        address broadcasterOracleSubmitter;
        address outputSettler;
        (payloads[0], broadcasterOracleSubmitter, outputSettler) = _getPayloadForVerifyMessage();
        uint256 broadcasterRemoteAccountId = uint256(
            keccak256(
                abi.encode(
                    keccak256(
                        abi.encode(
                            bytes32(0x0000000000000000000000000000000000000000000000000000000000000000),
                            address(blockHashProverPointer)
                        )
                    ),
                    knownAccount
                )
            )
        );

        vm.prank(owner);
        broadcasterOracle.setChainMap(broadcasterRemoteAccountId, 1);

        broadcasterOracle.verifyMessage(
            remoteReadArgs,
            1,
            address(broadcasterOracleSubmitter),
            this.encodeMessageCalldata(address(outputSettler).toIdentifier(), payloads)
        );
    }
}
