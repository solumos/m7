#!/usr/bin/env python3
"""Print the ipfs:// URI of a file's raw CIDv1, the CID `ipfs add --cid-version=1` gives a file of one block.

Deploy.s.sol refuses a METHODOLOGY_URI other than this value for docs/METHODOLOGY.md. Optionally write a CARv1
file holding that single block, for pinning services that import CARs, and check a gateway serves the exact bytes.
"""
import argparse
import base64
import hashlib
from pathlib import Path
import sys
import urllib.request

# CIDv1 (0x01), raw codec (0x55), sha2-256 multihash (0x12) of 32 bytes (0x20).
RAW_CID_PREFIX = bytes.fromhex('01551220')
# Kubo's default chunk size. A larger file becomes a UnixFS DAG whose CID is not a raw CID.
MAX_SINGLE_BLOCK = 256 * 1024


def raw_cid_bytes(content):
    if len(content) > MAX_SINGLE_BLOCK:
        raise ValueError('File exceeds one 256 KiB block; its CID would be a UnixFS DAG, not a raw CID')
    return RAW_CID_PREFIX + hashlib.sha256(content).digest()


def raw_cid(content):
    """Multibase base32 (lowercase, unpadded) raw CIDv1 of `content`."""
    return 'b' + base64.b32encode(raw_cid_bytes(content)).decode('ascii').lower().rstrip('=')


def varint(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        out.append(byte | (0x80 if value else 0))
        if not value:
            return bytes(out)


def car(content):
    """CARv1 with one root: the raw block itself. The DAG-CBOR header is {"roots": [cid], "version": 1}."""
    cid = raw_cid_bytes(content)
    link = b'\x00' + cid  # DAG-CBOR links are tag 42 over the identity-multibase CID bytes
    header = (b'\xa2' + b'\x65roots' + b'\x81' + b'\xd8\x2a' + b'\x58' + bytes([len(link)]) + link
              + b'\x67version' + b'\x01')
    return varint(len(header)) + header + varint(len(cid) + len(content)) + cid + content


def fetch(gateway, cid):
    url = gateway.rstrip('/') + '/ipfs/' + cid
    request = urllib.request.Request(url, headers={'User-Agent': 'm7cap-ipfs-check/0.1'})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path', type=Path)
    parser.add_argument('--car', type=Path, help='Also write a CARv1 file containing the block')
    parser.add_argument('--gateway', action='append', default=[],
                        help='Fetch the CID from this gateway (e.g. https://ipfs.io) and compare the bytes')
    args = parser.parse_args()
    content = args.path.read_bytes()
    cid = raw_cid(content)
    print('ipfs://' + cid)
    if args.car:
        args.car.write_bytes(car(content))
    failed = False
    for gateway in args.gateway:
        try:
            served = fetch(gateway, cid)
            ok = served == content
            print(gateway + (': identical bytes' if ok else ': DIFFERENT BYTES (%d served)' % len(served)),
                  file=sys.stderr)
        except Exception as exc:
            ok = False
            print(gateway + ': unavailable (' + str(exc) + ')', file=sys.stderr)
        failed |= not ok
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
