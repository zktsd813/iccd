#!/usr/bin/env python3
"""Fault-latency bucket controller for global NUMA balancing.

The controller is intentionally userspace-only. It advances the kernel fault
latency window, reads the current local/remote histograms, and disables global
NUMA balancing when the configured bucket policy says migration is no longer
helping.
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
from typing import Iterable, Optional, TextIO


BUCKET_LABELS = (
    "<=128",
    "<=256",
    "<=512",
    "<=1024",
    "<=2048",
    "<=4096",
    "<=8192",
    ">8192",
)

SERIES_KEYS = ("local_pages", "remote_pages")


@dataclass
class Histogram:
    window_seq: int
    local_pages: list[int]
    remote_pages: list[int]


@dataclass
class Decision:
    valid: bool
    decision: str
    stop_reason: str
    gap: Optional[int]
    effective_count: int
    no_improve_count: int


@dataclass
class RestartObservation:
    armed: bool
    valid: bool
    decision: str
    stop_remote_p20_index: Optional[int]
    compare_bucket_index: Optional[int]
    baseline_share: Optional[float]
    current_share: Optional[float]
    ratio: Optional[float]
    consecutive_count: int
    restart: bool


class DecisionState:
    def __init__(self, consecutive_effective: int, consecutive_no_improve: int):
        self.consecutive_effective = consecutive_effective
        self.consecutive_no_improve = consecutive_no_improve
        self.effective_count = 0
        self.no_improve_count = 0
        self.previous_need_gap: Optional[int] = None

    def reset(self) -> None:
        self.effective_count = 0
        self.no_improve_count = 0
        self.previous_need_gap = None

    def evaluate(
        self,
        *,
        local_total: int,
        remote_total: int,
        local_p80_index: int,
        remote_p20_index: int,
        min_local_pages: int,
        min_remote_pages: int,
    ) -> Decision:
        if (
            local_total < min_local_pages
            or remote_total < min_remote_pages
            or local_p80_index < 0
            or remote_p20_index < 0
        ):
            self.reset()
            return Decision(
                valid=False,
                decision="invalid_skip",
                stop_reason="",
                gap=None,
                effective_count=self.effective_count,
                no_improve_count=self.no_improve_count,
            )

        gap = local_p80_index - remote_p20_index
        if local_p80_index < remote_p20_index:
            self.effective_count += 1
            self.no_improve_count = 0
            self.previous_need_gap = None
            stop_reason = (
                "effective"
                if self.effective_count >= self.consecutive_effective
                else ""
            )
            return Decision(
                valid=True,
                decision="effective" if not stop_reason else "stop_effective",
                stop_reason=stop_reason,
                gap=gap,
                effective_count=self.effective_count,
                no_improve_count=self.no_improve_count,
            )

        self.effective_count = 0
        if self.previous_need_gap is None:
            self.no_improve_count = 0
            decision = "need_baseline"
        elif gap < self.previous_need_gap:
            self.no_improve_count = 0
            decision = "improving"
        else:
            self.no_improve_count += 1
            decision = "no_improve"

        self.previous_need_gap = gap
        stop_reason = (
            "no_improve"
            if self.no_improve_count >= self.consecutive_no_improve
            else ""
        )
        return Decision(
            valid=True,
            decision=decision if not stop_reason else "stop_no_improve",
            stop_reason=stop_reason,
            gap=gap,
            effective_count=self.effective_count,
            no_improve_count=self.no_improve_count,
        )


class RestartState:
    def __init__(self, threshold: float, consecutive_windows: int):
        self.threshold = threshold
        self.consecutive_windows = consecutive_windows
        self.stop_remote_p20_index: Optional[int] = None
        self.compare_bucket_index: Optional[int] = None
        self.baseline_share: Optional[float] = None
        self.consecutive_count = 0

    def reset(self) -> None:
        self.stop_remote_p20_index = None
        self.compare_bucket_index = None
        self.baseline_share = None
        self.consecutive_count = 0

    def snapshot(self) -> RestartObservation:
        return self._observation(
            valid=False,
            decision="",
            current_share=None,
            ratio=None,
            restart=False,
        )

    def arm(self, remote_pages: list[int], remote_p20_index: int) -> RestartObservation:
        self.reset()
        if not remote_pages or remote_p20_index < 0:
            return self._observation(
                valid=False,
                decision="restart_disarmed",
                current_share=None,
                ratio=None,
                restart=False,
            )

        last_index = len(remote_pages) - 1
        compare_index = min(remote_p20_index, max(0, last_index - 1))
        baseline = prefix_share(remote_pages, compare_index)
        if baseline is None:
            return self._observation(
                valid=False,
                decision="restart_disarmed",
                current_share=None,
                ratio=None,
                restart=False,
            )

        self.stop_remote_p20_index = remote_p20_index
        self.compare_bucket_index = compare_index
        self.baseline_share = baseline
        return self._observation(
            valid=True,
            decision="restart_armed",
            current_share=baseline,
            ratio=1.0 if baseline > 0 else None,
            restart=False,
        )

    def observe(self, remote_pages: list[int], min_remote_pages: int) -> RestartObservation:
        if self.compare_bucket_index is None or self.baseline_share is None:
            return self._observation(
                valid=False,
                decision="restart_not_armed",
                current_share=None,
                ratio=None,
                restart=False,
            )

        if sum(remote_pages) < min_remote_pages:
            self.consecutive_count = 0
            return self._observation(
                valid=False,
                decision="restart_invalid",
                current_share=None,
                ratio=None,
                restart=False,
            )

        current = prefix_share(remote_pages, self.compare_bucket_index)
        if current is None or self.baseline_share <= 0:
            self.consecutive_count = 0
            return self._observation(
                valid=False,
                decision="restart_invalid",
                current_share=current,
                ratio=None,
                restart=False,
            )

        ratio = current / self.baseline_share
        if ratio >= self.threshold:
            self.consecutive_count += 1
            restart = self.consecutive_count >= self.consecutive_windows
            return self._observation(
                valid=True,
                decision="restart_remote_share" if restart else "restart_candidate",
                current_share=current,
                ratio=ratio,
                restart=restart,
            )

        self.consecutive_count = 0
        return self._observation(
            valid=True,
            decision="restart_wait",
            current_share=current,
            ratio=ratio,
            restart=False,
        )

    def _observation(
        self,
        *,
        valid: bool,
        decision: str,
        current_share: Optional[float],
        ratio: Optional[float],
        restart: bool,
    ) -> RestartObservation:
        return RestartObservation(
            armed=self.compare_bucket_index is not None and self.baseline_share is not None,
            valid=valid,
            decision=decision,
            stop_remote_p20_index=self.stop_remote_p20_index,
            compare_bucket_index=self.compare_bucket_index,
            baseline_share=self.baseline_share,
            current_share=current_share,
            ratio=ratio,
            consecutive_count=self.consecutive_count,
            restart=restart,
        )


def monitor_decision(
    *,
    state: DecisionState,
    local_total: int,
    remote_total: int,
    local_p80_index: int,
    remote_p20_index: int,
    min_local_pages: int,
    min_remote_pages: int,
    decision_name: str = "monitor_off",
    invalid_decision_name: str = "invalid_skip_off",
) -> Decision:
    valid = (
        local_total >= min_local_pages
        and remote_total >= min_remote_pages
        and local_p80_index >= 0
        and remote_p20_index >= 0
    )
    gap = local_p80_index - remote_p20_index if valid else None
    return Decision(
        valid=valid,
        decision=decision_name if valid else invalid_decision_name,
        stop_reason="",
        gap=gap,
        effective_count=state.effective_count,
        no_improve_count=state.no_improve_count,
    )


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def monotonic_ms() -> int:
    return int(time.monotonic() * 1000)


def read_text(path: Path, default: str = "") -> str:
    try:
        return path.read_text(encoding="ascii", errors="replace")
    except OSError:
        return default


def write_text(path: Path, value: object, *, dry_run: bool = False) -> None:
    if dry_run:
        return
    path.write_text(f"{value}\n", encoding="ascii")


def parse_histogram_text(text: str) -> Histogram:
    values = {
        "local_pages": [0] * len(BUCKET_LABELS),
        "remote_pages": [0] * len(BUCKET_LABELS),
    }
    window_seq = 0

    for line in text.splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "window_seq" and len(parts) >= 2:
            try:
                window_seq = int(parts[1])
            except ValueError:
                window_seq = 0
            continue
        if parts[0] not in SERIES_KEYS:
            continue
        parsed = []
        for value in parts[1 : 1 + len(BUCKET_LABELS)]:
            try:
                parsed.append(int(value))
            except ValueError:
                parsed.append(0)
        if len(parsed) < len(BUCKET_LABELS):
            parsed.extend([0] * (len(BUCKET_LABELS) - len(parsed)))
        values[parts[0]] = parsed

    return Histogram(
        window_seq=window_seq,
        local_pages=values["local_pages"],
        remote_pages=values["remote_pages"],
    )


def read_histogram(path: Path) -> Histogram:
    return parse_histogram_text(read_text(path))


def percentile_bucket(values: list[int], percentile: int) -> tuple[int, str]:
    total = sum(values)
    if total <= 0:
        return -1, "NA"
    threshold = total * percentile / 100.0
    cumulative = 0
    for index, value in enumerate(values):
        cumulative += value
        if cumulative >= threshold:
            return index, BUCKET_LABELS[index]
    return len(values) - 1, BUCKET_LABELS[-1]


def prefix_share(values: list[int], end_index: int) -> Optional[float]:
    total = sum(values)
    if total <= 0 or end_index < 0:
        return None
    clamped = min(end_index, len(values) - 1)
    return sum(values[: clamped + 1]) / total


def sleep_interruptible(seconds: float, stop_file: Optional[Path], stop_flag: dict) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if stop_flag["stop"]:
            return False
        if stop_file is not None and stop_file.exists():
            return False
        remaining = deadline - time.monotonic()
        time.sleep(min(0.2, max(0.0, remaining)))
    return not stop_flag["stop"]


def open_output(path: Optional[Path]) -> tuple[TextIO, bool]:
    if path is None:
        return sys.stdout, False
    path.parent.mkdir(parents=True, exist_ok=True)
    return path.open("w", encoding="ascii", newline=""), True


def write_window_files(
    *,
    hist_dir: Optional[Path],
    window: int,
    elapsed_ms: int,
    histogram_text: str,
    histogram: Histogram,
    node_balancing: str,
) -> str:
    if hist_dir is None:
        return ""

    hist_dir.mkdir(parents=True, exist_ok=True)
    label = f"window_{window:04d}"
    hist_path = hist_dir / f"{label}.fault_latency_histograms"
    hist_path.write_text(histogram_text, encoding="ascii")
    (hist_dir / f"{label}.meta").write_text(
        "\n".join(
            (
                f"window_index={window}",
                f"elapsed_ms={elapsed_ms}",
                f"date_utc={now_iso()}",
                f"numa_balancing={node_balancing}",
                f"local_fault_window_seq={histogram.window_seq}",
            )
        )
        + "\n",
        encoding="ascii",
    )
    vmstat = read_text(Path("/proc/vmstat"))
    if vmstat:
        (hist_dir / f"{label}.vmstat").write_text(vmstat, encoding="ascii")
    return str(hist_path)


def read_knob(path: Path) -> str:
    return read_text(path).strip()


def require_path(path: Path, mode: str) -> None:
    if not path.exists():
        raise FileNotFoundError(f"missing path: {path}")
    if "r" in mode and not os.access(path, os.R_OK):
        raise PermissionError(f"path is not readable: {path}")
    if "w" in mode and not os.access(path, os.W_OK):
        raise PermissionError(f"path is not writable: {path}")


def run_controller(args: argparse.Namespace) -> int:
    sysfs_dir = args.sysfs_numa_dir
    hist_path = sysfs_dir / "fault_latency_histograms"
    window_path = sysfs_dir / "local_fault_window"
    local_rate_path = sysfs_dir / "local_fault_rate"
    remote_rate_path = sysfs_dir / "remote_fault_rate"
    numa_balancing_path = args.numa_balancing_path

    if args.require_knobs:
        for path in (hist_path, window_path, local_rate_path, remote_rate_path):
            require_path(path, "rw" if path != hist_path else "r")
        require_path(numa_balancing_path, "rw")

    stop_flag = {"stop": False}

    def handle_signal(signum, frame):  # noqa: ARG001
        stop_flag["stop"] = True

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    if args.hist_dir is not None:
        args.hist_dir.mkdir(parents=True, exist_ok=True)
        (args.hist_dir / "monitor.meta").write_text(
            "\n".join(
                (
                    f"interval_s={args.window_sec}",
                    f"local_rate={args.local_rate}",
                    f"remote_rate={args.remote_rate}",
                    f"min_local_pages={args.min_local_pages}",
                    f"min_remote_pages={args.min_remote_pages}",
                    f"consecutive_effective={args.consecutive_effective}",
                    f"consecutive_no_improve={args.consecutive_no_improve}",
                    f"restart_remote_share_threshold={args.restart_remote_share_threshold}",
                    f"consecutive_restart={args.consecutive_restart}",
                    f"restart_grace_windows={args.restart_grace_windows}",
                )
            )
            + "\n",
            encoding="ascii",
        )

    if not args.no_set_initial_on:
        write_text(numa_balancing_path, args.node_balancing_on, dry_run=args.dry_run)
    write_text(local_rate_path, args.local_rate, dry_run=args.dry_run)
    write_text(remote_rate_path, args.remote_rate, dry_run=args.dry_run)

    out, should_close = open_output(args.output)
    fields = (
        "event",
        "timestamp",
        "elapsed_ms",
        "window",
        "window_seq",
        "window_sec",
        "controller_state",
        "numa_balancing",
        "local_rate",
        "remote_rate",
        "local_total_pages",
        "remote_total_pages",
        "local_p80_bucket_index",
        "local_p80_bucket",
        "remote_p20_bucket_index",
        "remote_p20_bucket",
        "gap",
        "valid",
        "decision",
        "effective_consecutive",
        "no_improve_consecutive",
        "stop_reason",
        "restart_decision",
        "restart_armed",
        "restart_valid",
        "restart_stop_remote_p20_bucket_index",
        "restart_compare_bucket_index",
        "restart_baseline_share",
        "restart_current_share",
        "restart_ratio",
        "restart_consecutive",
        "restart_threshold",
        "restart_grace_remaining",
        "histogram_path",
    )
    writer = csv.DictWriter(out, fieldnames=fields)
    writer.writeheader()

    state = DecisionState(
        args.consecutive_effective,
        args.consecutive_no_improve,
    )
    restart_state = RestartState(
        args.restart_remote_share_threshold,
        args.consecutive_restart,
    )
    started_ms = monotonic_ms()
    controller_state = "on"
    restart_grace_remaining = 0
    window = 0

    def format_float(value: Optional[float]) -> str:
        if value is None:
            return ""
        return f"{value:.6f}"

    def emit(
        event: str,
        decision: Decision,
        histogram: Histogram,
        hist_file: str,
        restart: Optional[RestartObservation] = None,
    ) -> None:
        local_p80_index, local_p80_label = percentile_bucket(histogram.local_pages, 80)
        remote_p20_index, remote_p20_label = percentile_bucket(histogram.remote_pages, 20)
        if restart is None:
            restart = restart_state.snapshot()
        writer.writerow(
            {
                "event": event,
                "timestamp": now_iso(),
                "elapsed_ms": monotonic_ms() - started_ms,
                "window": window,
                "window_seq": histogram.window_seq,
                "window_sec": f"{args.window_sec:.3f}",
                "controller_state": controller_state,
                "numa_balancing": read_knob(numa_balancing_path),
                "local_rate": read_knob(local_rate_path),
                "remote_rate": read_knob(remote_rate_path),
                "local_total_pages": sum(histogram.local_pages),
                "remote_total_pages": sum(histogram.remote_pages),
                "local_p80_bucket_index": local_p80_index,
                "local_p80_bucket": local_p80_label,
                "remote_p20_bucket_index": remote_p20_index,
                "remote_p20_bucket": remote_p20_label,
                "gap": "" if decision.gap is None else decision.gap,
                "valid": int(decision.valid),
                "decision": decision.decision,
                "effective_consecutive": decision.effective_count,
                "no_improve_consecutive": decision.no_improve_count,
                "stop_reason": decision.stop_reason,
                "restart_decision": restart.decision,
                "restart_armed": int(restart.armed),
                "restart_valid": int(restart.valid),
                "restart_stop_remote_p20_bucket_index": (
                    "" if restart.stop_remote_p20_index is None else restart.stop_remote_p20_index
                ),
                "restart_compare_bucket_index": (
                    "" if restart.compare_bucket_index is None else restart.compare_bucket_index
                ),
                "restart_baseline_share": format_float(restart.baseline_share),
                "restart_current_share": format_float(restart.current_share),
                "restart_ratio": format_float(restart.ratio),
                "restart_consecutive": restart.consecutive_count,
                "restart_threshold": f"{restart_state.threshold:.6f}",
                "restart_grace_remaining": restart_grace_remaining,
                "histogram_path": hist_file,
            }
        )
        out.flush()

    try:
        empty = Histogram(0, [0] * len(BUCKET_LABELS), [0] * len(BUCKET_LABELS))
        emit("start", Decision(False, "start", "", None, 0, 0), empty, "")

        while not stop_flag["stop"]:
            if args.stop_file is not None and args.stop_file.exists():
                break
            if args.max_windows and window >= args.max_windows:
                break

            window += 1
            if not args.no_advance_window:
                write_text(window_path, 1, dry_run=args.dry_run)

            if not sleep_interruptible(args.window_sec, args.stop_file, stop_flag):
                break

            hist_text = read_text(hist_path)
            histogram = parse_histogram_text(hist_text)
            local_p80_index, _ = percentile_bucket(histogram.local_pages, 80)
            remote_p20_index, _ = percentile_bucket(histogram.remote_pages, 20)
            restart_observation: Optional[RestartObservation] = None
            if controller_state == "off":
                decision = monitor_decision(
                    state=state,
                    local_total=sum(histogram.local_pages),
                    remote_total=sum(histogram.remote_pages),
                    local_p80_index=local_p80_index,
                    remote_p20_index=remote_p20_index,
                    min_local_pages=args.min_local_pages,
                    min_remote_pages=args.min_remote_pages,
                )
                restart_observation = restart_state.observe(
                    histogram.remote_pages,
                    args.min_remote_pages,
                )
            elif restart_grace_remaining > 0:
                decision = monitor_decision(
                    state=state,
                    local_total=sum(histogram.local_pages),
                    remote_total=sum(histogram.remote_pages),
                    local_p80_index=local_p80_index,
                    remote_p20_index=remote_p20_index,
                    min_local_pages=args.min_local_pages,
                    min_remote_pages=args.min_remote_pages,
                    decision_name="restart_grace",
                    invalid_decision_name="invalid_restart_grace",
                )
            else:
                decision = state.evaluate(
                    local_total=sum(histogram.local_pages),
                    remote_total=sum(histogram.remote_pages),
                    local_p80_index=local_p80_index,
                    remote_p20_index=remote_p20_index,
                    min_local_pages=args.min_local_pages,
                    min_remote_pages=args.min_remote_pages,
                )
            hist_file = write_window_files(
                hist_dir=args.hist_dir,
                window=window,
                elapsed_ms=monotonic_ms() - started_ms,
                histogram_text=hist_text,
                histogram=histogram,
                node_balancing=read_knob(numa_balancing_path),
            )

            event = "sample"
            if controller_state == "on" and decision.stop_reason:
                restart_observation = restart_state.arm(
                    histogram.remote_pages,
                    remote_p20_index,
                )
                if not args.dry_run:
                    write_text(numa_balancing_path, args.node_balancing_off)
                    write_text(local_rate_path, args.local_rate)
                    write_text(remote_rate_path, args.remote_rate)
                controller_state = "off"
                event = "off"
            elif controller_state == "off" and restart_observation and restart_observation.restart:
                if not args.dry_run:
                    write_text(numa_balancing_path, args.node_balancing_on)
                    write_text(local_rate_path, args.local_rate)
                    write_text(remote_rate_path, args.remote_rate)
                state.reset()
                restart_state.reset()
                controller_state = "on"
                restart_grace_remaining = args.restart_grace_windows
                decision = Decision(
                    valid=decision.valid,
                    decision="restart_remote_share",
                    stop_reason="",
                    gap=decision.gap,
                    effective_count=state.effective_count,
                    no_improve_count=state.no_improve_count,
                )
                event = "restart"

            emit(event, decision, histogram, hist_file, restart_observation)
            if controller_state == "on" and decision.decision in (
                "restart_grace",
                "invalid_restart_grace",
            ):
                restart_grace_remaining = max(0, restart_grace_remaining - 1)

        emit(
            "exit",
            Decision(False, "exit", "", None, state.effective_count, state.no_improve_count),
            Histogram(0, [0] * len(BUCKET_LABELS), [0] * len(BUCKET_LABELS)),
            "",
        )
        return 0
    finally:
        if should_close:
            out.close()


def parse_args(argv: Optional[Iterable[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Control global NUMA balancing using local P80 and remote P20 latency buckets."
    )
    parser.add_argument("--window-sec", type=float, default=5.0)
    parser.add_argument("--local-rate", type=int, default=5)
    parser.add_argument("--remote-rate", type=int, default=5)
    parser.add_argument("--consecutive-effective", type=int, default=2)
    parser.add_argument("--consecutive-no-improve", type=int, default=2)
    parser.add_argument("--restart-remote-share-threshold", type=float, default=1.2)
    parser.add_argument("--consecutive-restart", type=int, default=2)
    parser.add_argument("--restart-grace-windows", type=int, default=1)
    parser.add_argument("--min-local-pages", type=int, default=1024)
    parser.add_argument("--min-remote-pages", type=int, default=1024)
    parser.add_argument("--node-balancing-on", type=int, default=2)
    parser.add_argument("--node-balancing-off", type=int, default=0)
    parser.add_argument("--sysfs-numa-dir", type=Path, default=Path("/sys/kernel/mm/numa_balancing"))
    parser.add_argument("--numa-balancing-path", type=Path, default=Path("/proc/sys/kernel/numa_balancing"))
    parser.add_argument("--stop-file", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--hist-dir", type=Path)
    parser.add_argument("--max-windows", type=int, default=0)
    parser.add_argument("--no-set-initial-on", action="store_true")
    parser.add_argument("--no-advance-window", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--no-require-knobs", dest="require_knobs", action="store_false")
    parser.set_defaults(require_knobs=True)
    args = parser.parse_args(argv)

    if args.window_sec <= 0:
        parser.error("--window-sec must be positive")
    if not 0 <= args.local_rate <= 100:
        parser.error("--local-rate must be in [0, 100]")
    if not 0 <= args.remote_rate <= 100:
        parser.error("--remote-rate must be in [0, 100]")
    if args.consecutive_effective < 1:
        parser.error("--consecutive-effective must be >= 1")
    if args.consecutive_no_improve < 1:
        parser.error("--consecutive-no-improve must be >= 1")
    if args.restart_remote_share_threshold <= 1.0:
        parser.error("--restart-remote-share-threshold must be > 1.0")
    if args.consecutive_restart < 1:
        parser.error("--consecutive-restart must be >= 1")
    if args.restart_grace_windows < 0:
        parser.error("--restart-grace-windows must be >= 0")
    if args.min_local_pages < 0 or args.min_remote_pages < 0:
        parser.error("minimum page counts must be non-negative")
    return args


def main(argv: Optional[Iterable[str]] = None) -> int:
    try:
        return run_controller(parse_args(argv))
    except Exception as exc:  # noqa: BLE001
        print(f"bucket_latency_controller: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
