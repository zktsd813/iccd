# Bound CXL refault comparison

- Run: `refault_compare_bound_cxl_20260507T054501Z`
- Artifact root: `/Serverless/iccd/experiments/20260507-refault-compare-bound-cxl/qemu-logs/phase_candidate_microbench/refault_compare_bound_cxl_20260507T054501Z/guest-artifacts/refault_compare_bound_cxl_20260507T054501Z`
- VM topology used by launcher: CPUs pinned to host node0 CPUs `0-31`; guest node0 memory `32G` bound to host node0 DRAM; guest node1 memory `64G` bound to host node2 CXL; `policy=bind`, `prealloc=on`. During the run, host pages were checked as approximately `N0 32.1 GiB`, `N2 64.0 GiB`.
- Local cgroup cap: `CAPACITY_PAGES=4194304` = 16 GiB. RSS/arena: 64 GiB. Phase length: 60 s. Policies: off+demotion, migration-on, adaptive_cgroup. Promotion sample rate knob was 10, and sampled refault stat collection was enabled.
- Previous unbound results should not be used for local-vs-CXL interpretation.

## Aggregate by phase kind
| candidate | policy | kind | n | Mops/s | refault/s | lat_us | promoted_GiB | N0_end_GiB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| friendly vs move16g3s | off+demotion | friendly_mulshift4g | 3 | 865.68 | 0.00 | 0.00 | 0.00 | 1.45 |
| friendly vs move16g3s | off+demotion | unfriendly_move16g3s | 3 | 448.60 | 0.00 | 0.00 | 0.00 | 1.40 |
| friendly vs move16g3s | migration-on | friendly_mulshift4g | 3 | 2,218.0 | 1,164.9 | 3.11 | 7.85 | 11.57 |
| friendly vs move16g3s | migration-on | unfriendly_move16g3s | 3 | 826.58 | 5,867.6 | 5.93 | 39.72 | 15.35 |
| friendly vs move16g3s | adaptive | friendly_mulshift4g | 3 | 2,564.9 | 1,551.7 | 5.12 | 10.53 | 9.47 |
| friendly vs move16g3s | adaptive | unfriendly_move16g3s | 3 | 792.30 | 0.00 | 0.00 | 0.00 | 10.82 |
| friendly vs sparse64 | off+demotion | friendly_mulshift4g | 3 | 598.97 | 0.00 | 0.00 | 0.00 | 0.97 |
| friendly vs sparse64 | off+demotion | unfriendly_sparse64 | 3 | 87.40 | 0.00 | 0.00 | 0.00 | 1.46 |
| friendly vs sparse64 | migration-on | friendly_mulshift4g | 3 | 1,486.3 | 1,055.3 | 1.59 | 7.12 | 11.61 |
| friendly vs sparse64 | migration-on | unfriendly_sparse64 | 3 | 90.90 | 1,555.7 | 1.42 | 10.54 | 15.62 |
| friendly vs sparse64 | adaptive | friendly_mulshift4g | 3 | 2,030.2 | 1,715.7 | 2.67 | 11.61 | 9.90 |
| friendly vs sparse64 | adaptive | unfriendly_sparse64 | 3 | 102.56 | 246.73 | 1.18 | 1.68 | 11.89 |

## Policy phase matrix
| candidate | phase | kind | off Mops/s | on Mops/s | ad Mops/s | on/off | ad/off | on ref/s | ad ref/s | on lat_us | ad lat_us |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| phase_mulshift4g_rot_move16g3s | 1 | friendly_mulshift4g | 1,400.2 | 3,088.7 | 3,031.5 | 2.21 | 2.17 | 1,029.3 | 1,121.1 | 3.80 | 2.59 |
| phase_mulshift4g_rot_move16g3s | 2 | unfriendly_move16g3s | 452.46 | 994.15 | 474.36 | 2.20 | 1.05 | 8,034.2 | 0.00 | 3.60 | 0.00 |
| phase_mulshift4g_rot_move16g3s | 3 | friendly_mulshift4g | 597.95 | 1,710.0 | 2,635.9 | 2.86 | 4.41 | 1,278.5 | 1,768.0 | 3.81 | 2.29 |
| phase_mulshift4g_rot_move16g3s | 4 | unfriendly_move16g3s | 446.53 | 731.64 | 919.51 | 1.64 | 2.06 | 4,611.8 | 0.00 | 10.98 | 0.00 |
| phase_mulshift4g_rot_move16g3s | 5 | friendly_mulshift4g | 598.90 | 1,855.3 | 2,027.2 | 3.10 | 3.38 | 1,186.7 | 1,766.1 | 1.71 | 10.49 |
| phase_mulshift4g_rot_move16g3s | 6 | unfriendly_move16g3s | 446.81 | 753.96 | 983.04 | 1.69 | 2.20 | 4,957.0 | 0.00 | 3.20 | 0.00 |
| phase_mulshift4g_rot_sparse64 | 1 | friendly_mulshift4g | 611.14 | 2,360.9 | 2,204.6 | 3.86 | 3.61 | 1,766.7 | 1,764.7 | 2.52 | 2.82 |
| phase_mulshift4g_rot_sparse64 | 2 | unfriendly_sparse64 | 86.73 | 86.73 | 96.69 | 1.00 | 1.11 | 3,635.7 | 0.00 | 2.16 | 0.00 |
| phase_mulshift4g_rot_sparse64 | 3 | friendly_mulshift4g | 600.65 | 1,362.0 | 2,050.4 | 2.27 | 3.41 | 1,398.6 | 1,762.9 | 2.25 | 2.83 |
| phase_mulshift4g_rot_sparse64 | 4 | unfriendly_sparse64 | 89.01 | 89.00 | 100.38 | 1.00 | 1.13 | 1,031.3 | 740.19 | 2.09 | 3.55 |
| phase_mulshift4g_rot_sparse64 | 5 | friendly_mulshift4g | 585.13 | 735.92 | 1,835.6 | 1.26 | 3.14 | 0.67 | 1,619.7 | 0.00 | 2.37 |
| phase_mulshift4g_rot_sparse64 | 6 | unfriendly_sparse64 | 86.45 | 96.97 | 110.62 | 1.12 | 1.28 | 0.00 | 0.00 | 0.00 | 0.00 |

## Initial observations
### friendly vs sparse64
- `friendly_mulshift4g`: on/off throughput ratio 2.48x; off 599.0 Mops/s, on 1486.3 Mops/s. On refault rate 1055.3/s, latency 1.59 us.
- `friendly_mulshift4g` adaptive/off throughput ratio 3.39x; adaptive refault rate 1715.7/s, latency 2.67 us.
- `unfriendly_sparse64`: on/off throughput ratio 1.04x; off 87.4 Mops/s, on 90.9 Mops/s. On refault rate 1555.7/s, latency 1.42 us.
- `unfriendly_sparse64` adaptive/off throughput ratio 1.17x; adaptive refault rate 246.7/s, latency 1.18 us.
### friendly vs move16g3s
- `friendly_mulshift4g`: on/off throughput ratio 2.56x; off 865.7 Mops/s, on 2218.0 Mops/s. On refault rate 1164.9/s, latency 3.11 us.
- `friendly_mulshift4g` adaptive/off throughput ratio 2.96x; adaptive refault rate 1551.7/s, latency 5.12 us.
- `unfriendly_move16g3s`: on/off throughput ratio 1.84x; off 448.6 Mops/s, on 826.6 Mops/s. On refault rate 5867.6/s, latency 5.93 us.
- `unfriendly_move16g3s` adaptive/off throughput ratio 1.77x; adaptive refault rate 0.0/s, latency 0.00 us.

## Files
- Phase metrics CSV: `/Serverless/iccd/experiments/20260507-refault-compare-bound-cxl/summaries/phase_refault_metrics.csv`
- Aggregate CSV: `/Serverless/iccd/experiments/20260507-refault-compare-bound-cxl/summaries/aggregate_refault_metrics.csv`
- Policy matrix CSV: `/Serverless/iccd/experiments/20260507-refault-compare-bound-cxl/summaries/policy_phase_matrix.csv`
- Graphs: `/Serverless/iccd/experiments/20260507-refault-compare-bound-cxl/graphs`
