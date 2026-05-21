# Local Util Adaptive vs Full On/Off

Compared using existing artifacts only. `full_off` is from the 2026-05-09 baseline kernel `#163`; `full_on` and `adaptive_localutil80x3` are from the 2026-05-10 kernel `#172`, so off comparisons have a kernel-version caveat.

## Throughput
| policy | off time | Friendly Mops/s | vs off | vs full on | Unfriendly MB/s | vs off | vs full on |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| full_off | start | 227.21 | 1.000x | 0.210x | 4511.39 | 1.000x | 1.266x |
| full_on | never | 1083.49 | 4.769x | 1.000x | 3563.01 | 0.790x | 1.000x |
| adaptive_localutil80x3 | 40.3 | 1093.26 | 4.812x | 1.009x | 4108.40 | 0.911x | 1.153x |

## Migration Cost
| policy | hints | PTE updates | promoted GiB | demoted GiB |
| --- | ---: | ---: | ---: | ---: |
| full_off | 0 | 0 | 0.00 | 0.00 |
| full_on | 21,743,669 | 29,912,483 | 16.54 | 16.65 |
| adaptive_localutil80x3 | 3,936,352 | 15,471,078 | 6.75 | 6.32 |

## Main Delta
- `adaptive_localutil80x3` turns migration off at `40.3s` after 3 consecutive high-utilization windows.
- Friendly throughput is essentially preserved vs full on: `1093.26` vs `1083.49` Mops/s (`1.009x`).
- Unfriendly throughput recovers from full on: `4108.40` vs `3563.01` MB/s (`1.153x`), but remains below full off `4511.39` MB/s (`0.911x`).
- Migration cost drops sharply vs full on: promoted `6.75` vs `16.54` GiB, demoted `6.32` vs `16.65` GiB.

## Optional Reference
The older phase-oracle adaptive result from 2026-05-09 switched off exactly at phase 2 and reached `4440.93 MB/s` in the unfriendly phase, closer to full off. The local-util trigger switched earlier at 40.3s, so phase 2 had zero migration counters but lower initial placement/state than the phase-oracle run.

## Files
- `/Serverless/iccd/experiments/20260509-fixed8g-remote16-split32-60s-adaptive/summaries/localutil80x3_vs_on_off.csv`
- `/Serverless/iccd/experiments/20260509-fixed8g-remote16-split32-60s-adaptive/summaries/localutil80x3_adaptive_analysis.md`
- `/Serverless/iccd/experiments/20260509-fixed8g-remote16-split32-60s-adaptive/summaries/localfault10_hit2000_on_analysis.md`
- `/Serverless/iccd/experiments/20260509-fixed8g-remote16-split32-60s-adaptive/summaries/analysis.md`
