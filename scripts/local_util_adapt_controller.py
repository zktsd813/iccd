#!/usr/bin/env python3
"""Userspace controller for local-fault based NUMA migration control.

The controller is workload agnostic: run it next to any benchmark process that
is already placed in a target cgroup.  It periodically opens a new local-fault
measurement window, reads the cgroup migration stats, and disables migration
when the local access ratio stays above a threshold for enough consecutive
windows.  Optionally it can keep running after that stop and re-enable
migration when the stop condition is not satisfied for enough windows.
"""

from __future__ import annotations

import argparse
import csv
import os
import signal
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, Optional, TextIO


MIGRATE_STATE_KEYS = (
    "numa_local_fault_pte_updates",
    "numa_local_fault_refault",
    "numa_local_fault_refault_hit",
    "numa_local_fault_lost",
)


@dataclass
class WindowStats:
    seq: int = 0
    pte_updates: int = 0
    refault: int = 0
    refault_hit: int = 0
    lost: int = 0
    hint_faults: int = 0


class CgroupKnobs:
    def __init__(self, cgroup: Path):
        self.cgroup = cgroup

    def knob_path(self, name: str, *, required: bool = True) -> Optional[Path]:
        candidates = (self.cgroup / name, self.cgroup / f"memory.{name}")
        for candidate in candidates:
            if candidate.exists():
                return candidate
        if required:
            raise FileNotFoundError(
                f"missing cgroup knob '{name}' or 'memory.{name}' under {self.cgroup}"
            )
        return None

    def read_knob(self, name: str, default: Optional[str] = None) -> str:
        path = self.knob_path(name, required=default is None)
        if path is None:
            return default if default is not None else ""
        try:
            return path.read_text(encoding="ascii").strip()
        except OSError:
            if default is not None:
                return default
            raise

    def write_knob(self, name: str, value: object, *, required: bool = True) -> bool:
        path = self.knob_path(name, required=required)
        if path is None:
            return False
        path.write_text(f"{value}\n", encoding="ascii")
        return True

    def migrate_state(self) -> Dict[str, int]:
        raw = self.read_knob("numa_migrate_state")
        state: Dict[str, int] = {}
        for line in raw.splitlines():
            fields = line.split()
            if len(fields) < 2:
                continue
            try:
                state[fields[0]] = int(fields[1])
            except ValueError:
                continue
        return state

    def memory_stat(self) -> Dict[str, int]:
        raw = self.read_knob("stat", default="")
        state: Dict[str, int] = {}
        for line in raw.splitlines():
            fields = line.split()
            if len(fields) < 2:
                continue
            try:
                state[fields[0]] = int(fields[1])
            except ValueError:
                continue
        return state

    def node_balancing(self) -> str:
        return self.read_knob("node_balancing", default="")


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def monotonic_ms() -> int:
    return int(time.monotonic() * 1000)


def read_totals(knobs: CgroupKnobs) -> WindowStats:
    state = knobs.migrate_state()
    memory = knobs.memory_stat()
    return WindowStats(
        pte_updates=state.get("numa_local_fault_pte_updates", 0),
        refault=state.get("numa_local_fault_refault", 0),
        refault_hit=state.get("numa_local_fault_refault_hit", 0),
        lost=state.get("numa_local_fault_lost", 0),
        hint_faults=memory.get("numa_hint_faults", 0),
    )


def diff_stats(cur: WindowStats, base: WindowStats) -> WindowStats:
    return WindowStats(
        pte_updates=max(0, cur.pte_updates - base.pte_updates),
        refault=max(0, cur.refault - base.refault),
        refault_hit=max(0, cur.refault_hit - base.refault_hit),
        lost=max(0, cur.lost - base.lost),
        hint_faults=max(0, cur.hint_faults - base.hint_faults),
    )


def read_bucket(knobs: CgroupKnobs, prefix: str) -> Optional[WindowStats]:
    state = knobs.migrate_state()
    key_prefix = f"numa_local_fault_window_{prefix}_"
    seq = state.get(f"{key_prefix}seq", 0)
    if seq <= 0:
        return None
    return WindowStats(
        seq=seq,
        pte_updates=state.get(f"{key_prefix}pte_updates", 0),
        refault=state.get(f"{key_prefix}refault", 0),
        refault_hit=state.get(f"{key_prefix}refault_hit", 0),
        lost=state.get(f"{key_prefix}lost", 0),
    )


def sleep_interruptible(seconds: float, stop_file: Optional[Path], stop_flag) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if stop_flag["stop"]:
            return False
        if stop_file is not None and stop_file.exists():
            return False
        time.sleep(min(0.2, max(0.0, deadline - time.monotonic())))
    return True


def ratio_pct(numerator: int, denominator: int) -> float:
    if denominator <= 0:
        return 0.0
    return numerator * 100.0 / denominator


def sample_pct(args, knobs: CgroupKnobs) -> float:
    if args.local_fault_sample_pct > 0:
        return args.local_fault_sample_pct
    try:
        return float(knobs.read_knob("numa_local_fault_on_tiering", default="0") or 0)
    except ValueError:
        return 0.0


def estimated_local_accesses(local_faults: int, sample_percent: float) -> float:
    if sample_percent <= 0:
        return 0.0
    return local_faults * 100.0 / sample_percent


def estimated_remote_accesses(stats: WindowStats, sample_percent: float) -> float:
    if stats.hint_faults <= 0:
        return 0.0
    local_estimate = estimated_local_accesses(stats.refault, sample_percent)
    return max(0.0, float(stats.hint_faults) - local_estimate)


def remote_ratio_pct(stats: WindowStats, sample_percent: float) -> float:
    if stats.hint_faults <= 0 or sample_percent <= 0:
        return 0.0
    return estimated_remote_accesses(stats, sample_percent) * 100.0 / stats.hint_faults


def write_event(writer: csv.DictWriter, event: str, started_ms: int, window: int,
                window_seq: int, args, stats: WindowStats, remote_stats: WindowStats,
                local_consecutive: int,
                remote_consecutive: int, node_balancing: str, sample_percent: float,
                stop_reason: str = "", reenable_consecutive: int = 0,
                controller_state: str = "") -> None:
    access_pct = ratio_pct(stats.refault, stats.pte_updates)
    fast_pct = ratio_pct(stats.refault_hit, stats.pte_updates)
    remote_pct = remote_ratio_pct(remote_stats, sample_percent)
    writer.writerow(
        {
            "event": event,
            "timestamp": now_iso(),
            "elapsed_ms": monotonic_ms() - started_ms,
            "window": window,
            "window_seq": window_seq,
            "window_sec": args.window_sec,
            "threshold_pct": args.threshold_pct,
            "remote_threshold_pct": args.remote_threshold_pct,
            "min_pte_updates": args.min_pte_updates,
            "min_hint_faults": args.min_hint_faults,
            "sample_pct": f"{sample_percent:.2f}",
            "pte_delta": stats.pte_updates,
            "hit_delta": stats.refault_hit,
            "refault_delta": stats.refault,
            "lost_delta": stats.lost,
            "remote_refault_delta": remote_stats.refault,
            "hint_fault_delta": remote_stats.hint_faults,
            "estimated_local_accesses": f"{estimated_local_accesses(remote_stats.refault, sample_percent):.2f}",
            "estimated_remote_accesses": f"{estimated_remote_accesses(remote_stats, sample_percent):.2f}",
            "access_pct": f"{access_pct:.2f}",
            "fast_pct": f"{fast_pct:.2f}",
            "remote_ratio_pct": f"{remote_pct:.2f}",
            "local_consecutive": local_consecutive,
            "remote_consecutive": remote_consecutive,
            "reenable_consecutive": reenable_consecutive,
            "consecutive": local_consecutive,
            "stop_reason": stop_reason,
            "controller_state": controller_state,
            "node_balancing": node_balancing,
        }
    )


def parse_args(argv: Optional[Iterable[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Disable cgroup NUMA migration after repeated high local-fault access windows."
    )
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--cgroup", type=Path, help="target cgroup directory")
    target.add_argument("--cgroup-name", help="target cgroup name under --cgroup-root")
    parser.add_argument("--cgroup-root", type=Path, default=Path("/sys/fs/cgroup"))
    parser.add_argument("--window-sec", type=float, default=10.0)
    parser.add_argument("--threshold-pct", type=float, default=80.0)
    parser.add_argument("--consecutive", type=int, default=3)
    parser.add_argument("--min-pte-updates", type=int, default=1000)
    parser.add_argument(
        "--remote-threshold-pct",
        type=float,
        default=20.0,
        help="stop when estimated residual remote ratio is <= this value",
    )
    parser.add_argument(
        "--remote-consecutive",
        type=int,
        default=0,
        help="remote-ratio consecutive target; 0 reuses --consecutive",
    )
    parser.add_argument("--min-hint-faults", type=int, default=1)
    parser.add_argument(
        "--local-fault-sample-pct",
        type=float,
        default=0.0,
        help="local fault sampling percentage; 0 reads numa_local_fault_on_tiering",
    )
    parser.add_argument(
        "--eval-lag",
        choices=("current", "prev", "prev2"),
        default="prev",
        help="which kernel window bucket to evaluate when available",
    )
    parser.add_argument(
        "--no-window-buckets",
        action="store_true",
        help="use raw counter deltas instead of kernel window buckets",
    )
    parser.add_argument(
        "--no-advance-window",
        action="store_true",
        help="do not write numa_local_fault_window=1 at each interval start",
    )
    parser.add_argument("--stop-file", type=Path, help="exit when this file appears")
    parser.add_argument("--max-windows", type=int, default=0, help="0 means unlimited")
    parser.add_argument("--output", type=Path, help="CSV output path, default stdout")
    parser.add_argument("--dry-run", action="store_true", help="log off event but do not write node_balancing=0")
    parser.add_argument(
        "--node-balancing-on",
        default="2",
        help="value written to node_balancing when migration is re-enabled",
    )
    parser.add_argument(
        "--reenable-consecutive",
        type=int,
        default=0,
        help="0 keeps old one-shot stop behavior; >0 re-enables after this many windows without the stop condition",
    )
    parser.add_argument(
        "--stop-local-fault",
        action="store_true",
        help="also write numa_local_fault_on_tiering=0 when stopping",
    )
    return parser.parse_args(argv)


def validate_args(args: argparse.Namespace) -> None:
    if args.cgroup_name:
        args.cgroup = args.cgroup_root / args.cgroup_name
    if args.window_sec <= 0:
        raise ValueError("--window-sec must be > 0")
    if args.threshold_pct < 0:
        raise ValueError("--threshold-pct must be >= 0")
    if args.remote_threshold_pct < 0:
        raise ValueError("--remote-threshold-pct must be >= 0")
    if args.consecutive < 1:
        raise ValueError("--consecutive must be >= 1")
    if args.remote_consecutive < 0:
        raise ValueError("--remote-consecutive must be >= 0")
    if args.min_pte_updates < 0:
        raise ValueError("--min-pte-updates must be >= 0")
    if args.min_hint_faults < 0:
        raise ValueError("--min-hint-faults must be >= 0")
    if args.local_fault_sample_pct < 0:
        raise ValueError("--local-fault-sample-pct must be >= 0")
    if args.max_windows < 0:
        raise ValueError("--max-windows must be >= 0")
    if args.reenable_consecutive < 0:
        raise ValueError("--reenable-consecutive must be >= 0")
    if args.remote_consecutive == 0:
        args.remote_consecutive = args.consecutive
    if not args.cgroup.is_dir():
        raise FileNotFoundError(f"cgroup directory does not exist: {args.cgroup}")


def open_output(path: Optional[Path]) -> tuple[TextIO, bool]:
    if path is None:
        return sys.stdout, False
    path.parent.mkdir(parents=True, exist_ok=True)
    return path.open("w", encoding="ascii", newline=""), True


def run_controller(args: argparse.Namespace) -> int:
    knobs = CgroupKnobs(args.cgroup)
    stop_flag = {"stop": False}

    def handle_signal(signum, frame):  # noqa: ARG001
        stop_flag["stop"] = True

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    out, should_close = open_output(args.output)
    fields = (
        "event",
        "timestamp",
        "elapsed_ms",
        "window",
        "window_seq",
        "window_sec",
        "threshold_pct",
        "remote_threshold_pct",
        "min_pte_updates",
        "min_hint_faults",
        "sample_pct",
        "pte_delta",
        "hit_delta",
        "refault_delta",
        "lost_delta",
        "remote_refault_delta",
        "hint_fault_delta",
        "estimated_local_accesses",
        "estimated_remote_accesses",
        "access_pct",
        "fast_pct",
        "remote_ratio_pct",
        "local_consecutive",
        "remote_consecutive",
        "reenable_consecutive",
        "consecutive",
        "stop_reason",
        "controller_state",
        "node_balancing",
    )
    writer = csv.DictWriter(out, fieldnames=fields)
    writer.writeheader()

    try:
        started_ms = monotonic_ms()
        local_consecutive = 0
        remote_consecutive = 0
        reenable_consecutive = 0
        controller_state = "on"
        window = 0
        initial_seq = int(knobs.read_knob("numa_local_fault_window", default="0") or 0)
        current_sample_pct = sample_pct(args, knobs)
        configured_sample_pct = current_sample_pct
        write_event(
            writer,
            "start",
            started_ms,
            0,
            initial_seq,
            args,
            WindowStats(),
            WindowStats(),
            0,
            0,
            knobs.node_balancing(),
            current_sample_pct,
            "",
            reenable_consecutive,
            controller_state,
        )
        out.flush()

        while not stop_flag["stop"]:
            if args.stop_file is not None and args.stop_file.exists():
                break
            if args.max_windows and window >= args.max_windows:
                break

            window += 1
            if not args.no_advance_window:
                knobs.write_knob("numa_local_fault_window", 1, required=False)

            try:
                window_seq = int(knobs.read_knob("numa_local_fault_window", default="0") or 0)
            except ValueError:
                window_seq = 0

            base = read_totals(knobs)
            if not sleep_interruptible(args.window_sec, args.stop_file, stop_flag):
                break
            cur = read_totals(knobs)
            raw_stats = diff_stats(cur, base)
            stats = raw_stats

            if not args.no_window_buckets:
                bucket = read_bucket(knobs, args.eval_lag)
                if bucket is not None:
                    window_seq = bucket.seq
                    stats = bucket

            current_sample_pct = sample_pct(args, knobs)
            access = ratio_pct(stats.refault, stats.pte_updates)
            remote = remote_ratio_pct(raw_stats, current_sample_pct)
            local_condition = stats.pte_updates >= args.min_pte_updates and access >= args.threshold_pct
            remote_condition = raw_stats.hint_faults >= args.min_hint_faults and remote <= args.remote_threshold_pct
            stop_reason = ""
            if local_condition:
                stop_reason = "local_access"
            elif remote_condition:
                stop_reason = "remote_ratio"

            if local_condition:
                local_consecutive += 1
            else:
                local_consecutive = 0
            if remote_condition:
                remote_consecutive += 1
            else:
                remote_consecutive = 0

            if controller_state == "off":
                if stop_reason:
                    reenable_consecutive = 0
                else:
                    reenable_consecutive += 1

            node_balancing = knobs.node_balancing()
            write_event(
                writer,
                "sample",
                started_ms,
                window,
                window_seq,
                args,
                stats,
                raw_stats,
                local_consecutive,
                remote_consecutive,
                node_balancing,
                current_sample_pct,
                "",
                reenable_consecutive,
                controller_state,
            )
            out.flush()

            should_stop = (
                controller_state == "on"
                and (
                    local_consecutive >= args.consecutive
                    or remote_consecutive >= args.remote_consecutive
                )
            )
            if should_stop:
                if local_consecutive >= args.consecutive:
                    stop_reason = "local_access"
                else:
                    stop_reason = "remote_ratio"
                if not args.dry_run:
                    knobs.write_knob("node_balancing", 0)
                    if args.stop_local_fault:
                        knobs.write_knob("numa_local_fault_on_tiering", 0, required=False)
                controller_state = "off"
                reenable_consecutive = 0
                node_balancing = knobs.node_balancing()
                write_event(
                    writer,
                    "off",
                    started_ms,
                    window,
                    window_seq,
                    args,
                    stats,
                    raw_stats,
                    local_consecutive,
                    remote_consecutive,
                    node_balancing,
                    current_sample_pct,
                    stop_reason,
                    reenable_consecutive,
                    controller_state,
                )
                out.flush()
                if args.reenable_consecutive == 0:
                    return 0
                local_consecutive = 0
                remote_consecutive = 0

            should_reenable = (
                controller_state == "off"
                and args.reenable_consecutive > 0
                and reenable_consecutive >= args.reenable_consecutive
            )
            if should_reenable:
                if not args.dry_run:
                    knobs.write_knob("node_balancing", args.node_balancing_on)
                    if configured_sample_pct > 0:
                        knobs.write_knob(
                            "numa_local_fault_on_tiering",
                            int(configured_sample_pct),
                            required=False,
                        )
                controller_state = "on"
                node_balancing = knobs.node_balancing()
                write_event(
                    writer,
                    "on",
                    started_ms,
                    window,
                    window_seq,
                    args,
                    stats,
                    raw_stats,
                    local_consecutive,
                    remote_consecutive,
                    node_balancing,
                    current_sample_pct,
                    "reenable",
                    reenable_consecutive,
                    controller_state,
                )
                out.flush()
                local_consecutive = 0
                remote_consecutive = 0
                reenable_consecutive = 0

        write_event(
            writer,
            "exit",
            started_ms,
            window,
            0,
            args,
            WindowStats(),
            WindowStats(),
            local_consecutive,
            remote_consecutive,
            knobs.node_balancing(),
            sample_pct(args, knobs),
            "",
            reenable_consecutive,
            controller_state,
        )
        out.flush()
        return 0
    finally:
        if should_close:
            out.close()


def main(argv: Optional[Iterable[str]] = None) -> int:
    try:
        args = parse_args(argv)
        validate_args(args)
        return run_controller(args)
    except Exception as exc:  # pragma: no cover - keeps guest logs readable.
        print(f"local_util_adapt_controller: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
