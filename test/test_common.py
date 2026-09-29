import io
import json
import unittest
from unittest.mock import patch

from scripts.common import RPC, request, word


class TransportTest(unittest.TestCase):
    def test_rpc_pins_calls_to_one_base_block_and_decodes_words(self):
        responses = ['0x2105', {'number': '0x42'}, '0x' + word(7) + word(9)]
        replies = [io.BytesIO(json.dumps({'result': value}).encode()) for value in responses]
        with patch('scripts.common.urllib.request.urlopen', side_effect=replies) as send:
            rpc = RPC('https://example.test')
            self.assertEqual(rpc.call('0x' + '11' * 20, 'balanceOf(address)', '0x' + '22' * 20), [7, 9])
        payload = json.loads(send.call_args.args[0].data)
        self.assertEqual(payload['method'], 'eth_call')
        self.assertEqual(payload['params'][1], '0x42')
        self.assertEqual(payload['params'][0]['data'], '0x70a08231' + word('0x' + '22' * 20))

    def test_rpc_rejects_wrong_chain_and_provider_errors(self):
        for response, error in [({'result': '0x1'}, 'not Base'), ({'error': {'message': 'unavailable'}}, 'unavailable')]:
            with self.subTest(response=response), patch('scripts.common.urllib.request.urlopen', return_value=io.BytesIO(json.dumps(response).encode())):
                with self.assertRaisesRegex(ValueError, error):
                    RPC('https://example.test')

    def test_webhook_and_heartbeat_accept_non_json_responses(self):
        for payload, body in [({'text': 'alert'}, b'ok'), (None, b'')]:
            with self.subTest(payload=payload), patch('scripts.common.urllib.request.urlopen', return_value=io.BytesIO(body)) as send:
                self.assertEqual(request('https://example.test', payload), body)
                sent = send.call_args.args[0]
                self.assertEqual(sent.get_method(), 'POST' if payload else 'GET')
                self.assertEqual(json.loads(sent.data) if payload else sent.data, payload)
                self.assertEqual(send.call_args.kwargs['timeout'], 30)
