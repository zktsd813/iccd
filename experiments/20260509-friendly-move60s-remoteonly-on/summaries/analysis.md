# Friendly-only move-60s remote-only migration-on

Run: `20260509T0723Z-friendly-move60s-remoteonly-on`

Candidate added locally:
`skew_lf_hotremote_4g_move_60s_remoteonly_mulshift_persistent`

Shape:

- Friendly-only `skewed-hotset`
- 4 GiB hotset
- Read-only, `mulshift`
- `move-policy=random`
- `move-step=4G`
- `move-min-offset=16G`, `move-max-offset=60G`
- `move-interval-ms=60000`
- potential hotset windows first-touched on remote node1
- policy: migration `on` only
- duration: `120000 ms`

Config:

- `NUMA_SCAN_SIZE_MB=4096`
- `SCAN_PERIOD_SCALE=100`
- `HOT_THRESHOLD_MS=0`
- `CAPACITY_PAGES=4194304`
- `MGLRU=0x0007`
- kernel `6.18.0modified #157`

## Overall

| metric | value |
| --- | ---: |
| return code | 0 |
| mean | 1289.93 Mops/s |
| median | 1799.36 Mops/s |
| promoted | 2100132 pages, 8.01 GiB |
| demoted | 1754430 pages, 6.69 GiB |
| hint faults | 4696404 |
| reclaimd runs | 4 |

## 60s Windows

| window | hotset offset | mean Mops/s | median Mops/s | hint faults | promotions | direct demotions | node0 active anon |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 0-60s | 16G | 1451.68 | 1800.40 | 1685875 | 1050384 | 873104 | 0.00 -> 3.63 GiB |
| 60-120s | 20G | 1108.70 | 409.67 | 2803654 | 891479 | 881326 | 3.63 -> 2.84 GiB |

## 15s Sub-Buckets

| bucket | offset | mean Mops/s | median Mops/s | hint faults | promotions | direct demotions | node0 active anon |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0-15s | 16G | 514.82 | 516.16 | 2 | 1 | 0 | 0.00 GiB |
| 15-30s | 16G | 1632.59 | 1843.66 | 849646 | 312359 | 434560 | 1.86 GiB |
| 30-45s | 16G | 1822.01 | 1835.66 | 556176 | 483460 | 438544 | 3.54 GiB |
| 45-60s | 16G | 1800.02 | 1800.80 | 26854 | 24414 | 0 | 3.63 GiB |
| 60-75s | 20G | 316.91 | 395.25 | 0 | 0 | 0 | 3.63 GiB |
| 75-90s | 20G | 407.70 | 408.62 | 2140284 | 431226 | 337666 | 1.27 GiB |
| 90-105s | 20G | 1831.15 | 1990.66 | 0 | 0 | 46528 | 1.27 GiB |
| 105-120s | 20G | 1879.04 | 1803.81 | 663370 | 460253 | 440684 | 2.84 GiB |

## Interpretation

The 60s interval fixes the main weakness seen with 15s movement. With 15s
movement, promotion often arrived just as the hotset moved away. With 60s
movement, the hotset stays long enough for NUMA scanning and promotion to catch
up.

In the first 60s window, the first 15s are still cold, but by 15-30s the
working set starts to land on node0 and throughput jumps above 1.6G Mops/s.
By 30-60s it is steady around 1.8G Mops/s.

The second 60s window repeats the same shape: the first 30s are lower after the
offset changes from 16G to 20G, then throughput climbs back to 1.8-2.0G Mops/s.

This supports the earlier diagnosis: the friendly access pattern itself is
migration-friendly, but the 15s movement interval was too short relative to
the scan/promotion timing.
