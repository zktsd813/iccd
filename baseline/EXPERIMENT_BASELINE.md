# VM Experiment Baseline Reference

Future VM realworld experiments should use this document as the baseline reference before launch.

## Current Baseline

- Baseline README: `baseline/README.md`
- Main frozen run: `baseline/20260710T-local32-48-onoff-controller-tail-jemalloc`
- Main latest symlink: `baseline/latest-local32-48-onoff-controller-tail-jemalloc`
- Main source run: `motivation/3_realworld/VM/results/20260710T-local32-48-onoff-controller-tail-jemalloc`
- Main summary CSV: `baseline/20260710T-local32-48-onoff-controller-tail-jemalloc/summaries/summary.csv`
- Local16 fixed-only frozen run: `baseline/20260709T-local16-onoff-tail-jemalloc-rerun`
- Local16 latest symlink: `baseline/latest-local16-onoff-tail-jemalloc`
- Local16 source run: `motivation/3_realworld/VM/results/20260709T-local16-onoff-tail-jemalloc-rerun`
- Local16 summary CSV: `baseline/20260709T-local16-onoff-tail-jemalloc-rerun/summaries/summary.csv`
- Fixed on/off reference CSV: `baseline/fixed-onoff-reference.csv`

The main run contains fixed OFF, fixed ON, and the previous controller at
local32/local48. The local16 supplement contains fixed OFF/ON only. It has no
controller cells by design.

## Baseline Settings To Preserve

- VM-only execution.
- SMT off: `DISABLE_SMT=1`, `RESTORE_SMT=0`.
- Fixed OFF/ON local memory sweep: 16 GiB, 32 GiB, and 48 GiB.
- Previous-controller cells: 32 GiB and 48 GiB only.
- Remote memory: 192 GiB on host node 2.
- Host CPUs: `0-31`.
- Guest CPUs: 32.
- Fast host node: 0.
- Slow host node: 2.
- Slow memory mode: `host-cxl`.
- HMAT: fast `80ns/40000M`, slow `250ns/10000M`.
- Rootfs overlay IO: qcow2 with `cache=none,aio=native`.
- Host page cache drop before VM boot and before guest run.
- Guest cache drop and memory compaction between workloads.
- Normal NUMA scan size: 256 MB.
- Workloads: `pr bc gups btree graph500 silo`.
- Configs: `off on` at all three local sizes; `controller_0x2` at local32 and
  local48 only.
- GAPBS: generated graph mode, scale 29, graph build included.
- Silo: jemalloc, tail hotset, scale factor 800000, 32 threads, 100000000 ops per worker.

## Controller Baseline

- Starts with migration on.
- Window mode: `remote-cycle`.
- Window counter: `remote_scan_cycles`.
- Stop policy: `selected-gap`.
- Restart policy: `selected-gap-immediate`.
- Local quantile: P75.
- Remote quantile: P25.
- `BASELINE_SKIP_WINDOWS=0`.
- `CONSECUTIVE_EFFECTIVE=3`.
- `CONSECUTIVE_NO_IMPROVE=2`.
- `EFFECTIVE_SCORE_THRESHOLD=0.75`.
- `SCORE_EPSILON=0.05`.
- `CONSECUTIVE_RESTART=2`.
- `RESTART_GRACE_WINDOWS=1`.
- `INITIAL_STOP_ONLY=0`.
- `MONITOR_AFTER_STOP=0`.
- `STOP_ACTION=observe`.
- `STOP_FAULT_SAMPLING_ON_STOP=0`.

## Fixed On/Off References

Use these on/off values for future comparisons unless a new baseline is explicitly requested.

| Local GiB | Workload | off elapsed s | on elapsed s | Source |
| ---: | --- | ---: | ---: | --- |
| 16 | pr | 797 | 881 | local16 fixed-only baseline |
| 16 | bc | 1103 | 1193 | local16 fixed-only baseline |
| 16 | gups | 531 | 559 | local16 fixed-only baseline |
| 16 | btree | 844 | 663 | local16 fixed-only baseline |
| 16 | graph500 | 380 | 409 | local16 fixed-only baseline |
| 16 | silo | 886 | 714 | local16 fixed-only baseline |
| 32 | pr | 803 | 809 | main local32/local48 baseline |
| 32 | bc | 1074 | 873 | main local32/local48 baseline |
| 32 | gups | 307 | 815 | main local32/local48 baseline |
| 32 | btree | 547 | 650 | main local32/local48 baseline |
| 32 | graph500 | 378 | 383 | main local32/local48 baseline |
| 32 | silo | 856 | 662 | main local32/local48 baseline |
| 48 | pr | 796 | 732 | main local32/local48 baseline |
| 48 | bc | 1046 | 670 | main local32/local48 baseline |
| 48 | gups | 288 | 872 | main local32/local48 baseline |
| 48 | btree | 486 | 651 | main local32/local48 baseline |
| 48 | graph500 | 342 | 336 | main local32/local48 baseline |
| 48 | silo | 806 | 678 | main local32/local48 baseline |

Notes:

- All local16 fixed cells come from the separately frozen July 9 supplement.
- All local32/local48 fixed cells come from the main July 10 frozen run.
- Both runs use guest kernel build 23 and matching workload, VM, HMAT, scan,
  allocator, and hotset settings. No staged binary hashes were recorded, so
  bit-identical binaries cannot be proven cryptographically.
- PR/BC average trial time excludes graph generation/build, while elapsed time
  includes it. Graph500 exposes no TEPS in this legacy fork. Use workload-native
  metrics where available rather than aggregating heterogeneous elapsed times.

## Required Preflight For Next Runs

1. Check this file and `baseline/README.md` before launching.
2. Confirm the next run is VM-only unless host-native execution is explicitly requested.
3. Confirm GAPBS commands contain `-g 29`, not `-f ...sg`.
4. Confirm Silo uses jemalloc and `--bench-opts=--zipf-reverse`.
5. Confirm no allocator, workload scale, hotset direction, graph mode, or VM placement setting changed without explicit approval.
6. Record any intentional change in the next run's `host-logs/host-config.log` and in the analysis notes.
