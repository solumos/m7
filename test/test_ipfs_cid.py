import hashlib
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from ipfs_cid import MAX_SINGLE_BLOCK, car, raw_cid, raw_cid_bytes, varint


def read_varint(data, offset):
    value = shift = 0
    while True:
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            return value, offset


class IpfsCidTest(unittest.TestCase):
    def test_matches_known_ipfs_cids(self):
        # The same vectors pin script/RawCid.sol, which Deploy.s.sol uses to check METHODOLOGY_URI.
        self.assertEqual(raw_cid(b''), 'bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku')
        self.assertEqual(raw_cid(b'hello'), 'bafkreibm6jg3ux5qumhcn2b3flc3tyu6dmlb4xa7u5bf44yegnrjhc4yeq')
        self.assertEqual(raw_cid(b'hello world'), 'bafkreifzjut3te2nhyekklss27nh3k72ysco7y32koao5eei66wof36n5e')

    def test_rejects_multi_block_files(self):
        raw_cid(b'x' * MAX_SINGLE_BLOCK)
        with self.assertRaises(ValueError):
            raw_cid(b'x' * (MAX_SINGLE_BLOCK + 1))

    def test_varint_is_unsigned_leb128(self):
        self.assertEqual(varint(0), b'\x00')
        self.assertEqual(varint(58), b'\x3a')
        self.assertEqual(varint(300), b'\xac\x02')

    def test_car_holds_one_root_and_the_exact_block(self):
        content = Path(__file__).resolve().parents[1].joinpath('docs/METHODOLOGY.md').read_bytes()
        data = car(content)
        cid = raw_cid_bytes(content)
        header_length, offset = read_varint(data, 0)
        header = data[offset:offset + header_length]
        self.assertEqual(header, bytes.fromhex('a265726f6f747381d82a582500') + cid + b'\x67version\x01')
        section_length, offset = read_varint(data, offset + header_length)
        self.assertEqual(section_length, len(cid) + len(content))
        self.assertEqual(data[offset:offset + len(cid)], cid)
        self.assertEqual(data[offset + len(cid):], content)
        self.assertEqual(cid[4:], hashlib.sha256(content).digest())


if __name__ == '__main__':
    unittest.main()
