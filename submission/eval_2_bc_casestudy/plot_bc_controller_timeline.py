#!/usr/bin/env python3
"""Plot BC controller migration state and per-trial promotion counts."""

from __future__ import annotations

import bisect
import csv
import os
import re
import shutil
import statistics
from dataclasses import dataclass
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.patches import Patch


REPO_ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = Path(__file__).resolve().parent
SOURCE_DIR = OUT_DIR / "source"
FIGURE_DIR = REPO_ROOT / "experiments" / "figure"
RESULTS_DIR = REPO_ROOT / "motivation/3_realworld/VM/results"

CASE_LOCAL_SIZE_GIB = 32
LOCAL_DIR = f"local{CASE_LOCAL_SIZE_GIB}"
WORKLOAD = "bc"
TIERING_CONFIG = "tiering_0x2"
CONTROLLER_CONFIG = "controller_0x2"
DEFAULT_RUN_GLOB = "*eval2-bc-promotion-local32*"


@dataclass(frozen=True)
class WorkloadTimes:
    read_s: float
    trial_times_s: list[float]
    stdout_path: Path

    @property
    def trials(self) -> int:
        return len(self.trial_times_s)

    @property
    def avg_trial_s(self) -> float:
        return sum(self.trial_times_s) / len(self.trial_times_s)

    @property
    def measured_elapsed_s(self) -> float:
        return self.read_s + sum(self.trial_times_s)


@dataclass(frozen=True)
class PromotionSample:
    elapsed_s: float
    pgpromote_success: float


@dataclass(frozen=True)
class CaseRun:
    config: str
    case_dir: Path
    times: WorkloadTimes
    promotion_csv: Path
    controller_csv: Path | None


def discover_run_root() -> Path:
    for env_name in ("BC_CASESTUDY_RUN_ROOT", "RUN_ROOT"):
        value = os.environ.get(env_name)
        if value:
            path = Path(value).expanduser().resolve()
            if path.exists():
                return path
            raise FileNotFoundError(f"{env_name}={path}")

    candidates = sorted(
        (path for path in RESULTS_DIR.glob(DEFAULT_RUN_GLOB) if path.is_dir()),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    for path in candidates:
        tiering = case_dir(path, TIERING_CONFIG) / "promotion_samples.csv"
        controller = case_dir(path, CONTROLLER_CONFIG) / "promotion_samples.csv"
        if tiering.exists() and controller.exists():
            return path
    if candidates:
        return candidates[0]
    raise FileNotFoundError(f"no run root matching {RESULTS_DIR / DEFAULT_RUN_GLOB}")


def case_dir(run_root: Path, config: str) -> Path:
    return run_root / "guest-results" / LOCAL_DIR / config / WORKLOAD


def first_existing(paths: list[Path]) -> Path:
    for path in paths:
        if path.exists() and path.stat().st_size > 0:
            return path
    for path in paths:
        if path.exists():
            return path
    raise FileNotFoundError("missing all candidate paths: " + ", ".join(map(str, paths)))


def parse_workload_times(case_path: Path, config: str) -> WorkloadTimes:
    stdout_path = first_existing(
        [
            case_path / "controller" / "stdout.txt",
            case_path / "workload.stdout.log",
        ]
        if config == CONTROLLER_CONFIG
        else [case_path / "workload.stdout.log"]
    )
    text = stdout_path.read_text(errors="replace")
    read_match = re.search(r"Read Time:\s*([0-9]+(?:\.[0-9]+)?)", text)
    trials = [
        float(match.group(1))
        for match in re.finditer(r"Trial Time:\s*([0-9]+(?:\.[0-9]+)?)", text)
    ]
    if not read_match or not trials:
        raise RuntimeError(f"could not parse Read Time/Trial Time from {stdout_path}")
    return WorkloadTimes(float(read_match.group(1)), trials, stdout_path)


def read_case(run_root: Path, config: str) -> CaseRun:
    path = case_dir(run_root, config)
    if not path.exists():
        raise FileNotFoundError(path)
    promotion_csv = path / "promotion_samples.csv"
    if not promotion_csv.exists():
        raise FileNotFoundError(promotion_csv)
    controller_csv = path / "controller" / "controller.csv"
    return CaseRun(
        config=config,
        case_dir=path,
        times=parse_workload_times(path, config),
        promotion_csv=promotion_csv,
        controller_csv=controller_csv if controller_csv.exists() else None,
    )


def trial_boundaries(times: WorkloadTimes) -> list[float]:
    boundaries = [times.read_s]
    elapsed = times.read_s
    for trial_s in times.trial_times_s:
        elapsed += trial_s
        boundaries.append(elapsed)
    return boundaries


def elapsed_to_trial_x(elapsed_s: float, times: WorkloadTimes) -> float:
    boundaries = trial_boundaries(times)
    if elapsed_s < boundaries[0]:
        return (elapsed_s - boundaries[0]) / times.trial_times_s[0]
    if elapsed_s >= boundaries[-1]:
        return len(times.trial_times_s) + (
            (elapsed_s - boundaries[-1]) / times.trial_times_s[-1]
        )
    idx = bisect.bisect_right(boundaries, elapsed_s) - 1
    idx = max(0, min(idx, len(times.trial_times_s) - 1))
    return idx + ((elapsed_s - boundaries[idx]) / times.trial_times_s[idx])


def read_controller_events(case: CaseRun) -> list[dict[str, str]]:
    if case.controller_csv is None:
        raise FileNotFoundError("controller.csv missing")
    with case.controller_csv.open(newline="") as file:
        rows = list(csv.DictReader(file))
    for row in rows:
        elapsed_s = float(row["elapsed_ms"]) / 1000.0
        row["elapsed_s"] = f"{elapsed_s:.6f}"
        row["trial_x"] = f"{elapsed_to_trial_x(elapsed_s, case.times):.6f}"
    return rows


def read_promotion_samples(path: Path) -> list[PromotionSample]:
    samples: list[PromotionSample] = []
    with path.open(newline="") as file:
        for row in csv.DictReader(file):
            try:
                samples.append(
                    PromotionSample(
                        elapsed_s=float(row["elapsed_s"]),
                        pgpromote_success=float(row["pgpromote_success"]),
                    )
                )
            except (KeyError, ValueError):
                continue
    samples.sort(key=lambda sample: sample.elapsed_s)
    if len(samples) < 2:
        raise RuntimeError(f"not enough promotion samples in {path}")
    return samples


def sample_interval_label(cases: list[CaseRun]) -> str:
    deltas: list[float] = []
    for case in cases:
        samples = read_promotion_samples(case.promotion_csv)
        for before, after in zip(samples, samples[1:]):
            delta = after.elapsed_s - before.elapsed_s
            if delta > 0:
                deltas.append(delta)
    if not deltas:
        return "periodic"
    interval = statistics.median(deltas)
    if interval >= 1.0:
        return f"{interval:.0f}s"
    return f"{interval:.3f}s"


def interpolate_counter(samples: list[PromotionSample], elapsed_s: float) -> float:
    times = [sample.elapsed_s for sample in samples]
    idx = bisect.bisect_left(times, elapsed_s)
    if idx <= 0:
        return samples[0].pgpromote_success
    if idx >= len(samples):
        return samples[-1].pgpromote_success
    before = samples[idx - 1]
    after = samples[idx]
    if after.elapsed_s == before.elapsed_s:
        return after.pgpromote_success
    ratio = (elapsed_s - before.elapsed_s) / (after.elapsed_s - before.elapsed_s)
    return before.pgpromote_success + ratio * (
        after.pgpromote_success - before.pgpromote_success
    )


def promotion_by_trial(case: CaseRun) -> list[dict[str, object]]:
    samples = read_promotion_samples(case.promotion_csv)
    boundaries = trial_boundaries(case.times)
    rows: list[dict[str, object]] = []
    for trial_idx in range(case.times.trials):
        start_s = boundaries[trial_idx]
        end_s = boundaries[trial_idx + 1]
        start_counter = interpolate_counter(samples, start_s)
        end_counter = interpolate_counter(samples, end_s)
        promoted_pages = max(0.0, end_counter - start_counter)
        rows.append(
            {
                "config": case.config,
                "trial": trial_idx + 1,
                "trial_start_s": start_s,
                "trial_end_s": end_s,
                "trial_time_s": case.times.trial_times_s[trial_idx],
                "pgpromote_success_start_interp": start_counter,
                "pgpromote_success_end_interp": end_counter,
                "promoted_pages_interp": promoted_pages,
                "promoted_mpages": promoted_pages / 1_000_000.0,
            }
        )
    return rows


def state_segments(
    events: list[dict[str, str]], times: WorkloadTimes
) -> list[tuple[float, float, str]]:
    changes: list[tuple[float, str, str]] = []
    for row in events:
        event = row["event"]
        if event in {"start", "off", "restart", "exit"}:
            changes.append((float(row["trial_x"]), row["controller_state"], event))

    if not changes:
        raise RuntimeError("No controller state changes found")

    x_min = elapsed_to_trial_x(0.0, times)
    x_max = times.trials
    segments: list[tuple[float, float, str]] = []
    for idx, (x_start, state, event) in enumerate(changes):
        start = x_min if event == "start" else x_start
        if idx + 1 < len(changes):
            end = changes[idx + 1][0]
        else:
            end = x_max
        start = max(x_min, min(x_max, start))
        end = max(x_min, min(x_max, end))
        if end > start:
            segments.append((start, end, state))
    return segments


def write_event_csv(events: list[dict[str, str]], path: Path) -> None:
    fieldnames = [
        "event",
        "elapsed_s",
        "trial_x",
        "window",
        "controller_state",
        "numa_balancing",
        "decision",
        "stop_reason",
        "restart_decision",
        "restart_ratio",
    ]
    with path.open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fieldnames)
        writer.writeheader()
        for row in events:
            if row["event"] not in {"start", "off", "restart", "exit"}:
                continue
            writer.writerow({field: row.get(field, "") for field in fieldnames})


def write_boundaries_csv(cases: list[CaseRun], path: Path) -> None:
    fieldnames = ["config", "boundary", "elapsed_s", "trial_x"]
    with path.open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fieldnames)
        writer.writeheader()
        for case in cases:
            for idx, boundary in enumerate(trial_boundaries(case.times)):
                writer.writerow(
                    {
                        "config": case.config,
                        "boundary": idx,
                        "elapsed_s": f"{boundary:.6f}",
                        "trial_x": f"{idx:.6f}",
                    }
                )


def write_promotions_csv(rows: list[dict[str, object]], path: Path) -> None:
    fieldnames = [
        "config",
        "trial",
        "trial_start_s",
        "trial_end_s",
        "trial_time_s",
        "pgpromote_success_start_interp",
        "pgpromote_success_end_interp",
        "promoted_pages_interp",
        "promoted_mpages",
    ]
    with path.open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(
                {
                    field: (
                        f"{row[field]:.6f}"
                        if isinstance(row[field], float)
                        else row[field]
                    )
                    for field in fieldnames
                }
            )


def plot(
    tiering: CaseRun,
    controller: CaseRun,
    events: list[dict[str, str]],
    promotion_rows: list[dict[str, object]],
    output_base: Path,
) -> None:
    x_min = elapsed_to_trial_x(0.0, controller.times)
    x_max = controller.times.trials
    segments = state_segments(events, controller.times)
    off_events = [row for row in events if row["event"] == "off"]
    restart_events = [row for row in events if row["event"] == "restart"]

    fig, (ax_state, ax_promo) = plt.subplots(
        2,
        1,
        figsize=(10.2, 5.9),
        gridspec_kw={"height_ratios": [1.0, 1.45], "hspace": 0.16},
        sharex=True,
    )
    fig.subplots_adjust(left=0.13, right=0.985, top=0.86, bottom=0.13)

    ax_state.set_xlim(x_min, x_max)
    ax_state.set_ylim(0, 2.4)
    ax_state.axvspan(x_min, 0, color="#eeeeee", alpha=0.9, zorder=0)
    ax_state.text(
        (x_min + 0) / 2,
        2.17,
        f"read phase\n{controller.times.read_s:.1f}s",
        ha="center",
        va="top",
        fontsize=8,
        color="#555555",
    )

    for trial in range(0, controller.times.trials + 1):
        for ax in (ax_state, ax_promo):
            ax.axvline(trial, color="#d0d5dd", linewidth=0.8, linestyle=":", zorder=0)
        if trial < controller.times.trials:
            ax_state.text(
                trial + 0.5,
                0.05,
                f"T{trial + 1}",
                ha="center",
                va="bottom",
                fontsize=8,
            )

    ax_state.broken_barh(
        [(x_min, x_max - x_min)],
        (1.48, 0.42),
        facecolors="#4C78A8",
        edgecolors="white",
        linewidth=0.6,
    )
    ax_state.text(x_min - 0.06, 1.69, "memory tiering", ha="right", va="center", fontsize=9)

    state_color = {"on": "#2A9D55", "off": "#E45756"}
    for start, end, state in segments:
        ax_state.broken_barh(
            [(start, end - start)],
            (0.82, 0.42),
            facecolors=state_color.get(state, "#9CA3AF"),
            edgecolors="white",
            linewidth=0.6,
        )
    ax_state.text(
        x_min - 0.06,
        1.03,
        "migration-gatekeeper",
        ha="right",
        va="center",
        fontsize=9,
    )

    off_x = [float(row["trial_x"]) for row in off_events]
    restart_x = [float(row["trial_x"]) for row in restart_events]
    ax_state.scatter(off_x, [1.03] * len(off_x), marker="v", s=36, color="#9F1239", zorder=4)
    ax_state.scatter(
        restart_x, [1.03] * len(restart_x), marker="^", s=36, color="#065F46", zorder=4
    )
    ax_state.set_yticks([])

    by_config: dict[str, list[dict[str, object]]] = {TIERING_CONFIG: [], CONTROLLER_CONFIG: []}
    for row in promotion_rows:
        by_config[str(row["config"])].append(row)

    trial_centers = [float(idx) + 0.5 for idx in range(controller.times.trials)]
    tiering_y = [float(row["promoted_mpages"]) for row in by_config[TIERING_CONFIG]]
    controller_y = [float(row["promoted_mpages"]) for row in by_config[CONTROLLER_CONFIG]]
    ax_promo.plot(
        trial_centers,
        tiering_y,
        color="#4C78A8",
        linewidth=1.8,
        marker="o",
        markersize=4.2,
        label="memory tiering",
    )
    ax_promo.plot(
        trial_centers,
        controller_y,
        color="#E45756",
        linewidth=1.8,
        marker="o",
        markersize=4.2,
        label="migration-gatekeeper",
    )
    ax_promo.set_ylabel("Promoted pages (million)")
    ax_promo.set_xlabel("BC trial timeline (0 = trial 1 start, 8 = trial 8 end)")
    ax_promo.set_xticks(range(0, controller.times.trials + 1))
    ax_promo.grid(axis="y", color="#e5e7eb", linewidth=0.8)
    ax_promo.legend(loc="upper right", frameon=False, fontsize=8)

    fig.suptitle(
        "BC local32GiB: migration state and per-trial promotions",
        fontsize=11,
        y=0.965,
    )
    fig.text(
        0.13,
        0.035,
        (
            "Event positions use exact Read Time and per-trial Trial Time from the run. "
            f"Promotion counts use {sample_interval_label([tiering, controller])} "
            "vmstat pgpromote_success samples, "
            "linearly interpolated at trial boundaries."
        ),
        fontsize=8,
        color="#4b5563",
    )

    handles = [
        Patch(facecolor="#4C78A8", edgecolor="white", label="migration active"),
        Patch(facecolor="#2A9D55", edgecolor="white", label="controller on"),
        Patch(facecolor="#E45756", edgecolor="white", label="controller off"),
        Line2D([0], [0], marker="v", color="none", markerfacecolor="#9F1239", label="off event"),
        Line2D([0], [0], marker="^", color="none", markerfacecolor="#065F46", label="restart event"),
    ]
    fig.legend(
        handles=handles,
        loc="upper center",
        bbox_to_anchor=(0.5, 0.925),
        ncol=5,
        frameon=False,
        fontsize=8,
    )

    for suffix in [".pdf", ".svg", ".png"]:
        fig.savefig(output_base.with_suffix(suffix), bbox_inches="tight")
    plt.close(fig)


def copy_case_sources(case: CaseRun) -> None:
    prefix = f"bc_local{CASE_LOCAL_SIZE_GIB}_{case.config}"
    shutil.copy2(case.promotion_csv, SOURCE_DIR / f"{prefix}_promotion_samples.csv")
    shutil.copy2(case.times.stdout_path, SOURCE_DIR / f"{prefix}_{case.times.stdout_path.name}")
    for name in ["run.config", "status.txt", "time.txt"]:
        path = case.case_dir / name
        if path.exists():
            shutil.copy2(path, SOURCE_DIR / f"{prefix}_{name}")
    if case.controller_csv and case.controller_csv.exists():
        shutil.copy2(case.controller_csv, SOURCE_DIR / f"{prefix}_controller.csv")


def copy_to_figure_dir(output_base: Path) -> None:
    FIGURE_DIR.mkdir(parents=True, exist_ok=True)
    for suffix in [".pdf", ".svg", ".png"]:
        shutil.copy2(
            output_base.with_suffix(suffix),
            FIGURE_DIR / f"submission_eval_2_bc_controller_promotion_timeline{suffix}",
        )


def write_readme(run_root: Path, tiering: CaseRun, controller: CaseRun) -> None:
    interval = sample_interval_label([tiering, controller])
    text = f"""# BC Case Study

This directory contains the local32GiB BC case-study figure for memory tiering
and migration-gatekeeper.

Run root:

`{run_root}`

Inputs:

- Workload: GAPBS BC, prebuilt graph, `{WORKLOAD}`.
- VM local memory: {CASE_LOCAL_SIZE_GIB} GiB.
- Policies: `{TIERING_CONFIG}` and `{CONTROLLER_CONFIG}`.
- Promotion metric: `/proc/vmstat` `pgpromote_success`, sampled every {interval} during
  the workload and linearly interpolated at BC trial boundaries.

Timing sources:

- `{tiering.times.stdout_path}`
- `{controller.times.stdout_path}`
- `{controller.controller_csv}`

Artifacts:

- `bc_controller_promotion_timeline.pdf`: migration state plus per-trial
  promotion counts.
- `bc_controller_migration_events.csv`: controller off/restart positions
  recalculated with exact trial boundaries.
- `bc_trial_promotions.csv`: per-trial promotion counts.
- `bc_trial_boundaries.csv`: Read Time plus cumulative trial boundaries.
"""
    (OUT_DIR / "README.md").write_text(text)


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    run_root = discover_run_root()
    tiering = read_case(run_root, TIERING_CONFIG)
    controller = read_case(run_root, CONTROLLER_CONFIG)
    events = read_controller_events(controller)
    promotion_rows = promotion_by_trial(tiering) + promotion_by_trial(controller)

    write_event_csv(events, OUT_DIR / "bc_controller_migration_events.csv")
    write_promotions_csv(promotion_rows, OUT_DIR / "bc_trial_promotions.csv")
    write_boundaries_csv([tiering, controller], OUT_DIR / "bc_trial_boundaries.csv")

    output_base = OUT_DIR / "bc_controller_promotion_timeline"
    plot(tiering, controller, events, promotion_rows, output_base)

    copy_case_sources(tiering)
    copy_case_sources(controller)
    copy_to_figure_dir(output_base)
    write_readme(run_root, tiering, controller)


if __name__ == "__main__":
    main()
