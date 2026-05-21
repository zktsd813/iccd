# Remote-only phase experiment, 200s phases

Run: `20260509T0330Z-remoteonly-scan4096-phase200-t1500`

This is the valid rerun for 200 second phases. The first attempt under
`20260509-remoteonly-scan4096-phase200-onoff-adaptive` was truncated because
the runner default `TIMEOUT_SEC=900` killed each policy before the 6 phases
completed. This rerun used `TIMEOUT_SEC=1500`.

## Configuration

- Candidate: `phase_move15s4g_remote_split32_stream4k_localft`
- Policies: `off`, `on`, `oracle_cgroup_global0`
- `PHASE_MS=200000`, `PHASE_REPEAT=3`
- Effective phases: friendly/unfriendly repeated 3 times, 6 phases total
- `NUMA_SCAN_SIZE_MB=4096`, `SCAN_PERIOD_SCALE=100`, `HOT_THRESHOLD_MS=0`
- `MEMORY=96G`, `CPUS=32`, node0 `32G`, node1 `64G`
- Host binding: node0 memory on host node0, node1 memory on host node2
- `CAPACITY_PAGES=4194304`
- MGLRU runtime: `lru_gen_enabled=0x0007`
- Kernel: `6.18.0modified #157`
- Return code: all three policy runs returned `0`

Adaptive controller log confirmed:

- Friendly phases 1, 3, 5: `global=0`, `cgroup_node_balancing=2`
- Unfriendly phases 2, 4, 6: `global=0`, `cgroup_node_balancing=0`

## Phase Means

Friendly units are Mops/s. Unfriendly units are MB/s from the summarizer
`mean_MBps` field.

| phase | kind | off | on | adaptive |
| --- | --- | ---: | ---: | ---: |
| 1 | friendly | 228.33 | 271.48 | 274.69 |
| 2 | unfriendly | 4518.59 | 2280.98 | 3932.91 |
| 3 | friendly | 228.20 | 691.58 | 439.58 |
| 4 | unfriendly | 4519.67 | 3022.21 | 4210.88 |
| 5 | friendly | 228.06 | 736.38 | 742.07 |
| 6 | unfriendly | 4519.86 | 3354.95 | 2522.70 |

## Aggregate Means

| policy | friendly mean Mops/s | unfriendly mean MB/s | promoted GiB | demoted GiB | hint faults |
| --- | ---: | ---: | ---: | ---: | ---: |
| off | 228.20 | 4519.38 | 0.00 | 0.00 | 0 |
| on | 566.48 | 2886.05 | 43.13 | 42.25 | 86060644 |
| adaptive | 485.45 | 3555.50 | 25.33 | 24.76 | 54887081 |

## Ratios

| scope | on/off | adaptive/off | adaptive/on |
| --- | ---: | ---: | ---: |
| friendly mean | 2.482x | 2.127x | 0.857x |
| unfriendly mean | 0.639x | 0.787x | 1.232x |

## Notes

- The 200s result preserves the earlier conclusion: full migration-on improves
  friendly phases but still hurts the streaming unfriendly phases.
- Adaptive reduces migration volume versus full-on and recovers unfriendly
  throughput relative to full-on, while keeping most of the friendly gain.
- Compared with the 60s rerun, the 200s run gives adaptive a stronger friendly
  mean (`485.45` vs `373.04` Mops/s) while keeping almost the same unfriendly
  mean (`3555.50` vs `3566.94` MB/s).
