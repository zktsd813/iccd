# Remote-only moving-friendly phase on/off/adaptive analysis

Experiment:
`/Serverless/iccd/experiments/20260508-phase-move15s4g-remote-split32-onoff-adaptive`

Run id:
`20260508T1730Z-phase-move15s4g-remote-split32`

Candidate:
`phase_move15s4g_remote_split32_stream4k_localft`

Policies:
`off`, `on`, `oracle_cgroup_global0`

## Configuration

- `PHASE_MS=60000`
- `PHASE_REPEAT=3`
- `SAMPLE_MS=500`
- `NUMA_SCAN_SIZE_MB=4096`
- `SCAN_PERIOD_SCALE=100`
- `HOT_THRESHOLD_MS=0`
- MGLRU: `0x0007`
- Kernel: `Linux kernel 6.18.0modified #157 SMP PREEMPT_DYNAMIC Fri May 8 15:16:31 UTC 2026`

The friendly hotset was remote-only. Observed friendly offsets:

| policy | friendly offsets |
| --- | --- |
| off | `16G`, `20G`, `44G`, `60G` |
| on | `16G`, `20G`, `44G`, `60G` |
| oracle_cgroup_global0 | `16G`, `20G`, `44G`, `60G` |

The adaptive policy controller behaved as intended:

| phase | kind | global NUMA | cgroup node_balancing |
| ---: | --- | ---: | ---: |
| 1 | friendly | 0 | 2 |
| 2 | sparse/unfriendly | 0 | 0 |
| 3 | friendly | 0 | 2 |
| 4 | sparse/unfriendly | 0 | 0 |
| 5 | friendly | 0 | 2 |
| 6 | sparse/unfriendly | 0 | 0 |

## Phase Results

Friendly phases are reported in Mops/s. Unfriendly phases are reported in MiB/s.

| phase | workload | off mean | off median | on mean | on median | adaptive mean | adaptive median |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | friendly | 228.68 | 228.20 | 286.12 | 228.20 | 285.94 | 228.56 |
| 2 | unfriendly | 4503.17 | 4504.68 | 3031.20 | 2574.35 | 3950.98 | 3959.42 |
| 3 | friendly | 228.24 | 228.26 | 751.60 | 396.49 | 360.69 | 349.04 |
| 4 | unfriendly | 4491.26 | 4492.10 | 2844.46 | 2803.21 | 3409.63 | 3498.05 |
| 5 | friendly | 228.15 | 228.13 | 867.41 | 723.52 | 567.96 | 328.73 |
| 6 | unfriendly | 4492.13 | 4492.10 | 3137.70 | 2881.49 | 2688.80 | 2634.02 |

## Aggregate Results

| policy | friendly mean Mops/s | friendly median Mops/s | unfriendly mean MiB/s | unfriendly median MiB/s | promote GiB | demote GiB | hint faults |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| off | 228.35 | 228.20 | 4495.52 | 4496.29 | 0.000 | 0.000 | 0 |
| on | 635.04 | 449.40 | 3004.45 | 2753.01 | 30.041 | 29.418 | 51,678,660 |
| adaptive | 404.86 | 302.11 | 3349.80 | 3363.83 | 15.144 | 14.940 | 28,369,875 |

Ratios:

| scope | on/off | adaptive/off | adaptive/on |
| --- | ---: | ---: | ---: |
| friendly mean | 2.781x | 1.773x | 0.638x |
| friendly median | 1.969x | 1.324x | 0.672x |
| unfriendly mean | 0.668x | 0.745x | 1.115x |
| unfriendly median | 0.612x | 0.748x | 1.222x |

## Interpretation

The remote-only fix made the friendly comparison clean: off stays flat around
`228 Mops/s`, while on improves the remote hotset over repeated friendly
phases.

Full migration-on is strongly friendly-positive but unfriendly-negative:

- friendly mean improves `2.78x` over off
- unfriendly mean drops to `0.67x` of off
- migration activity is high: about `30 GiB` promoted and `29 GiB` demoted

Adaptive reduces migration roughly by half and improves unfriendly throughput
relative to full-on:

- promotion drops from `30.04 GiB` to `15.14 GiB`
- demotion drops from `29.42 GiB` to `14.94 GiB`
- unfriendly mean improves from `3004.45` to `3349.80 MiB/s`

However, adaptive does not preserve the full friendly benefit under this
`16G` local-prefix placement. It reaches only `0.64x` of full-on friendly mean.
The local prefix is too large for this adaptive policy: it preserves too much
initial local residency for the streaming phase and leaves less useful room for
friendly hotset promotion.

Conclusion:

- As a remote-only validation, this run is valid.
- As an adaptive placement, `16G` local prefix is not optimal.
- This motivates reducing the initial local split; the later split sweep found
  `3G` as the balanced target and `6G` as an unfriendly-biased alternative.

