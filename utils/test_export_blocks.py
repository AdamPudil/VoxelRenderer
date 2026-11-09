"""Regression checks for authored rotation settings during GOX re-export."""
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import export_blocks


class RotationExportTests(unittest.TestCase):
    def test_reexport_preserves_rotation_and_rejects_invalid_before_writing(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'source'
            dest = Path(folder) / 'output'
            source.mkdir()
            (source / 'sample.gox').touch()
            args = SimpleNamespace(source=source, output=dest, dry_run=False)
            with patch.object(export_blocks, 'load_gox', return_value=([], [('Front', [])])), \
                    patch.object(export_blocks, 'collect_voxels', return_value={(0, 0, 0): (255, 0, 0, 255)}):
                self.assertEqual(export_blocks.run(args), 0)
                descriptor = dest / '100_sample_front.block'
                model = dest / '100_sample_front.vox'
                self.assertNotIn('rotation:', descriptor.read_text())
                for value in ('yaw', 'none'):
                    descriptor.write_text(descriptor.read_text() + f'RoTaTiOn: "{value.upper()}"\n')
                    self.assertEqual(export_blocks.run(args), 0)
                    self.assertIn(f'rotation: {value}\n', descriptor.read_text())
                    self.assertEqual(export_blocks.run(args), 0)
                    self.assertEqual(descriptor.read_text().count('rotation:'), 1)
                    descriptor.write_text(descriptor.read_text().replace(f'rotation: {value}\n', ''))
                for invalid in ('rotation: facing\n', 'rotation: yaw\nrotation: none\n'):
                    descriptor.write_text(invalid)
                    model.write_bytes(b'preserve on invalid metadata')
                    self.assertEqual(export_blocks.run(args), 1)
                    self.assertEqual(descriptor.read_text(), invalid)
                    self.assertEqual(model.read_bytes(), b'preserve on invalid metadata')


if __name__ == '__main__':
    unittest.main()
