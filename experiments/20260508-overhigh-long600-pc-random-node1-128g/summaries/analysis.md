# 600s HSS32 Long Run After Over-High Fix

Date: 2026-05-08

Artifact: `/Serverless/iccd/experiments/20260508-overhigh-long600-pc-random-node1-128g/qemu-logs/phase_candidate_microbench/20260508T112437Z`

## Run Configuration

- Kernel image: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Fresh initrd: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260508-overhigh-long600-pc-random-node1-128g.img`
- Guest kernel: `Linux kernel 6.18.0modified #151 SMP PREEMPT_DYNAMIC Fri May 8 11:25:09 UTC 2026`
- Build/initrd path used all CPUs through the wrapper: `jobs=64`; manual pre-check build used `make -C /Serverless/Migration-friendly/linux -j$(nproc) bzImage modules`
- KVM: enabled
- VM: `CPUS=32`, `MEMORY=160G`, guest node0 `32G`, guest node1 `128G`
- Host binding: `HOST_CPUS=0-31`, node0 host node `0`, node1 host node `2`, `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1`
- Cgroup cap: `CAPACITY_PAGES=4194304` (`16GiB`)
- Placement: local-first-touch arena with hotset/window remote-first-touched on guest node1
- MGLRU: `lru_gen_enabled=0x0007`
- Scan: `NUMA_SCAN_SIZE_MB=4096`, effective `4096`, `SCAN_PERIOD_SCALE=100`, `HOT_THRESHOLD_MS=0`
- Migration knobs: `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2`, `KSWAPD_DEMOTION_ON=1`, `OFF_DEMOTION_ON=1`
- Diagnostics disabled: `NUMA_MIGRATION_STOP_ENABLED=0`, `NUMA_PINGPONG_STAT_ENABLED=0`, `NUMA_PROMOTE_SAMPLE_STAT_ENABLED=0`, `NUMA_PROMOTE_SAMPLE_RATE=0`
- Duration: `MBENCH_FORCE_DURATION_MS=600000`, `LIVE_SAMPLE_SEC=10`

Initial measured cgroup anon residency before each workload:

| workload | node0 anon | node1 anon |
| --- | ---: | ---: |
| pointer-chase | 15.61 GiB | 48.39 GiB |
| random-read/mulshift | 15.42 GiB | 48.58 GiB |

## Workloads

Pointer-chase:

```text
--mode pc --window-size 32G --window-offset 0 --move-policy fixed --pc-chains 1 --pc-pattern random --hotset-prefault-node 1 --threads 32
```

Random-read/mulshift:

```text
--mode skewed-hotset --window-size 32G --window-offset 0 --move-policy fixed --hotset-pages 8388608 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift --hotset-prefault-node 1 --threads 32
```

## Overall Result

`candidate/HSS` and `promotion/HSS` below are event-volume ratios, not unique hotset coverage. With 4096MiB scan and demotion/re-promotion churn, an individual page can contribute more than once.

| workload | mean | median | last 60s | promoted | demoted | candidate | candidate+NRL/bypass | over_high | pgmigrate_fail | latency pass |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| pointer-chase | 107.74 Mops/s | 111.02 Mops/s | 111.99 Mops/s | 6,230,725 pages, 23.77 GiB, 74.3% HSS | 7,335,505 pages, 27.98 GiB | 6,181,120 pages, 23.58 GiB, 73.7% HSS | 6,230,738 pages, 23.77 GiB, 74.3% HSS | 4 | 3,425 | 18.8% |
| random-read/mulshift | 508.25 Mops/s | 477.04 Mops/s | 534.40 Mops/s | 10,449,726 pages, 39.86 GiB, 124.6% HSS | 10,424,109 pages, 39.76 GiB | 10,449,801 pages, 39.86 GiB, 124.6% HSS | 10,449,807 pages, 39.86 GiB, 124.6% HSS | 79 | 24,178 | 14.1% |

Other counters:

| workload | promotion_enter | latency_pass | latency_fail | blocked | alloc_fail | max node0 usage | reclaimd runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| pointer-chase | 32,935,740 | 6,181,120 | 26,705,002 | 0 | 0 | 16.00 GiB | 6 |
| random-read/mulshift | 74,319,819 | 10,449,801 | 63,870,012 | 0 | 0 | 16.00 GiB | 4 |

## Pointer-Chase 60s Phases

| phase | seconds | ops | promoted | demoted | candidate | candidate+NRL/bypass | over_high | pgmigrate_fail | node0 end | reclaimd runs |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0-60 | 28.72 Mops/s | 4.86 GiB | 10.22 GiB | 4.67 GiB | 4.86 GiB | 0 | 191 | 14.46 GiB | 1 |
| 2 | 60-120 | 148.80 Mops/s | 5.98 GiB | 5.17 GiB | 5.98 GiB | 5.98 GiB | 0 | 427 | 15.03 GiB | 1 |
| 3 | 120-180 | 121.11 Mops/s | 5.83 GiB | 5.17 GiB | 5.83 GiB | 5.83 GiB | 0 | 1,426 | 15.69 GiB | 3 |
| 4 | 180-240 | 109.50 Mops/s | 0.98 GiB | 1.09 GiB | 0.98 GiB | 0.98 GiB | 0 | 26 | 15.58 GiB | 0 |
| 5 | 240-300 | 111.07 Mops/s | 2.19 GiB | 2.21 GiB | 2.19 GiB | 2.19 GiB | 1 | 278 | 15.57 GiB | 0 |
| 6 | 300-360 | 111.94 Mops/s | 0.00 GiB | 0.06 GiB | 0.00 GiB | 0.00 GiB | 0 | 150 | 15.50 GiB | 0 |
| 7 | 360-420 | 109.67 Mops/s | 0.00 GiB | 0.07 GiB | 0.00 GiB | 0.00 GiB | 0 | 74 | 15.44 GiB | 0 |
| 8 | 420-480 | 113.13 Mops/s | 0.00 GiB | 0.07 GiB | 0.00 GiB | 0.00 GiB | 0 | 34 | 15.37 GiB | 0 |
| 9 | 480-540 | 111.41 Mops/s | 0.68 GiB | 0.05 GiB | 0.68 GiB | 0.68 GiB | 0 | 100 | 16.00 GiB | 0 |
| 10 | 540-600 | 111.99 Mops/s | 3.25 GiB | 3.74 GiB | 3.25 GiB | 3.25 GiB | 3 | 662 | 15.51 GiB | 0 |

## Random-Read/Mulshift 60s Phases

| phase | seconds | ops | promoted | demoted | candidate | candidate+NRL/bypass | over_high | pgmigrate_fail | node0 end | reclaimd runs |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0-60 | 306.80 Mops/s | 10.71 GiB | 10.35 GiB | 10.71 GiB | 10.71 GiB | 0 | 0 | 15.70 GiB | 2 |
| 2 | 60-120 | 462.56 Mops/s | 6.03 GiB | 5.73 GiB | 6.03 GiB | 6.03 GiB | 0 | 17 | 16.00 GiB | 1 |
| 3 | 120-180 | 534.18 Mops/s | 1.72 GiB | 1.87 GiB | 1.72 GiB | 1.72 GiB | 14 | 1,010 | 15.86 GiB | 0 |
| 4 | 180-240 | 516.61 Mops/s | 2.54 GiB | 2.62 GiB | 2.54 GiB | 2.54 GiB | 15 | 1,374 | 15.79 GiB | 0 |
| 5 | 240-300 | 543.16 Mops/s | 2.61 GiB | 2.57 GiB | 2.61 GiB | 2.61 GiB | 8 | 1,588 | 15.82 GiB | 0 |
| 6 | 300-360 | 523.16 Mops/s | 3.03 GiB | 3.04 GiB | 3.03 GiB | 3.03 GiB | 12 | 3,212 | 15.82 GiB | 0 |
| 7 | 360-420 | 540.04 Mops/s | 3.36 GiB | 3.20 GiB | 3.36 GiB | 3.36 GiB | 5 | 5,068 | 15.98 GiB | 0 |
| 8 | 420-480 | 562.36 Mops/s | 3.02 GiB | 3.07 GiB | 3.02 GiB | 3.02 GiB | 7 | 3,294 | 15.93 GiB | 0 |
| 9 | 480-540 | 558.70 Mops/s | 3.19 GiB | 3.30 GiB | 3.19 GiB | 3.19 GiB | 13 | 3,192 | 15.82 GiB | 0 |
| 10 | 540-600 | 534.40 Mops/s | 3.64 GiB | 3.52 GiB | 3.64 GiB | 3.64 GiB | 5 | 4,510 | 15.94 GiB | 0 |

## Interpretation

The prior over-high dead-zone problem is effectively fixed for these long runs. It is not mathematically zero, but it is no longer the dominant failure path: pointer-chase saw 4 over-high rejects over 32.9M promotion-enter events, and random-read saw 79 over-high rejects over 74.3M promotion-enter events. `blocked=0` and `alloc_fail=0` in both runs.

Pointer-chase now accumulates 23.77GiB of promotion event volume in 600s, but candidate formation is still limited by the hot/latency filter: only 18.8% of promotion-enter events passed latency. It also has a clear mid-run plateau from 300-480s, then resumes promotion in the last two minutes, consistent with scan/revisit cadence rather than an over-high gate.

Random-read/mulshift promotes 39.86GiB and demotes 39.76GiB over 600s. The promotion/HSS ratio is above 100% because this is event volume with demote/re-promote churn, not unique HSS coverage. This run confirms that the over-high fix also holds for the earlier random-read HSS32 shape.

The remaining `pgmigrate_fail` values are generic migration failures, not cgroup over-high, cgroup blocked, or destination allocation failures. Further debugging should focus on generic migration failure reasons and scanner/hot-threshold coverage if the goal is unique HSS coverage, not the previous cgroup over-high dead zone.
