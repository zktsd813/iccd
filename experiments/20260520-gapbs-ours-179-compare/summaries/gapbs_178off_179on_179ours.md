# GAPBS #178 off vs #179 on vs #179 ours

Values are average trial seconds. Lower is better.

| workload | cap | #178 off | #179 on | #179 ours |
| --- | --- | ---: | ---: | ---: |
| PR | 8G | 18.873 | 45.412 | 20.184 |
| PR | 16G | 19.067 | 44.052 | 19.778 |
| BC | 8G | 16.397 | 52.612 | 41.692 |
| BC | 16G | 49.387 | 19.981 | 14.176 |

Normalized to `#178 off`:

| workload | cap | #179 on / #178 off | #179 ours / #178 off |
| --- | --- | ---: | ---: |
| PR | 8G | 2.406x | 1.069x |
| PR | 16G | 2.310x | 1.037x |
| BC | 8G | 3.209x | 2.543x |
| BC | 16G | 0.405x | 0.287x |

Ours stop points:

| workload | cap | stop |
| --- | --- | --- |
| PR | 8G | 45.0s, window 9, local_access |
| PR | 16G | 35.0s, window 7, local_access |
| BC | 8G | 70.0s, window 14, local_access |
| BC | 16G | 45.0s, window 9, local_access |

Graphs:

- `graphs/gapbs_178off_179on_179ours_avg_trial.png`
- `graphs/gapbs_178off_179on_179ours_normalized.png`
