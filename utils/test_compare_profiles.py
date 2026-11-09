import csv
import json
from pathlib import Path
import tempfile
import unittest

from compare_profiles import read_capture, summary, differences


class ComparisonTests(unittest.TestCase):
    def test_percentiles_and_empty(self):
        self.assertEqual(summary([120, 1, 10, 2]), {"samples": 4, "median": 6, "p95": 120, "p99": 120})
        self.assertEqual(summary([])["samples"], 0)

    def test_ranges_missing_samples_and_stage_shares(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "capture.csv"
            path.write_text("frame,domain,stage,ms\n1,cpu,total,10\n2,cpu,total,20\n2,gpu,world,12\n2,gpu,total,15\n3,cpu,total,30\n")
            result = read_capture(path, start=2, end=3)
            self.assertEqual(result["missing_gpu_frames"], [3])
            self.assertEqual(result["stages"]["gpu.world"]["stage_share_pct"], 80)
            self.assertEqual(result["stages"]["cpu.total"]["median"], 25)
            self.assertTrue(result["warnings"])

    def test_phase_and_metadata(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "capture.csv"
            path.write_text("frame,domain,stage,ms\n1,cpu,total,100\n2,cpu,total,5\n2,gpu,total,4\n")
            columns = ["frame", "phase", "geometry_revision", "light_revision", "x", "y", "z", "yaw", "pitch", "width", "height"]
            with Path(str(path) + ".frames.csv").open("w") as stream:
                writer = csv.writer(stream)
                writer.writerow(columns)
                for frame, phase in [(1, "warmup"), (2, "measured")]:
                    writer.writerow([frame, phase, 1, 1, 0, 1, 2, 3, 0, 64, 64])
            Path(str(path) + ".meta.json").write_text(json.dumps({"configuration": {"lighting": "direct"}, "result": {"complete": True}}))
            result = read_capture(path)
            self.assertEqual(result["selected_frames"], 1)
            self.assertEqual(result["stages"]["cpu.total"]["median"], 5)
            self.assertEqual(result["missing_gpu_frames"], [])
            self.assertEqual(differences(result, result), {})

    def test_empty_context_does_not_promote_startup_to_measurement(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "capture.csv"
            path.write_text("frame,domain,stage,ms\n1,cpu,total,100\n")
            Path(str(path) + ".frames.csv").write_text("frame,phase\n")
            result = read_capture(path)
            self.assertEqual(result["selected_frames"], 0)
            self.assertEqual(result["cpu_samples"], 0)

    def test_stale_diagnostics_sidecar_ignored_for_uninstrumented_capture(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "capture.csv"
            path.write_text("frame,domain,stage,ms\n1,cpu,total,2\n1,gpu,total,1\n")
            Path(str(path) + ".meta.json").write_text(json.dumps({"configuration": {"benchmark": {"diagnostic_stride": 0}}, "result": {"complete": True}}))
            Path(str(path) + ".diagnostics.csv").write_text("stale incomplete data")
            result = read_capture(path)
            self.assertEqual(result["diagnostics"], {})
            self.assertIsNone(result["missing_diagnostic_frames"])

    def test_invalid_samples_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "capture.csv"
            for samples in ["1,gpu,total,nan\n", "1,gpu,total,2\n1,gpu,total,3\n"]:
                path.write_text("frame,domain,stage,ms\n" + samples)
                with self.assertRaises(ValueError):
                    read_capture(path)


if __name__ == "__main__":
    unittest.main()
