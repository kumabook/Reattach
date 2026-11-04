import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install-permission-hooks.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class HookMergeTests(unittest.TestCase):
    def test_preserves_other_hooks_and_is_idempotent(self):
        source = {'hooks': {'Stop': [{'hooks': [{'command': 'custom notify'}]}]}, 'other': True}
        merged = installer.merge(copy.deepcopy(source), ['Stop', 'PermissionRequest'], '/tmp/reattachd agent-event')
        self.assertEqual(merged['hooks']['Stop'][0]['hooks'][0]['command'], 'custom notify')
        self.assertTrue(merged['other'])
        self.assertEqual(installer.merge(copy.deepcopy(merged), ['Stop', 'PermissionRequest'], '/tmp/reattachd agent-event'), merged)

    def test_replaces_only_legacy_reattach_permission_notifications(self):
        source = {'hooks': {'Notification': [
            {'matcher': 'permission_prompt', 'hooks': [{'command': 'reattachd notify'}, {'command': 'other notify'}]},
            {'matcher': 'idle_prompt', 'hooks': [{'command': 'reattachd notify'}]},
        ]}}
        merged = installer.merge(source, ['Notification'], '/tmp/reattachd agent-event')
        entries = merged['hooks']['Notification']
        self.assertEqual(entries[0]['hooks'], [{'command': 'other notify'}])
        self.assertEqual(entries[1]['hooks'], [{'command': 'reattachd notify'}])
        self.assertEqual(entries[2]['matcher'], 'permission_prompt')
        self.assertEqual(entries[2]['hooks'][0]['command'], '/tmp/reattachd agent-event')


if __name__ == '__main__':
    unittest.main()
