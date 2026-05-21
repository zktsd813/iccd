# Phase moving-friendly / split32-streaming miracle-adaptive run

Experiment:
`/Serverless/iccd/experiments/20260508-phase-move15s4g-split32-miracle-adaptive`

Run id:
`20260508T1710Z-phase-move15s4g-miracle`

Candidate:
`phase_move15s4g_split32_stream4k_localft`

Policy:
`oracle_cgroup_global0`

This is the miracle/adaptive policy used in earlier phase experiments. It keeps
global NUMA balancing off and uses the phase controller to set cgroup
`node_balancing=2` for friendly phases and `node_balancing=0` for unfriendly
streaming phases.

## Configuration

- `PHASE_MS=60000`
- `PHASE_REPEAT=3`
- `SAMPLE_MS=500`
- `ARENA_SIZE=64G`
- `THREADS=32`
- `NUMA_SCAN_SIZE_MB=4096`
- `SCAN_PERIOD_SCALE=100`
- `HOT_THRESHOLD_MS=0`
- `NUMA_MIGRATION_STOP_ENABLED=0`
- `NUMA_PINGPONG_STAT_ENABLED=0`
- `NUMA_PROMOTE_SAMPLE_STAT_ENABLED=0`
- `lru_gen_enabled=0x0007`
- Kernel: `Linux kernel 6.18.0modified #157 SMP PREEMPT_DYNAMIC Fri May 8 15:16:31 UTC 2026`

Initial measured anon placement after prefault:

| node | anon |
| --- | ---: |
| node0 | 14.603 GiB |
| node1 | 49.397 GiB |

## Policy Controller Check

`policy-controller.log` confirms the intended oracle behavior:

| phase | kind | global NUMA | cgroup node_balancing |
| ---: | --- | ---: | ---: |
| 1 | friendly | 0 | 2 |
| 2 | sparse/unfriendly | 0 | 0 |
| 3 | friendly | 0 | 2 |
| 4 | sparse/unfriendly | 0 | 0 |
| 5 | friendly | 0 | 2 |
| 6 | sparse/unfriendly | 0 | 0 |

## Migration Counters

| policy | promote pages | promote GiB | demote pages | demote GiB | hint faults |
| --- | ---: | ---: | ---: | ---: | ---: |
| on-only transition rerun | 8,091,201 | 30.865 | 7,910,499 | 30.176 | 51,687,899 |
| miracle/adaptive | 3,539,122 | 13.501 | 3,476,804 | 13.263 | 24,749,559 |

Relative to the on-only transition rerun, miracle/adaptive reduced:

- promotion to `0.437x`
- demotion to `0.439x`
- hint faults to `0.479x`

## Phase Throughput

| phase | name | mean Mops/s | median Mops/s | mean MiB/s | median MiB/s |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | move15s-hotset-4g-rss64 | 1016.59 | 320.86 | 65061.97 | 20534.85 |
| 2 | stream-read-32g-split16-4k | 525.09 | 524.81 | 4200.72 | 4198.50 |
| 3 | move15s-hotset-4g-rss64 | 1045.70 | 672.26 | 66924.54 | 43024.90 |
| 4 | stream-read-32g-split16-4k | 524.22 | 524.29 | 4193.78 | 4194.30 |
| 5 | move15s-hotset-4g-rss64 | 875.65 | 601.23 | 56041.76 | 38478.54 |
| 6 | stream-read-32g-split16-4k | 462.34 | 461.90 | 3698.75 | 3695.18 |

Average by phase type:

| phase type | mean | median |
| --- | ---: | ---: |
| friendly | 979.31 Mops/s | 531.45 Mops/s |
| unfriendly | 4031.08 MiB/s | 4029.33 MiB/s |

## Comparison With On-Only

| phase type | on-only | miracle/adaptive | ratio |
| --- | ---: | ---: | ---: |
| friendly mean | 1024.36 Mops/s | 979.31 Mops/s | 0.956x |
| friendly median | 533.36 Mops/s | 531.45 Mops/s | 0.996x |
| unfriendly mean | 2918.83 MiB/s | 4031.08 MiB/s | 1.381x |
| unfriendly median | 2970.74 MiB/s | 4029.33 MiB/s | 1.356x |

Using the earlier off baseline for this same phase pair, unfriendly off was
about `4516.25 MiB/s` mean and `4517.86 MiB/s` median. The miracle/adaptive
unfriendly result reaches about `0.893x` of that off mean.

## Unfriendly Transition Windows

Window averages exclude the partial `phase_elapsed=0` sample.

| phase | 0.5-2s | 2-5s | 5-10s | 10-20s | 20-40s | 40-60s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 Mops/s | 471.16 | 524.81 | 524.08 | 524.73 | 525.55 | 524.50 |
| 4 Mops/s | 476.40 | 523.15 | 523.66 | 523.63 | 524.04 | 524.46 |
| 6 Mops/s | 456.31 | 461.46 | 461.64 | 461.45 | 462.28 | 462.11 |

During the unfriendly phases, the phase controller keeps cgroup
`node_balancing=0`, and `live.csv` shows zero promotion/demotion deltas inside
the unfriendly windows. The unfriendly phase is therefore much closer to
steady from the start: after the first 0.5-2s transition window, phases 2 and 4
are flat near 524 Mops/s, and phase 6 is flat near 462 Mops/s.

## Interpretation

Miracle/adaptive preserves the friendly benefit almost exactly by median while
removing the migration activity during unfriendly phases. Compared with
on-only, unfriendly throughput improves by about `1.36-1.38x`, and the
previous unfriendly ramp/transient largely disappears once the first transition
window is past.

