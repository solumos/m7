// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {RawCid} from "../script/RawCid.sol";

/// @dev The deploy guard's CID must equal what IPFS reports, or the immutable methodology URI would be wrong.
contract RawCidTest is Test {
    function testMatchesKnownIpfsCids() public pure {
        assertEq(RawCid.cid(""), "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku");
        assertEq(RawCid.cid("hello"), "bafkreibm6jg3ux5qumhcn2b3flc3tyu6dmlb4xa7u5bf44yegnrjhc4yeq");
        assertEq(RawCid.cid("hello world"), "bafkreifzjut3te2nhyekklss27nh3k72ysco7y32koao5eei66wof36n5e");
        assertEq(RawCid.uri("hello"), "ipfs://bafkreibm6jg3ux5qumhcn2b3flc3tyu6dmlb4xa7u5bf44yegnrjhc4yeq");
    }

    function testMethodologyUriIsStable() public view {
        bytes memory methodology = bytes(vm.readFile("docs/METHODOLOGY.md"));
        string memory cid = RawCid.cid(methodology);
        assertEq(bytes(cid).length, 59);
        assertEq(bytes(cid)[0], bytes1("b"));
    }
}
