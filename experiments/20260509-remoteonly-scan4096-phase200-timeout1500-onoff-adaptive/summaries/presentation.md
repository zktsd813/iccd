# Remote-only 200s Phase Result

Run: `20260509T0330Z-remoteonly-scan4096-phase200-t1500`

Graphs:

- Throughput by phase: `graphs/phase200_throughput_by_phase.svg`
- Adaptive counters: `graphs/phase200_adaptive_faults_promotions.svg`

## Phase Mean Throughput

Friendly phases use Mops/s. Unfriendly phases use MB/s.

| phase | kind | off | on | adaptive | unit |
| --- | --- | ---: | ---: | ---: | --- |
| 1 | friendly | 228.33 | 271.48 | 274.69 | Mops/s |
| 2 | unfriendly | 4518.59 | 2280.98 | 3932.91 | MB/s |
| 3 | friendly | 228.20 | 691.58 | 439.58 | Mops/s |
| 4 | unfriendly | 4519.67 | 3022.21 | 4210.88 | MB/s |
| 5 | friendly | 228.06 | 736.38 | 742.07 | Mops/s |
| 6 | unfriendly | 4519.86 | 3354.95 | 2522.70 | MB/s |

## Aggregate

| policy | friendly mean Mops/s | unfriendly mean MB/s | promoted GiB | demoted GiB | hint faults |
| --- | ---: | ---: | ---: | ---: | ---: |
| off | 228.20 | 4519.38 | 0.00 | 0.00 | 0 |
| on | 566.48 | 2886.05 | 43.13 | 42.25 | 86060644 |
| adaptive | 485.45 | 3555.50 | 25.33 | 24.76 | 54887081 |

## Adaptive Phase Counters

| phase | kind | hint faults | promotions | reclaimd runs |
| --- | --- | ---: | ---: | ---: |
| 1 | friendly | 17943849 | 3019406 | 6 |
| 2 | unfriendly | 0 | 0 | 0 |
| 3 | friendly | 13626212 | 1384233 | 3 |
| 4 | unfriendly | 0 | 0 | 0 |
| 5 | friendly | 13124055 | 1701571 | 5 |
| 6 | unfriendly | 2623821 | 0 | 0 |

## Short Read

- Full `on` gives the best friendly mean but hurts unfriendly throughput.
- `adaptive` reduces hint faults and migration volume versus full `on`.
- `adaptive` recovers unfriendly phases 2 and 4 well, but phase 6 is weak.
- Phase 6 has only early hint faults and no useful promotions, so the drop is
  more consistent with inherited placement from phase 5 than with ongoing fault
  overhead throughout phase 6.
