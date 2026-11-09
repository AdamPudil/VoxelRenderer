#!/usr/bin/env python3
"""Compare renderer captures without conflating GPU work and presentation cadence."""
import argparse
import csv
import json
import math
from pathlib import Path
import statistics


def summary(values):
    values = sorted(values)
    if not values:
        return {"samples": 0, "median": None, "p95": None, "p99": None}
    return {"samples": len(values), "median": statistics.median(values),
            "p95": values[math.ceil(len(values) * .95) - 1],
            "p99": values[math.ceil(len(values) * .99) - 1]}


def read_capture(path, start=None, end=None, phase="measured"):
    path = Path(path)
    context_path = Path(str(path) + ".frames.csv")
    metadata_path = Path(str(path) + ".meta.json")
    contexts = {}
    warnings = []
    has_context = context_path.exists()
    if has_context:
        with context_path.open(newline="") as stream:
            contexts = {int(row["frame"]): row for row in csv.DictReader(stream)}
    elif phase != "all":
        warnings.append("No frame sidecar: phase filtering unavailable; using requested frame range.")
    metadata = json.loads(metadata_path.read_text()) if metadata_path.exists() else None
    if metadata is None:
        warnings.append("No metadata: capture comparability is unverified.")
    elif phase == "measured" and not (metadata.get("result") or {}).get("complete"):
        warnings.append("Capture did not complete a stable benchmark; no speedup acceptance is possible.")

    def selected(frame):
        return ((start is None or frame >= start) and (end is None or frame <= end)
                and (phase == "all" or not has_context or contexts.get(frame, {}).get("phase") == phase))

    series = {}
    cpu_frames = set()
    gpu_frames = set()
    with path.open(newline="") as stream:
        rows = csv.DictReader(stream)
        if rows.fieldnames != ["frame", "domain", "stage", "ms"]:
            raise ValueError(f"{path}: expected frame,domain,stage,ms CSV")
        for row in rows:
            frame = int(row["frame"])
            if not selected(frame):
                continue
            duration = float(row["ms"])
            if not math.isfinite(duration) or duration < 0:
                raise ValueError(f"{path}: invalid duration at frame {frame}")
            key = row["domain"] + "." + row["stage"]
            samples = series.setdefault(key, {})
            if frame in samples:
                raise ValueError(f"{path}: duplicate {key} sample at frame {frame}")
            samples[frame] = duration
            if key == "cpu.total":
                cpu_frames.add(frame)
            if key == "gpu.total":
                gpu_frames.add(frame)
    expected = {f for f in contexts if selected(f)} if has_context else cpu_frames | gpu_frames
    if expected - gpu_frames:
        warnings.append(f"{len(expected - gpu_frames)} selected frames have no GPU total; inspect drops before comparing tails.")
    stages = {}
    for key, samples in sorted(series.items()):
        stats = summary(samples.values())
        domain, stage = key.split(".", 1)
        totals = series.get(domain + ".total", {})
        common = samples.keys() & totals.keys()
        denominator = sum(totals[f] for f in common)
        stats["stage_share_pct"] = (100 * sum(samples[f] for f in common) / denominator
                                    if stage != "total" and denominator else None)
        stages[key] = stats
    selected_context = [row for f, row in contexts.items() if selected(f)]
    geometry = sorted({row["geometry_revision"] for row in selected_context})
    lights = sorted({row["light_revision"] for row in selected_context})
    poses = sorted({tuple(row[k] for k in ("x", "y", "z", "yaw", "pitch", "width", "height"))
                    for row in selected_context})
    if len(geometry) > 1 or len(lights) > 1:
        warnings.append("Selected frames contain geometry/light revision changes.")
    if len(poses) > 1:
        warnings.append("Selected frames contain camera or resolution changes.")
    if phase == "measured" and len(expected) < 300:
        warnings.append("Fewer than 300 measured frames; unsuitable for the plan's acceptance threshold.")
    diagnostics = {}
    diagnostic_path = Path(str(path) + ".diagnostics.csv")
    diagnostic_frames = set()
    diagnostic_enabled = diagnostic_path.exists() and (metadata is None or
        metadata.get("configuration", {}).get("benchmark", {}).get("diagnostic_stride", 0) > 0)
    if diagnostic_enabled:
        with diagnostic_path.open(newline="") as stream:
            for row in csv.DictReader(stream):
                frame = int(row["frame"])
                if selected(frame):
                    diagnostic_frames.add(frame)
                    diagnostics.setdefault(row["counter"], []).append(int(row["count"]))
        diagnostics = {key: {**summary(v), "sum": sum(v)} for key, v in diagnostics.items()}
        warnings.append("Instrumented run: raw sampled algorithm counters; measure overhead against diagnostics disabled.")
    return {"path": str(path), "phase": phase, "selected_frames": len(expected),
            "first_frame": min(expected, default=None), "last_frame": max(expected, default=None),
            "cpu_samples": len(cpu_frames), "gpu_samples": len(gpu_frames),
            "missing_gpu_frames": sorted(expected - gpu_frames),
            "missing_cpu_frames": sorted(expected - cpu_frames),
            "missing_diagnostic_frames": sorted(expected - diagnostic_frames) if diagnostic_enabled else None,
            "geometry_revisions": geometry, "light_revisions": lights, "poses": poses,
            "stages": stages, "diagnostics": diagnostics, "metadata": metadata, "warnings": warnings}


def differences(baseline, candidate):
    """Report all changed configuration, including deliberate experimental switches."""
    left = (baseline["metadata"] or {}).get("configuration", {})
    right = (candidate["metadata"] or {}).get("configuration", {})
    result = {}
    for key in sorted(left.keys() | right.keys()):
        if left.get(key) != right.get(key):
            result[key] = {"baseline": left.get(key), "candidate": right.get(key)}
    if baseline["poses"] != candidate["poses"]:
        result["recorded_camera_and_framebuffer"] = {"baseline": baseline["poses"], "candidate": candidate["poses"]}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("captures", nargs="+", help="CSV files; compare each with the first")
    parser.add_argument("--start", type=int, help="inclusive frame ID")
    parser.add_argument("--end", type=int, help="inclusive frame ID")
    parser.add_argument("--phase", default="measured", choices=["measured", "all", "settling", "warmup", "interactive", "unstable"])
    parser.add_argument("--json", action="store_true", help="machine-readable report")
    args = parser.parse_args()
    if args.start is not None and args.end is not None and args.start > args.end:
        parser.error("--start must not exceed --end")
    try:
        runs = [read_capture(p, args.start, args.end, args.phase) for p in args.captures]
    except (OSError, ValueError, KeyError) as error:
        parser.error(str(error))
    for run in runs[1:]:
        run["configuration_differences"] = differences(runs[0], run)
        first = runs[0]["stages"].get("gpu.total", {}).get("median")
        current = run["stages"].get("gpu.total", {}).get("median")
        run["observed_gpu_median_change_pct"] = 100 * (current / first - 1) if first and current is not None else None
    # Quantify repeated-run variation only for identical metadata + observed pose.
    groups = {}
    for run in runs:
        if run["metadata"] is None:
            continue
        key = json.dumps([run["metadata"]["configuration"], run["poses"]], sort_keys=True)
        groups.setdefault(key, []).append(run)
    repeatability = []
    for group in groups.values():
        medians = [r["stages"]["gpu.total"]["median"] for r in group if "gpu.total" in r["stages"]]
        if len(medians) < 2:
            continue
        center = statistics.median(medians)
        repeatability.append({"captures": [r["path"] for r in group], "run_medians_ms": medians,
                              "median_ms": center, "range_pct": 100 * (max(medians) - min(medians)) / center if center else None,
                              "stdev_ms": statistics.stdev(medians)})
    if args.json:
        print(json.dumps({"captures": runs, "repeatability": repeatability}, indent=2))
        return
    for run in runs:
        print(f"\n{run['path']}: frames {run['first_frame']}–{run['last_frame']} ({run['phase']})")
        print(f"  CPU {run['cpu_samples']}, GPU {run['gpu_samples']}, missing GPU {len(run['missing_gpu_frames'])}")
        print("  stage                         samples   median ms      p95      p99   share %")
        for key, stat in run["stages"].items():
            share = stat["stage_share_pct"]
            print(f"  {key:29} {stat['samples']:7} {stat['median']:11.3f} {stat['p95']:8.3f} {stat['p99']:8.3f} {share if share is not None else 0:9.2f}")
        if "configuration_differences" in run:
            print("  Changed configuration:", ", ".join(run["configuration_differences"]) or "none")
            change = run["observed_gpu_median_change_pct"]
            if change is not None:
                print(f"  Observed GPU median change vs first: {change:+.2f}% (not an acceptance verdict)")
        for warning in run["warnings"]:
            print("  NOTE:", warning)
        for key, stat in run["diagnostics"].items():
            print(f"  diagnostic {key}: n={stat['samples']} median={stat['median']} sum={stat['sum']}")
    for group in repeatability:
        print(f"\nRepeated configuration: n={len(group['captures'])}, median={group['median_ms']:.3f} ms, range={group['range_pct']:.2f}%, stdev={group['stdev_ms']:.3f} ms")


if __name__ == "__main__":
    main()
