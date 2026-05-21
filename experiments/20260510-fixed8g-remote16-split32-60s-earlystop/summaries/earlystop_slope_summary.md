# Earlystop Slope Estimates

Kernel does not export the internal `slope` field in `live.csv`, so this file reconstructs it from `cg_earlystop_current_demote_promoted`.
The formula mirrors the kernel shape: `slope = (delta[current] - delta[two_samples_back]) / 2`.
`1s_live` uses the live sampler cadence; `2s_downsample_est` is closer to `numa_earlystopd`, which checks every 2 seconds, but it is still a post-hoc estimate because the daemon tick is not timestamped.

Initial constants: `MEMCG_NUMA_EARLYSTOP_THRESHOLD=10000`, `MEMCG_NUMA_EARLYSTOP_SLOPE_MAX=20000`.

## 2s Estimate Around ON Phase2
| elapsed | phase2 rel | current | delta_current | slope_est | threshold_est | below? | cnt |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 80.607s | +20.607s | 66131 | 35353 | 17676 | 10000 | 0 | 0 |
| 82.668s | +22.668s | 133768 | 67637 | 18458 | 10000 | 0 | 0 |
| 84.758s | +24.758s | 196920 | 63152 | 13899 | 10000 | 0 | 0 |
| 86.842s | +26.842s | 261010 | 64090 | -1774 | 10000 | 1 | 0 |
| 88.894s | +28.894s | 301182 | 40172 | -11490 | 10000 | 0 | 1 |
| 90.978s | +30.978s | 314993 | 13811 | -25140 | 10000 | 0 | 1 |
| 93.037s | +33.037s | 394360 | 79367 | 19597 | 10000 | 0 | 2 |
| 95.079s | +35.079s | 485644 | 91284 | 38736 | 10000 | 0 | 1 |
| 97.183s | +37.183s | 517379 | 31735 | -23816 | 10000 | 0 | 1 |
| 99.273s | +39.273s | 517671 | 292 | -45496 | 10000 | 0 | 1 |
| 101.354s | +41.354s | 580493 | 62822 | 15543 | 10000 | 0 | 0 |
| 103.393s | +43.393s | 646864 | 66371 | 33039 | 10000 | 0 | 0 |
| 105.513s | +45.513s | 681912 | 35048 | -13887 | 10000 | 0 | 0 |
| 107.580s | +47.580s | 763134 | 81222 | 7425 | 10000 | 1 | 1 |
| 109.653s | +49.653s | 828112 | 64978 | 14965 | 10000 | 0 | 2 |
| 111.707s | +51.707s | 921383 | 93271 | 6024 | 10000 | 1 | 1 |
| 113.765s | +53.765s | 982953 | 61570 | -1704 | 10000 | 1 | 1 |
| 115.815s | +55.815s | 982961 | 8 | -46632 | 10000 | 0 | 1 |
| 117.861s | +57.861s | 982964 | 3 | -30784 | 10000 | 0 | 0 |

## Event Focus, 2s Estimate
| event elapsed | phase2 rel | cnt change | nearest sample | delta_current | slope_est | threshold_est | below? | cnt sample |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 88.894s | +28.894s | 0->1 | 88.894s | 40172 | -11490 | 10000 | 0 | 1 |
| 92.010s | +32.010s | 1->2 | 93.037s | 79367 | 19597 | 10000 | 0 | 2 |
| 94.059s | +34.059s | 2->1 | 95.079s | 91284 | 38736 | 10000 | 0 | 1 |
| 100.328s | +40.328s | 1->0 | 101.354s | 62822 | 15543 | 10000 | 0 | 0 |
| 106.542s | +46.542s | 0->1 | 105.513s | 35048 | -13887 | 10000 | 0 | 0 |
| 108.606s | +48.606s | 1->2 | 107.580s | 81222 | 7425 | 10000 | 1 | 1 |
| 110.683s | +50.683s | 2->1 | 111.707s | 93271 | 6024 | 10000 | 1 | 1 |
| 116.835s | +56.835s | 1->0 | 115.815s | 8 | -46632 | 10000 | 0 | 1 |

## Files
- `earlystop_slope_estimates.csv`: full 1s and 2s estimated slope timeline
- `earlystop_slope_event_focus.csv`: slope estimate near each `earlystop_cnt` transition
