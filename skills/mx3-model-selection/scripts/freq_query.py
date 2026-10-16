#!/usr/bin/env python3
"""Apply the TX8 MX3 frequency rule to the MemryX reference matrix (tx8-freq-matrix.csv).

Usage:
  python3 freq_query.py --model-regex YOLO26_nano_640 [--target-fps 30] [--safety 1.5]
  python3 freq_query.py --task detect --input-size 640 [--format csv]
  python3 freq_query.py --help

Rule (docs/DESIGN.md section 2.4, product owner):
  1. Only frequencies present in the table, <= --max-freq (default 400 MHz), status PASS.
  2. Pick the LOWEST such frequency where fps >= target_fps * safety (default 30 * 1.5 = 45).
  3. None qualifies -> "not recommended" for this target.
  4. Model or chip count (1-3 chips) not in the table -> run the on-board stability test first
     (skill mx3-runtime-integration, scripts/mx3_stability_test.sh).
The table is MemryX reference data measured with 4 chips (config 4x1), NOT measured on TX8.

Python 3.10+, standard library only, read-only. Mirrors scripts/freq_query.ps1 (keep the task
heuristic in sync with freq_query.ps1 and gen_detection_summary.ps1).
Exit codes: 0 = at least one model listed, 1 = no model matched, 2 = usage error.
"""
from __future__ import annotations

import argparse
import csv
import re
import sys
from pathlib import Path

DEFAULT_CSV = Path(__file__).resolve().parent.parent / "references" / "tx8-freq-matrix.csv"
TASKS = ("any", "detect", "obb", "segment", "pose", "classify", "depth", "track")
INPUT_RE = re.compile(r"_(\d+)_(\d+)_(\d+)_(onnx|tflite|tensorflow|keras)$")


def task_of(name: str) -> str:
    """Name-based task heuristic (same order as freq_query.ps1)."""
    n = name.lower()
    if re.search(r"oriented_bounding_boxes|_obb", n):
        return "obb"
    if re.search(r"pose|kpts|keypoint|landmark", n):
        return "pose"
    if re.search(r"_cls_|classif|malaria_detector", n):
        return "classify"
    if re.search(r"_seg_|segment|deeplab|unet|bisenet|pspnet|lanenet|yolop", n):
        return "segment"
    if re.search(r"depth|midas|dpt_", n):
        return "depth"
    if re.search(r"3d|pointpillars|centerpoint|text_detection", n):
        return "other"
    if re.search(r"yolo|ssd|rtmdet|nanodet|damo|efficientdet|centernet|detection|detector|detr"
                 r"|retinanet|fcos|mobiledet|yunet", n):
        return "detect"
    return "other"


def input_of(name: str) -> str:
    m = INPUT_RE.search(name)
    return f"{m.group(1)}x{m.group(2)}" if m else ""


def load_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig") as fh:
        lines = [ln for ln in fh if ln.strip() and not ln.lstrip().startswith("#")]
    return list(csv.DictReader(lines))


def to_float(value: str) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Recommend the lowest MX3 clock (<= 400 MHz) per model from tx8-freq-matrix.csv.")
    p.add_argument("--model-regex", default=".", help="case-insensitive regex on model name")
    p.add_argument("--input-size", default="", help="'640' (= 640x640) or 'HxW', e.g. 480x640")
    p.add_argument("--target-fps", type=float, default=30.0, help="required sustained fps (default 30)")
    p.add_argument("--safety", type=float, default=1.5, help="safety factor (default 1.5)")
    p.add_argument("--max-freq", type=int, default=400, help="highest allowed MHz (default 400)")
    p.add_argument("--allow-above-400", action="store_true",
                   help="permit --max-freq > 400 for analysis only (violates the product rule)")
    p.add_argument("--task", choices=TASKS, default="any",
                   help="name heuristic filter; track = detect")
    p.add_argument("--csv", type=Path, default=DEFAULT_CSV, help="path to tx8-freq-matrix.csv")
    p.add_argument("--format", choices=("text", "csv"), default="text")
    return p.parse_args(argv)


def main(argv: list[str]) -> int:
    a = parse_args(argv)
    if a.max_freq > 400:
        if not a.allow_above_400:
            print(f"error: --max-freq {a.max_freq} exceeds the product rule (MX3 clock <= 400 MHz); "
                  "add --allow-above-400 for analysis only", file=sys.stderr)
            return 2
        print(f"WARNING !!! --max-freq {a.max_freq} MHz VIOLATES the TX8 product rule (<= 400 MHz). "
              "Analysis only, not for deployment. !!!", file=sys.stderr)
    if not a.csv.is_file():
        print(f"error: CSV not found: {a.csv}", file=sys.stderr)
        return 2

    want_input = ""
    if a.input_size:
        if re.fullmatch(r"\d+", a.input_size):
            want_input = f"{a.input_size}x{a.input_size}"
        elif re.fullmatch(r"\d+x\d+", a.input_size.lower()):
            want_input = a.input_size.lower()
        else:
            print("error: --input-size must be N or HxW", file=sys.stderr)
            return 2
    want_task = "detect" if a.task == "track" else a.task
    try:
        rx = re.compile(a.model_regex, re.IGNORECASE)
    except re.error as exc:
        print(f"error: bad --model-regex: {exc}", file=sys.stderr)
        return 2
    need = a.target_fps * a.safety

    by_model: dict[str, list[dict[str, str]]] = {}
    for row in load_rows(a.csv):
        name = row.get("model", "")
        if rx.search(name):
            by_model.setdefault(name, []).append(row)

    results = []
    for name in sorted(by_model, key=str.lower):
        task = task_of(name)
        if want_task != "any" and task != want_task:
            continue
        inp = input_of(name)
        if want_input and inp != want_input:
            continue
        passing = []
        for r in by_model[name]:
            freq = int(r["freq_mhz"])
            fps = to_float(r.get("fps", ""))
            if r.get("status") == "PASS" and freq <= a.max_freq and fps is not None:
                passing.append((freq, fps, r))
        passing.sort(key=lambda t: t[0])
        pick = next((t for t in passing if t[1] >= need), None)
        if pick:
            freq, fps, r = pick
            results.append(dict(model=name, task=task, input=inp, recommended_mhz=str(freq),
                                fps=f"{fps:.1f}", power_mw=r.get("power_mw", ""),
                                temp_c=r.get("temp_c", ""), verdict="OK",
                                reason=f"fps {fps:.1f} >= {need:g}"))
        else:
            best = max(passing, key=lambda t: t[1]) if passing else None
            results.append(dict(
                model=name, task=task, input=inp, recommended_mhz="",
                fps=f"{best[1]:.1f}" if best else "",
                power_mw=best[2].get("power_mw", "") if best else "",
                temp_c=best[2].get("temp_c", "") if best else "",
                verdict="not recommended",
                reason=(f"best {best[1]:.1f} fps @ {best[0]} MHz < {need:g}" if best
                        else f"no PASS row <= {a.max_freq} MHz")))

    if not results:
        print(f"No model in the matrix matches regex '{a.model_regex}' "
              f"(task={a.task}, input={a.input_size or 'any'}).")
        print("-> Not in the reference table: run the on-board stability test first "
              "(skill mx3-runtime-integration).")
        return 1

    cols = ["model", "task", "input", "recommended_mhz", "fps", "power_mw", "temp_c", "verdict", "reason"]
    if a.format == "csv":
        w = csv.DictWriter(sys.stdout, fieldnames=cols, lineterminator="\n")
        w.writeheader()
        w.writerows(results)
        return 0

    print(f"Rule: lowest PASS freq <= {a.max_freq} MHz with fps >= {a.target_fps:g} x {a.safety:g} = "
          f"{need:g}. Source: MemryX reference table (4 chips), NOT TX8 data.")
    widths = {c: max(len(c), *(len(str(r[c])) for r in results)) for c in cols}
    print("  ".join(c.ljust(widths[c]) for c in cols))
    print("  ".join("-" * widths[c] for c in cols))
    for r in results:
        print("  ".join(str(r[c]).ljust(widths[c]) for c in cols))
    print("Verify on TX8 before deployment (skill mx3-runtime-integration). "
          "Chip counts 1-3 are not in the table.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
