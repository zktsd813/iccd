# Quick 30s unfriendly sweep

- Run: `quick30_20260507T072817Z`
- VM: guest node0 32G host node0 DRAM, guest node1 64G host node2 CXL, cgroup local cap 16G.
- Measurement: remote prefault only, then 30s measured run; no extra benchmark warmup. One rep per policy. off keeps demotion enabled; on enables cgroup NUMA balancing `0x2`.
- Ratio uses each candidate primary metric: `ops` -> Mops/s, `bytes` -> MB/s.

| rank | candidate | primary | off | on | on/off | delta | promoted on | hint faults on | blocked on |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | `pc_64g_stride_remoteft` | ops | 119.43 | 101.34 | 0.849x | -15.1% | 18.53 GiB | 109.5M | 0.52M |
| 2 | `sparse_stride_read_64g_remoteft` | bytes | 735.71 | 666.12 | 0.905x | -9.5% | 14.17 GiB | 9.4M | 0.00M |
| 3 | `index_rf_segmented_64g_span4k` | ops | 168.86 | 180.51 | 1.069x | +6.9% | 0.25 GiB | 0.1M | 0.00M |
| 4 | `index_rf_segmented_64g_span256k` | ops | 228.90 | 259.50 | 1.134x | +13.4% | 0.06 GiB | 0.0M | 0.00M |
| 5 | `index_rf_segmented_64g_span64k` | ops | 218.88 | 271.23 | 1.239x | +23.9% | 0.06 GiB | 0.0M | 0.00M |
| 6 | `skew_rf_read_8g_move_1s_mulshift_persistent` | ops | 441.90 | 1006.04 | 2.277x | +127.7% | 19.48 GiB | 28.8M | 0.33M |
| 7 | `skew_rf_read_16g_move_250ms_mulshift_persistent` | ops | 303.46 | 740.13 | 2.439x | +143.9% | 21.47 GiB | 37.8M | 0.35M |
| 8 | `skew_rf_read_12g_move_250ms_mulshift_persistent` | ops | 228.29 | 613.15 | 2.686x | +168.6% | 30.42 GiB | 31.7M | 0.33M |
| 9 | `skew_rf_read_12g_move_500ms_mulshift_persistent` | ops | 230.99 | 636.34 | 2.755x | +175.5% | 27.91 GiB | 32.0M | 0.34M |
| 10 | `skew_rf_read_16g_move_500ms_mulshift_persistent` | ops | 325.26 | 947.40 | 2.913x | +191.3% | 22.12 GiB | 33.0M | 0.31M |

## Selected for deep run

- `pc_64g_stride_remoteft`: quick on/off 0.849 (-15.1%).
- `sparse_stride_read_64g_remoteft`: quick on/off 0.905 (-9.5%).
- `index_rf_segmented_64g_span4k`: quick on/off 1.069 (+6.9%).
