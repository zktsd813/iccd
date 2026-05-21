# Remote-only scan4096 on/off/adaptive rerun

Experiment:
`/Serverless/iccd/experiments/20260509-remoteonly-scan4096-onoff-adaptive-rerun`

Run id:
`20260509T0218Z-remoteonly-scan4096-rerun`

Candidate:
`phase_move15s4g_remote_split32_stream4k_localft`

Policies:
`off`, `on`, `oracle_cgroup_global0`

## Configuration Check

- `NUMA_SCAN_SIZE_MB=4096`
- `effective_numa_scan_size_mb=4096`
- `SCAN_PERIOD_SCALE=100`
- `HOT_THRESHOLD_MS=0`
- `PHASE_MS=60000`
- `PHASE_REPEAT=3`
- `SAMPLE_MS=500`
- MGLRU: `0x0007`
- Kernel: `Linux kernel 6.18.0modified #157 SMP PREEMPT_DYNAMIC Fri May 8 15:16:31 UTC 2026`

Remote-only friendly offset check:

| policy | friendly offsets |
| --- | --- |
| off | `16G`, `20G`, `44G`, `60G` |
| on | `16G`, `20G`, `44G`, `60G` |
| oracle_cgroup_global0 | `16G`, `20G`, `44G`, `60G` |

## Phase Mean Results

Friendly phases are `Mops/s`. Unfriendly phases are `MiB/s`.

| phase | workload | off mean | on mean | adaptive mean | unit |
| ---: | --- | ---: | ---: | ---: | --- |
| 1 | friendly | 228.84 | 288.17 | 286.20 | Mops/s |
| 2 | unfriendly | 4555.72 | 2829.27 | 4099.37 | MiB/s |
| 3 | friendly | 228.23 | 644.04 | 346.24 | Mops/s |
| 4 | unfriendly | 4556.00 | 2415.24 | 3804.99 | MiB/s |
| 5 | friendly | 228.27 | 717.68 | 486.68 | Mops/s |
| 6 | unfriendly | 4561.30 | 2692.94 | 2796.46 | MiB/s |

## Aggregate Results

| policy | friendly mean Mops/s | friendly median Mops/s | unfriendly mean MiB/s | unfriendly median MiB/s | promote GiB | demote GiB | hint faults |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| off | 228.44 | 228.35 | 4557.67 | 4559.94 | 0.000 | 0.000 | 0 |
| on | 549.96 | 361.41 | 2645.82 | 2550.14 | 28.386 | 27.409 | 52,500,623 |
| adaptive | 373.04 | 299.95 | 3566.94 | 3546.98 | 14.872 | 14.700 | 27,677,722 |

Ratios:

| scope | on/off | adaptive/off | adaptive/on |
| --- | ---: | ---: | ---: |
| friendly mean | 2.407x | 1.633x | 0.678x |
| friendly median | 1.583x | 1.314x | 0.830x |
| unfriendly mean | 0.581x | 0.783x | 1.348x |
| unfriendly median | 0.559x | 0.778x | 1.391x |

## Comparison With Previous Scan4096 Remote-only Run

Previous run:
`/Serverless/iccd/experiments/20260508-phase-move15s4g-remote-split32-onoff-adaptive`

Phase mean delta, new minus previous:

| phase | workload | off delta | on delta | adaptive delta |
| ---: | --- | ---: | ---: | ---: |
| 1 | friendly | +0.1% | +0.7% | +0.1% |
| 2 | unfriendly | +1.2% | -6.7% | +3.8% |
| 3 | friendly | -0.0% | -14.3% | -4.0% |
| 4 | unfriendly | +1.4% | -15.1% | +11.6% |
| 5 | friendly | +0.1% | -17.3% | -14.3% |
| 6 | unfriendly | +1.5% | -14.2% | +4.0% |

## Interpretation

The rerun confirms the baseline placement and off behavior:

- scan size was effectively `4096`
- remote-only friendly offsets were maintained
- `off` is highly stable: friendly remains about `228 Mops/s`; unfriendly
  remains about `4.5 GiB/s`

The migration policies show run-to-run variation:

- `on` still improves friendly over off, but less than the previous run.
- `on` hurts unfriendly more strongly in this rerun.
- `adaptive` again cuts migration roughly in half compared with `on`.
- `adaptive` improves unfriendly over `on`, but friendly remains well below
  full `on`.

Conclusion:

The scan4096 rerun is valid and reinforces the previous conclusion: with the
remote-only workload, a `16G` local prefix is not the best adaptive placement.
It is stable for off/unfriendly baseline, but it leaves adaptive in a
middle-ground: better unfriendly than full-on, but not enough friendly benefit.

