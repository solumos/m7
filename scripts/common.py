"""Shared read-only HTTP, Base RPC and ABI helpers for the operational commands."""
from functools import lru_cache
import json
from pathlib import Path
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SYMBOLS = ('AAPLc', 'AMZNc', 'GOOGLc', 'METAc', 'MSFTc', 'NVDAc', 'TSLAc')


def request(url, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers={
        'Content-Type': 'application/json', 'User-Agent': 'm7-tools/0.1'})
    with urllib.request.urlopen(req, timeout=30) as response:
        return response.read()


@lru_cache(maxsize=None)
def selector(signature):
    # Ethereum uses Keccak, not hashlib.sha3_256; reuse installed Foundry.
    return subprocess.check_output(['cast', 'sig', signature], text=True).strip()


@lru_cache(maxsize=None)
def keccak_text(text):
    return int(subprocess.check_output(['cast', 'keccak', text], text=True).strip(), 16)


def word(value):
    number = int(value, 16) if isinstance(value, str) else value
    if not 0 <= number < 2**256:
        raise ValueError('ABI word out of range')
    return format(number, '064x')


def words(encoded):
    body = encoded[2:]
    if len(body) % 64:
        raise ValueError('Malformed ABI response')
    return [int(body[i:i+64], 16) for i in range(0, len(body), 64)]


def address(value):
    return '0x' + format(value, '040x')


class RPC:
    def __init__(self, url):
        self.url = url
        chain = self.rpc('eth_chainId', [])
        if int(chain, 16) != 8453:
            raise ValueError('RPC is not Base mainnet')
        self.block = self.rpc('eth_getBlockByNumber', ['latest', False])

    def rpc(self, method, params):
        response = json.loads(request(self.url, {'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}))
        if 'error' in response:
            raise ValueError(str(response['error']))
        return response['result']

    def call(self, target, signature, *args):
        payload = selector(signature) + ''.join(word(arg) for arg in args)
        return words(self.rpc('eth_call', [{'to': target, 'data': payload}, self.block['number']]))
