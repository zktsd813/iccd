# Combined quick 30s sweep

| rank | run | candidate | primary | off | on | on/off | delta | promote GiB | hints | blocked |
|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | `quick30b_20260507T080015Z` | `sparse_stride_read_64g_block2m_remoteft` | bytes | 437.45 | 109.36 | 0.250x | -75.0% | 14.19 | 16.2M | 0.00M |
| 2 | `quick30b_20260507T080015Z` | `sparse_stride_write_64g_remoteft` | bytes | 462.31 | 387.17 | 0.837x | -16.3% | 14.18 | 6.8M | 0.00M |
| 3 | `quick30_20260507T072817Z` | `pc_64g_stride_remoteft` | ops | 119.43 | 101.34 | 0.849x | -15.1% | 18.53 | 109.5M | 0.52M |
| 4 | `quick30_20260507T072817Z` | `sparse_stride_read_64g_remoteft` | bytes | 735.71 | 666.12 | 0.905x | -9.5% | 14.17 | 9.4M | 0.00M |
| 5 | `quick30b_20260507T080015Z` | `pc_64g_stride_remoteft` | ops | 118.01 | 107.79 | 0.913x | -8.7% | 17.59 | 92.2M | 0.37M |
| 6 | `quick30b_20260507T080015Z` | `irregular_uniform_sweep_32g_remoteft` | ops | 147.11 | 152.78 | 1.039x | +3.9% | 3.19 | 0.9M | 0.00M |
| 7 | `quick30b_20260507T080015Z` | `pc_48g_stride_remoteft` | ops | 91.79 | 97.93 | 1.067x | +6.7% | 14.92 | 71.0M | 0.35M |
| 8 | `quick30_20260507T072817Z` | `index_rf_segmented_64g_span4k` | ops | 168.86 | 180.51 | 1.069x | +6.9% | 0.25 | 0.1M | 0.00M |
| 9 | `quick30b_20260507T080015Z` | `irregular_uniform_sweep_64g_remoteft` | ops | 119.30 | 127.76 | 1.071x | +7.1% | 1.00 | 0.3M | 0.00M |
| 10 | `quick30_20260507T072817Z` | `index_rf_segmented_64g_span256k` | ops | 228.90 | 259.50 | 1.134x | +13.4% | 0.06 | 0.0M | 0.00M |
| 11 | `quick30_20260507T072817Z` | `index_rf_segmented_64g_span64k` | ops | 218.88 | 271.23 | 1.239x | +23.9% | 0.06 | 0.0M | 0.00M |
| 12 | `quick30b_20260507T080015Z` | `pc_32g_stride_remoteft` | ops | 127.42 | 171.88 | 1.349x | +34.9% | 14.52 | 47.1M | 0.34M |
| 13 | `quick30_20260507T072817Z` | `skew_rf_read_8g_move_1s_mulshift_persistent` | ops | 441.90 | 1006.04 | 2.277x | +127.7% | 19.48 | 28.8M | 0.33M |
| 14 | `quick30_20260507T072817Z` | `skew_rf_read_16g_move_250ms_mulshift_persistent` | ops | 303.46 | 740.13 | 2.439x | +143.9% | 21.47 | 37.8M | 0.35M |
| 15 | `quick30_20260507T072817Z` | `skew_rf_read_12g_move_250ms_mulshift_persistent` | ops | 228.29 | 613.15 | 2.686x | +168.6% | 30.42 | 31.7M | 0.33M |
| 16 | `quick30_20260507T072817Z` | `skew_rf_read_12g_move_500ms_mulshift_persistent` | ops | 230.99 | 636.34 | 2.755x | +175.5% | 27.91 | 32.0M | 0.34M |
| 17 | `quick30_20260507T072817Z` | `skew_rf_read_16g_move_500ms_mulshift_persistent` | ops | 325.26 | 947.40 | 2.913x | +191.3% | 22.12 | 33.0M | 0.31M |
