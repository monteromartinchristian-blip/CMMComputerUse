"""Metadata contract, without a socket or native GUI substitute."""
import json
import unittest
from cmm_computer_use.mcp_server import ToolRegistry, _render_observation


class ViewMetadataTests(unittest.TestCase):
    def test_observation_exposes_only_helper_identity_before_ax_text(self):
        text = _render_observation({'target_app': 'Fixture', 'target_bundle': 'com.example.computer-use-fixture',
            'target_pid': 123, 'snapshot': 3, 'target_window': 'Fixture', 'target_window_id': 42,
            'content': [{'role': 'AXStaticText', 'text': 'private'}]})
        line = next(line for line in text.splitlines()[:4] if line.startswith('cmm_view: '))
        self.assertEqual(json.loads(line[10:]), {'bundle': 'com.example.computer-use-fixture', 'pid': 123,
            'snapshot': 3, 'window': 'Fixture', 'window_id': 42})
        self.assertNotIn('private', line)

    def test_capture_preserves_mcp_image_and_adds_selected_window_identity(self):
        class CaptureClient:
            def capture_window(self, app, title):
                return {'screenshot_base64': 'QUJD', 'screenshot_scope': 'window',
                    'view_identity': {'bundle': 'com.example.computer-use-fixture', 'pid': 123,
                        'window': 'Fixture', 'window_id': 42, 'snapshot': 3, 'private': 'secret'}}
        result = ToolRegistry(CaptureClient(), 'background')._capture({'app': 'Fixture', 'window_title': 'Fixture'})
        self.assertEqual(result['content'][1], {'type': 'image', 'data': 'QUJD', 'mimeType': 'image/png'})
        text = result['content'][0]['text']
        self.assertTrue(text.startswith('Captured one window (scope=window).\n'))
        self.assertNotIn('secret', text)
        self.assertEqual(json.loads(text.splitlines()[1][10:])['window_id'], 42)

    def test_old_helper_does_not_get_invented_identity(self):
        self.assertNotIn('cmm_view:', _render_observation({'target_bundle': 'old'}))
