# Phase transition analysis: migration on only

Experiment:
`/Serverless/iccd/experiments/20260508-phase-move15s4g-split32-on-transition`

Run id:
`20260508T1651Z-phase-move15s4g-on-transition`

Candidate:
`phase_move15s4g_split32_stream4k_localft`

Policy:
`on`

Important configuration:

- `PHASE_MS=60000`
- `PHASE_REPEAT=3`
- `SAMPLE_MS=500`
- `ARENA_SIZE=64G`
- `THREADS=32`
- `NUMA_SCAN_SIZE_MB=4096`
- `SCAN_PERIOD_SCALE=100`
- `HOT_THRESHOLD_MS=0`
- Friendly phase: 4G moving read hotset, random 4G-aligned offset across the 64G RSS, 15s move interval.
- Unfriendly phase: fixed 32G streaming read window at offset 0, 4KB stride.
- Initial phase placement: first 16G local, remaining 48G remote.

## Migration counters

Migration-on kernel counters during the run:

| counter | pages | GiB |
| --- | ---: | ---: |
| `pgpromote_success` | 8,091,201 | 30.865 |
| `pgdemote_direct` | 7,910,499 | 30.176 |

Additional counters:

- `numa_hint_faults`: 51,687,899
- `pgmigrate_fail`: 43,009

## Unfriendly phases

The unfriendly phases are phases 2, 4, and 6. Units below are streaming read throughput.

| phase | mean MiB/s | median MiB/s | mean Mops/s | median Mops/s |
| --- | ---: | ---: | ---: | ---: |
| 2 | 3245.59 | 3602.91 | 405.70 | 450.36 |
| 4 | 2568.74 | 2483.80 | 321.09 | 310.48 |
| 6 | 2942.15 | 2825.50 | 367.77 | 353.19 |

The `phase_elapsed=0` sample is a partial transition sample and should not be treated as steady-state performance.

## Early-transition shape

Window averages exclude the `phase_elapsed=0` sample.

| phase | 0.5-2s | 2-5s | 5-10s | 10-20s | 20-40s | 40-60s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 Mops/s | 469.94 | 487.15 | 533.10 | 546.47 | 450.51 | 244.06 |
| 4 Mops/s | 303.04 | 336.86 | 219.78 | 351.40 | 318.48 | 331.19 |
| 6 Mops/s | 226.49 | 143.65 | 188.27 | 473.04 | 378.47 | 391.58 |

## Migration deltas by transition window

The table below uses `live.csv` cgroup counters. Counter snapshots are roughly 1s apart, so window boundaries are approximate. `pgdemote_kswapd` was zero; demotion below is `pgdemote_direct`.

| phase | window | promote pages | promote GiB | demote pages | demote GiB |
| --- | --- | ---: | ---: | ---: | ---: |
| 2 | 0.5-2s | 0 | 0.000 | 0 | 0.000 |
| 2 | 2-5s | 203,786 | 0.777 | 63,552 | 0.242 |
| 2 | 5-10s | 335,264 | 1.279 | 263,072 | 1.004 |
| 2 | 10-20s | 548,902 | 2.094 | 747,285 | 2.851 |
| 2 | 20-40s | 771,733 | 2.944 | 671,312 | 2.561 |
| 2 | 40-60s | 576,169 | 2.198 | 520,405 | 1.985 |
| 4 | 0.5-2s | 21,977 | 0.084 | 0 | 0.000 |
| 4 | 2-5s | 269,963 | 1.030 | 128,193 | 0.489 |
| 4 | 5-10s | 175,071 | 0.668 | 84,742 | 0.323 |
| 4 | 10-20s | 250,690 | 0.956 | 285,892 | 1.091 |
| 4 | 20-40s | 338,843 | 1.293 | 354,354 | 1.352 |
| 4 | 40-60s | 282,874 | 1.079 | 266,096 | 1.015 |
| 6 | 0.5-2s | 2,536 | 0.010 | 0 | 0.000 |
| 6 | 2-5s | 0 | 0.000 | 0 | 0.000 |
| 6 | 5-10s | 235,020 | 0.897 | 11 | 0.000 |
| 6 | 10-20s | 558,213 | 2.129 | 558,205 | 2.129 |
| 6 | 20-40s | 208,003 | 0.793 | 309,860 | 1.182 |
| 6 | 40-60s | 333,777 | 1.273 | 288,592 | 1.101 |

## Interpretation

The unfriendly phase does not start from a clean steady state immediately after the friendly phase.

- Phase 2 reaches a high level within roughly 1-2 seconds, stays high until about 20 seconds, then drops later in the phase.
- Phase 4 is mixed: after the first transition samples it oscillates around the later steady range, with a dip around 5-10 seconds.
- Phase 6 shows the clearest ramp: it starts low, remains low for several seconds, then jumps upward around 10-11 seconds and settles near the later range.

So the observed behavior is not "steady from the beginning". It is also not always a simple monotonic ramp. The safest summary is: friendly to unfriendly has a real transient; depending on the prior friendly phase's migrated placement, the unfriendly phase either reaches the later range within a couple seconds or ramps over about 10 seconds.
