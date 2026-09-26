// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Raw CIDv1 (sha2-256, multibase base32) of a single-block file: the CID `ipfs add --cid-version=1`
///         reports for a file of at most 256 KiB. Mirrors scripts/ipfs_cid.py.
library RawCid {
    bytes private constant ALPHABET = "abcdefghijklmnopqrstuvwxyz234567";

    function uri(bytes memory content) internal pure returns (string memory) {
        return string.concat("ipfs://", cid(content));
    }

    function cid(bytes memory content) internal pure returns (string memory) {
        require(content.length <= 256 * 1024, "RawCid: more than one block");
        // CIDv1 (0x01), raw codec (0x55), sha2-256 multihash (0x12) of 32 bytes (0x20).
        bytes memory data = abi.encodePacked(hex"01551220", sha256(content));
        bytes memory out = new bytes(1 + (data.length * 8 + 4) / 5);
        out[0] = "b";
        uint256 buffer;
        uint256 bits;
        uint256 j = 1;
        for (uint256 i; i < data.length; ++i) {
            buffer = ((buffer << 8) | uint8(data[i])) & 0xffff;
            bits += 8;
            while (bits >= 5) {
                bits -= 5;
                out[j++] = ALPHABET[(buffer >> bits) & 31];
            }
        }
        if (bits != 0) out[j] = ALPHABET[(buffer << (5 - bits)) & 31];
        return string(out);
    }
}
