#!/usr/bin/env python3
import csv
from pathlib import Path

ROOT = Path("/Serverless/iccd/experiments/20260520-gapbs-toggle-ours-window-sweep")
IN_CSV = ROOT / "summaries" / "gapbs_toggle_ours_window_sweep_summary.csv"
OUT_MD = ROOT / "summaries" / "gapbs_toggle_ours_window_sweep_summary.md"


def sec(ms):
    if not ms:
        return ""
    return f"{float(ms) / 1000.0:.3f}"


def main():
    rows = list(csv.DictReader(IN_CSV.open()))
    rows.sort(key=lambda r: (r["workload"], r["cap"], int(r["window_sec"])))
    by_workload = {}
    for row in rows:
        by_workload.setdefault(row["workload"], []).append(row)

    lines = [
        "# GAPBS toggle ours window sweep",
        "",
        "- Workload graph: `/root/gapbs_graphs/kron_g28.sg` loaded with `-f`.",
        "- Workloads: PR `/root/pr -f ... -i20 -t1e-4 -n 8`, BC `/root/bc -f ... -i1 -n 8`.",
        "- Kernel: `Linux kernel 6.18.0modified #179 SMP PREEMPT_DYNAMIC Wed May 20 03:30:57 UTC 2026`.",
        "- VM: 96G, 32 vCPUs, node0 32G on host node0, node1 64G on host node2, KVM bind/prealloc.",
        "- Knobs: MGLRU `0x0007`, scan size 256MB, scan period min 1000ms, fast scan off, hot threshold 0.",
        "- Toggle policy: start with migration on, stop after local-util condition, re-enable after the stop condition is not satisfied for 2 consecutive windows.",
        "",
    ]

    for workload in ("pr", "bc"):
        lines += [
            f"## {workload.upper()}",
            "",
            "| cap | window | avg trial s | off s | on s | off/on count | final state | hint faults | promoted | demoted |",
            "| --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: |",
        ]
        for row in sorted(by_workload.get(workload, []), key=lambda r: (r["cap"], int(r["window_sec"]))):
            demoted = int(row["pgdemote_kswapd"] or 0) + int(row["pgdemote_direct"] or 0)
            lines.append(
                f"| {row['cap']} | {row['window_sec']} | {float(row['avg_trial_s']):.5f} | "
                f"{sec(row['first_off_ms'])} | {sec(row['first_on_ms'])} | "
                f"{row['off_count']}/{row['on_count']} | {row['final_controller_state']} | "
                f"{int(row['numa_hint_faults']):,} | {int(row['pgpromote_success']):,} | {demoted:,} |"
            )
        lines.append("")

    lines += [
        "## Observation",
        "",
        "- Every case toggled exactly once: one `off` followed by one `on`, and the final controller state was `on`.",
        "- After re-enable, these runs generally did not accumulate enough local PTE-update/refault evidence to stop again, so the latter part of each run behaves closer to migration-on than one-shot `ours`.",
        "- The strongest regressions are PR 8G/5s and BC 8G all windows, where re-enabling keeps migration cost high for most later trials.",
        "",
    ]

    OUT_MD.write_text("\n".join(lines), encoding="ascii")
    print(OUT_MD)


if __name__ == "__main__":
    main()
