# on/off 3-run average

- Experiment: `20260507-unfriendly64-pc64-onoff-reps-bound-cxl`
- Run ID: `unfriendly64_pc64_onoff_reps_20260507T065736Z`
- VM: 32 vCPU on guest node0, guest node0 32G bound to host node0 DRAM, guest node1 64G bound to host node2 CXL, cgroup local cap 16G.
- Microbench: RSS/arena 64G, 32 threads, remote-firsttouch, 60s measured duration, 3 reps, global NUMA balancing off, cgroup NUMA balancing `0x2`, demotion enabled for off/on, scan size 2048MB.
- Throughput below is the average of per-run steady CSV means. `Mops/s` is from `ops_delta`; `MB/s` is from `bytes_delta`. The two workloads count bytes differently, so use on/off ratio within each workload as the main comparison.

| workload | policy | n | mean Mops/s | sd | on/off | mean MB/s | sd | promote GiB avg | hint faults avg | blocked avg |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| pointer-chase unfriendly / pc_64g_stride_remoteft | off | 3 | 118.54 | 0.75 |  | 7586.5 | 48.1 | 0.00 | 0.0M | 0.00M |
| pointer-chase unfriendly / pc_64g_stride_remoteft | on | 3 | 102.80 | 6.16 | 0.867x | 6578.9 | 394.5 | 20.37 | 214.0M | 0.93M |
| unfriendly64 / sparse_stride_read_64g_remoteft | off | 3 | 91.33 | 0.08 |  | 730.7 | 0.6 | 0.00 | 0.0M | 0.00M |
| unfriendly64 / sparse_stride_read_64g_remoteft | on | 3 | 85.55 | 0.17 | 0.937x | 684.4 | 1.4 | 14.16 | 11.2M | 0.00M |

## Per-run values

| workload | policy | rep | Mops/s | MB/s | promote GiB | hint faults | blocked | return |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| pointer-chase unfriendly / pc_64g_stride_remoteft | off | 1 | 119.38 | 7640.0 | 0.00 | 0.0M | 0.00M | 0 |
| pointer-chase unfriendly / pc_64g_stride_remoteft | off | 2 | 118.32 | 7572.6 | 0.00 | 0.0M | 0.00M | 0 |
| pointer-chase unfriendly / pc_64g_stride_remoteft | off | 3 | 117.92 | 7546.9 | 0.00 | 0.0M | 0.00M | 0 |
| pointer-chase unfriendly / pc_64g_stride_remoteft | on | 1 | 105.37 | 6743.5 | 20.39 | 209.9M | 0.88M | 0 |
| pointer-chase unfriendly / pc_64g_stride_remoteft | on | 2 | 107.26 | 6864.5 | 19.84 | 182.3M | 0.77M | 0 |
| pointer-chase unfriendly / pc_64g_stride_remoteft | on | 3 | 95.76 | 6128.8 | 20.89 | 249.8M | 1.15M | 0 |
| unfriendly64 / sparse_stride_read_64g_remoteft | off | 1 | 91.38 | 731.0 | 0.00 | 0.0M | 0.00M | 0 |
| unfriendly64 / sparse_stride_read_64g_remoteft | off | 2 | 91.38 | 731.0 | 0.00 | 0.0M | 0.00M | 0 |
| unfriendly64 / sparse_stride_read_64g_remoteft | off | 3 | 91.24 | 730.0 | 0.00 | 0.0M | 0.00M | 0 |
| unfriendly64 / sparse_stride_read_64g_remoteft | on | 1 | 85.36 | 682.9 | 14.19 | 12.1M | 0.00M | 0 |
| unfriendly64 / sparse_stride_read_64g_remoteft | on | 2 | 85.65 | 685.2 | 14.12 | 10.5M | 0.00M | 0 |
| unfriendly64 / sparse_stride_read_64g_remoteft | on | 3 | 85.65 | 685.2 | 14.17 | 11.0M | 0.00M | 0 |

## Notes

- `pc_64g_stride_remoteft`: on/off by Mops/s = 0.867 (-13.3%).
- `sparse_stride_read_64g_remoteft`: on/off by Mops/s = 0.937 (-6.3%).
- All 12 runs returned `0`; no timeout/failure was observed.
