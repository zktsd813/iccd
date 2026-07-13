# VM Realworld Baseline Results

This directory stores the frozen baseline for the current VM realworld memory-tiering runs.
Use it as the comparison point before launching the next VM experiment.

## Captured Runs

### Main local32/local48 baseline

- Captured date: 2026-07-10
- Run id: `20260710T-local32-48-onoff-controller-tail-jemalloc`
- Source run: `motivation/3_realworld/VM/results/20260710T-local32-48-onoff-controller-tail-jemalloc`
- Baseline copy: `baseline/20260710T-local32-48-onoff-controller-tail-jemalloc`
- Latest symlink: `baseline/latest-local32-48-onoff-controller-tail-jemalloc`
- Summary CSV: `20260710T-local32-48-onoff-controller-tail-jemalloc/summaries/summary.csv`
- Summary MD: `20260710T-local32-48-onoff-controller-tail-jemalloc/summaries/summary.md`

### Supplemental local16 fixed-only baseline

- Captured date: 2026-07-09
- Run id: `20260709T-local16-onoff-tail-jemalloc-rerun`
- Source run: `motivation/3_realworld/VM/results/20260709T-local16-onoff-tail-jemalloc-rerun`
- Baseline copy: `baseline/20260709T-local16-onoff-tail-jemalloc-rerun`
- Latest symlink: `baseline/latest-local16-onoff-tail-jemalloc`
- Summary CSV: `20260709T-local16-onoff-tail-jemalloc-rerun/summaries/summary.csv`
- Summary MD: `20260709T-local16-onoff-tail-jemalloc-rerun/summaries/summary.md`

Both copies contain `guest-results`, `host-logs`, and `summaries`. The qcow2
VM overlays are not preserved because the runs used `delete_vm_images=1`.

## Scope

- Environment: VM only. Do not compare this baseline with host-native runs.
- Local memory sizes: 16 GiB, 32 GiB, and 48 GiB.
- Remote memory: 192 GiB, exposed as VM node1.
- Workloads: `pr bc gups btree graph500 silo`.
- local16 configs: `off on` only.
- local32/local48 configs: `off on controller_0x2`.
- Liblinear is not part of this baseline.
- Failures/timeouts: 0 of 12 local16 rows and 0 of 36 local32/local48 rows.

The local16 supplement deliberately contains no controller cases. It supplies
the missing fixed OFF/ON reference cells without changing the provenance or
contents of the main local32/local48 baseline.

## VM Configuration

- Host CPU binding: `0-31`.
- Guest vCPUs: 32.
- Guest node0 CPUs: `0-31`.
- Fast host node: 0.
- Slow host node: 2.
- Slow memory mode: `host-cxl`.
- QEMU memory:
  - local16: `-m 208G`, node0 `16G`, node1 `192G`.
  - local32: `-m 224G`, node0 `32G`, node1 `192G`.
  - local48: `-m 240G`, node0 `48G`, node1 `192G`.
- HMAT: fast `80ns/40000M`, slow `250ns/10000M`.
- Kernel image: `linux-global-build/arch/x86/boot/bzImage`.
- Guest kernel for both frozen runs: `6.18.0modified #23`, built
  `Thu Jul 9 11:51:03 UTC 2026`.
- Kernel cmdline extra: `systemd.mask=systemd-networkd-wait-online.service`.
- Rootfs base: `/Serverless/Migration-friendly/qemu/build/ubuntu.img`.
- Rootfs overlays: qcow2, `cache=none,aio=native`.
- Host page cache:
  - dropped before VM boot.
  - dropped again before each guest run.
- Guest memory hygiene:
  - `DROP_GUEST_CACHES=1`.
  - `COMPACT_GUEST_MEMORY=1`.
- SMT:
  - `DISABLE_SMT=1`.
  - `RESTORE_SMT=0`.
  - No reboot is part of this baseline run.
- NUMA scan:
  - normal scan size: 256 MB.
  - min scan period: 1000 ms.
- Controller local fault sampling:
  - local rate: 5.
  - scan size: 64 MB.
  - scan period: 1000 ms.

## Workload Configuration

- GAPBS:
  - graph mode: generated.
  - graph scale: 29.
  - graph build is included in measured time.
  - no prebuilt `.sg` graph was staged or used.
  - PR: `-g 29 -i 20 -t 1e-4 -n 8`.
  - BC: `-g 29 -i 1 -n 8`.
- GUPS: `bench_gups_mt 64`.
- Graph500: `bench_graph500_mt -s 28`.
- Silo:
  - allocator: jemalloc build.
  - binary: `/Serverless/benchmark/silo/out-perf.masstree/benchmarks/dbtest`.
  - workload: YCSB.
  - threads: 32.
  - scale factor: 800000.
  - ops per worker: 100000000.
  - hotset direction: tail, via `--bench-opts=--zipf-reverse`.

## Policy Definitions

- `off`:
  - `numa_balancing=0`.
  - `migration_enabled=false`.
  - demotion disabled with target `0 -1 1 -1`.
- `on`:
  - `numa_balancing=2`.
  - `migration_enabled=true`.
  - demotion enabled with target `0 1 1 -1`.
- `controller_0x2`:
  - starts from migration-on state.
  - `WINDOW_MODE=remote-cycle`.
  - `CYCLE_WINDOW_STAT=remote_scan_cycles`.
  - `STOP_POLICY=selected-gap`.
  - `LOCAL_QUANTILE_PERCENTILE=75`.
  - `REMOTE_QUANTILE_PERCENTILE=25`.
  - `BASELINE_SKIP_WINDOWS=0`.
  - `CONSECUTIVE_EFFECTIVE=3`.
  - `CONSECUTIVE_NO_IMPROVE=2`.
  - `EFFECTIVE_SCORE_THRESHOLD=0.75`.
  - `SCORE_EPSILON=0.05`.
  - `RESTART_POLICY=selected-gap-immediate`.
  - `CONSECUTIVE_RESTART=2`.
  - `RESTART_GRACE_WINDOWS=1`.
  - `INITIAL_STOP_ONLY=0`.
  - `MONITOR_AFTER_STOP=0`.
  - `STOP_ACTION=observe`.
  - `STOP_FAULT_SAMPLING_ON_STOP=0`.
  - `REMOTE_FAULT_RATE=0`.
  - `NUMA_BALANCING_ON=2`.
  - `NUMA_BALANCING_OFF=0`.

## Elapsed Time Summary

Elapsed time is in seconds.

| Local GiB | Workload | off | on | controller_0x2 |
| ---: | --- | ---: | ---: | ---: |
| 16 | pr | 797 | 881 | NA |
| 16 | bc | 1103 | 1193 | NA |
| 16 | gups | 531 | 559 | NA |
| 16 | btree | 844 | 663 | NA |
| 16 | graph500 | 380 | 409 | NA |
| 16 | silo | 886 | 714 | NA |
| 32 | pr | 803 | 809 | 819 |
| 32 | bc | 1074 | 873 | 929 |
| 32 | gups | 307 | 815 | 659 |
| 32 | btree | 547 | 650 | 664 |
| 32 | graph500 | 378 | 383 | 381 |
| 32 | silo | 856 | 662 | 685 |
| 48 | pr | 796 | 732 | 780 |
| 48 | bc | 1046 | 670 | 605 |
| 48 | gups | 288 | 872 | 882 |
| 48 | btree | 486 | 651 | 597 |
| 48 | graph500 | 342 | 336 | 373 |
| 48 | silo | 806 | 678 | 676 |

## Fixed On/Off References

Use `baseline/fixed-onoff-reference.csv` for future on/off comparisons.

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

## Controller Event Summary

| Local GiB | Workload | Windows | Off Events | Restart Events | First Stop s | First Stop Window | Final State |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | --- |
| 32 | pr | 25 | 5 | 4 | 302.325 | 7 | off |
| 32 | bc | 23 | 4 | 4 | 297.348 | 6 | on |
| 32 | gups | 11 | 2 | 2 | 156.082 | 3 | on |
| 32 | btree | 17 | 1 | 1 | 87.059 | 3 | on |
| 32 | graph500 | 15 | 3 | 2 | 35.027 | 2 | off |
| 32 | silo | 19 | 0 | 0 | NA | NA | on |
| 48 | pr | 22 | 4 | 4 | 150.154 | 6 | on |
| 48 | bc | 14 | 2 | 2 | 271.214 | 7 | on |
| 48 | gups | 14 | 3 | 2 | 159.093 | 3 | off |
| 48 | btree | 13 | 1 | 1 | 209.172 | 7 | on |
| 48 | graph500 | 4 | 1 | 1 | 264.118 | 3 | on |
| 48 | silo | 21 | 0 | 0 | NA | NA | on |

## Future Experiment Checklist

Before launching the next VM experiment:

- Read `baseline/EXPERIMENT_BASELINE.md`.
- Compare new settings against this README and the copied `host-logs/host-config.log`.
- Run VM workloads only unless host-native execution is explicitly requested.
- Do not change allocator, Silo hotset direction, GAPBS graph mode, or workload scale without explicit approval.
- Keep GAPBS in generated graph mode unless a graph-file experiment is explicitly requested.
- Keep Silo on jemalloc and tail-hotset mode for comparisons against this baseline.
- If changing only local memory size, keep every other setting above fixed.
