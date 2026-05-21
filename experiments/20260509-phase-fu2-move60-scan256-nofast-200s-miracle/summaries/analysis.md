# Two-Phase Friendly/Unfriendly Move60 Scan256 No-Fast

Date: 2026-05-09 UTC

## Setup

- Candidate: `phase_move60s4g_remote_split32_stream4k_localft`
- Phase 1: `move60s-hotset-4g-remote`, 200s, remote-only 4 GiB mulshift hot window, random 4 GiB-aligned movement every 60s
- Phase 2: `stream-read-32g-split16-4k`, 200s, 32 GiB stream read, 4 KiB stride, initial active window split 16 GiB local / 16 GiB remote
- Policies: `off`, `on`, `oracle_cgroup_global0` (`Miracle`)
- Scan: `NUMA_SCAN_SIZE_MB=256`, effective `256`; `NUMA_FAST_SCAN=0`; `NUMA_SCAN_PERIOD_MIN_MS=1000`, effective `1000`
- Kernel: `Linux kernel 6.18.0modified #163 SMP PREEMPT_DYNAMIC Sat May  9 12:53:28 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux`
- MGLRU: `0x0007`; cgroup cap 16 GiB; earlystop/pingpong disabled
- Initial anon placement: node0 `14.60 GiB`, node1 `49.40 GiB`

## Phase Throughput

Friendly phase uses Mops/s. Unfriendly phase uses MiB/s.

| phase | workload | off | on | Miracle | on/off | Miracle/off |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | move60s-hotset-4g-remote | 228.44 Mops/s | 1443.90 Mops/s | 1427.71 Mops/s | 6.321x | 6.250x |
| 2 | stream-read-32g-split16-4k | 4506.87 MiB/s | 2759.56 MiB/s | 2136.38 MiB/s | 0.612x | 0.474x |

## Overall And Counters

Overall mixed Mops/s is secondary because the two phases use different effective units.

| policy | overall mean | promoted | demoted | hint faults | PTE updates |
| --- | ---: | ---: | ---: | ---: | ---: |
| off | 397.14 Mops/s | 0.00 GiB | 0.00 GiB | 0 | 0.00 GiB |
| on | 894.63 Mops/s | 38.68 GiB | 37.78 GiB | 39,435,452 | 178.57 GiB |
| Miracle | 847.30 Mops/s | 15.76 GiB | 14.94 GiB | 14,508,389 | 79.47 GiB |

## Phase Migration Counters

| policy | phase | hint faults | PTE updates | promoted | demoted |
| --- | ---: | ---: | ---: | ---: | ---: |
| off | 1 | 0 | 0.00 GiB | 0.00 GiB | 0.00 GiB |
| off | 2 | 0 | 0.00 GiB | 0.00 GiB | 0.00 GiB |
| on | 1 | 8,778,792 | 77.61 GiB | 15.11 GiB | 15.35 GiB |
| on | 2 | 24,344,544 | 97.00 GiB | 22.84 GiB | 21.20 GiB |
| Miracle | 1 | 8,845,102 | 78.20 GiB | 15.52 GiB | 14.94 GiB |
| Miracle | 2 | 0 | 0.00 GiB | 0.00 GiB | 0.00 GiB |

## Notes

- Full `on` improves the friendly phase from `228.44` to `1443.90 Mops/s` (`6.321x`).
- Full `on` hurts the unfriendly stream phase from `4506.87` to `2759.56 MiB/s` (`0.612x`).
- Miracle preserves almost the same friendly benefit as `on` (`0.989x of on), but its unfriendly phase is lower than full `on` in this run (`0.774x of on`).
- Miracle controller log confirms phase 1 `node_balancing=2` and phase 2 `node_balancing=0` with global NUMA balancing kept at `0`.

## Artifacts

- `/Serverless/iccd/experiments/20260509-phase-fu2-move60-scan256-nofast-200s-miracle/summaries/summary.csv`
- `/Serverless/iccd/experiments/20260509-phase-fu2-move60-scan256-nofast-200s-miracle/summaries/phase_summary.csv`
- `/Serverless/iccd/experiments/20260509-phase-fu2-move60-scan256-nofast-200s-miracle/summaries/phase_migration.csv`
- raw root: `/Serverless/iccd/experiments/20260509-phase-fu2-move60-scan256-nofast-200s-miracle/qemu-logs/phase_candidate_microbench/20260509Tphase-fu2-move60-scan256-nofast-200s/guest-artifacts/20260509Tphase-fu2-move60-scan256-nofast-200s`
