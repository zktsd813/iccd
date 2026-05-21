# Refault Compare: refault_compare_rot_sparse64_move16g3s_20260507T044957Z

Settings: policies `off,on,adaptive_cgroup`; candidates `phase_mulshift4g_rot_sparse64` and `phase_mulshift4g_rot_move16g3s`; phase 60s x 6; local cgroup cap 16G; VM node0 32G, node1 64G; promote sample stat enabled rate=10; pingpong/migration-stop disabled.

## Aggregate

| candidate | policy | kind | avg Mops/s | refault/s | refault % | latency us | sampled | refaults | promotions |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| phase_mulshift4g_rot_move16g3s | adaptive_cgroup | friendly_mulshift4g | 3380.2 | 1499.0 | 100.0 | 9.0 | 269811 | 269811 | 2698054 |
| phase_mulshift4g_rot_move16g3s | adaptive_cgroup | unfriendly_move16g3s | 3105.2 | 526.8 | 100.0 | 5.6 | 94818 | 94817 | 948203 |
| phase_mulshift4g_rot_move16g3s | off | friendly_mulshift4g | 3458.8 | 0.0 | 0.0 | 0.0 | 0 | 0 | 0 |
| phase_mulshift4g_rot_move16g3s | off | unfriendly_move16g3s | 3248.7 | 0.0 | 0.0 | 0.0 | 0 | 0 | 0 |
| phase_mulshift4g_rot_move16g3s | on | friendly_mulshift4g | 3380.2 | 1433.2 | 100.0 | 3.8 | 257969 | 257969 | 2579698 |
| phase_mulshift4g_rot_move16g3s | on | unfriendly_move16g3s | 2651.7 | 7784.4 | 100.0 | 6.4 | 1401190 | 1401190 | 14011871 |
| phase_mulshift4g_rot_sparse64 | adaptive_cgroup | friendly_mulshift4g | 3165.9 | 1711.7 | 100.0 | 8.5 | 308099 | 308099 | 3080972 |
| phase_mulshift4g_rot_sparse64 | adaptive_cgroup | unfriendly_sparse64 | 153.0 | 593.9 | 100.0 | 3.6 | 106900 | 106900 | 1069017 |
| phase_mulshift4g_rot_sparse64 | off | friendly_mulshift4g | 3307.2 | 0.0 | 0.0 | 0.0 | 0 | 0 | 0 |
| phase_mulshift4g_rot_sparse64 | off | unfriendly_sparse64 | 151.9 | 0.0 | 0.0 | 0.0 | 0 | 0 | 0 |
| phase_mulshift4g_rot_sparse64 | on | friendly_mulshift4g | 3268.9 | 1061.2 | 100.0 | 3.7 | 191018 | 191018 | 1910069 |
| phase_mulshift4g_rot_sparse64 | on | unfriendly_sparse64 | 98.7 | 2785.5 | 100.0 | 13.3 | 501392 | 501392 | 5014031 |

## Phase Detail

| candidate | policy | phase | kind | phase name | mean Mops/s | mean MB/s | refault/s | refault % | latency us | refaults | sampled |
|---|---:|---:|---|---|---:|---:|---:|---:|---:|---:|---:|
| phase_mulshift4g_rot_move16g3s | off | 1 | friendly_mulshift4g | mulshift-hotset-4g-off0g | 3493.1 | 223556.0 | 0.0 | 0.0 | 0.0 | 0 | 0 |
| phase_mulshift4g_rot_move16g3s | off | 2 | unfriendly_move16g3s | mulshift-hotset-16g-move-3s | 3187.0 | 203969.0 | 0.0 | 0.0 | 0.0 | 0 | 0 |
| phase_mulshift4g_rot_move16g3s | off | 3 | friendly_mulshift4g | mulshift-hotset-4g-off24g | 3363.7 | 215278.1 | 0.0 | 0.0 | 0.0 | 0 | 0 |
| phase_mulshift4g_rot_move16g3s | off | 4 | unfriendly_move16g3s | mulshift-hotset-16g-move-3s | 3277.8 | 209778.7 | 0.0 | 0.0 | 0.0 | 0 | 0 |
| phase_mulshift4g_rot_move16g3s | off | 5 | friendly_mulshift4g | mulshift-hotset-4g-off48g | 3519.5 | 225249.4 | 0.0 | 0.0 | 0.0 | 0 | 0 |
| phase_mulshift4g_rot_move16g3s | off | 6 | unfriendly_move16g3s | mulshift-hotset-16g-move-3s | 3281.4 | 210010.0 | 0.0 | 0.0 | 0.0 | 0 | 0 |
| phase_mulshift4g_rot_move16g3s | on | 1 | friendly_mulshift4g | mulshift-hotset-4g-off0g | 3480.8 | 222771.2 | 1102.7 | 100.0 | 4.4 | 66159 | 66159 |
| phase_mulshift4g_rot_move16g3s | on | 2 | unfriendly_move16g3s | mulshift-hotset-16g-move-3s | 2807.6 | 179687.3 | 9556.8 | 100.0 | 8.6 | 573410 | 573410 |
| phase_mulshift4g_rot_move16g3s | on | 3 | friendly_mulshift4g | mulshift-hotset-4g-off24g | 3405.3 | 217941.4 | 1559.3 | 100.0 | 4.0 | 93560 | 93560 |
| phase_mulshift4g_rot_move16g3s | on | 4 | unfriendly_move16g3s | mulshift-hotset-16g-move-3s | 2766.9 | 177080.5 | 5385.5 | 100.0 | 2.7 | 323130 | 323130 |
| phase_mulshift4g_rot_move16g3s | on | 5 | friendly_mulshift4g | mulshift-hotset-4g-off48g | 3254.4 | 208284.3 | 1637.5 | 100.0 | 3.3 | 98250 | 98250 |
| phase_mulshift4g_rot_move16g3s | on | 6 | unfriendly_move16g3s | mulshift-hotset-16g-move-3s | 2380.7 | 152362.1 | 8410.8 | 100.0 | 6.3 | 504650 | 504650 |
| phase_mulshift4g_rot_move16g3s | adaptive_cgroup | 1 | friendly_mulshift4g | mulshift-hotset-4g-off0g | 3431.3 | 219605.2 | 1001.5 | 100.0 | 4.5 | 60092 | 60092 |
| phase_mulshift4g_rot_move16g3s | adaptive_cgroup | 2 | unfriendly_move16g3s | mulshift-hotset-16g-move-3s | 3073.4 | 196698.0 | 297.4 | 100.0 | 5.4 | 17847 | 17847 |
| phase_mulshift4g_rot_move16g3s | adaptive_cgroup | 3 | friendly_mulshift4g | mulshift-hotset-4g-off24g | 3408.1 | 218117.0 | 1747.7 | 100.0 | 6.5 | 104860 | 104860 |
| phase_mulshift4g_rot_move16g3s | adaptive_cgroup | 4 | unfriendly_move16g3s | mulshift-hotset-16g-move-3s | 3113.3 | 199251.0 | 832.7 | 100.0 | 4.6 | 49960 | 49961 |
| phase_mulshift4g_rot_move16g3s | adaptive_cgroup | 5 | friendly_mulshift4g | mulshift-hotset-4g-off48g | 3301.3 | 211281.1 | 1747.7 | 100.0 | 14.2 | 104859 | 104859 |
| phase_mulshift4g_rot_move16g3s | adaptive_cgroup | 6 | unfriendly_move16g3s | mulshift-hotset-16g-move-3s | 3128.9 | 200250.5 | 450.2 | 100.0 | 7.6 | 27010 | 27010 |
| phase_mulshift4g_rot_sparse64 | off | 1 | friendly_mulshift4g | mulshift-hotset-4g-off40g | 3476.5 | 222493.6 | 0.0 | 0.0 | 0.0 | 0 | 0 |
| phase_mulshift4g_rot_sparse64 | off | 2 | unfriendly_sparse64 | sparse-stride-read-64g | 148.4 | 1187.5 | 0.0 | 0.0 | 0.0 | 0 | 0 |
| phase_mulshift4g_rot_sparse64 | off | 3 | friendly_mulshift4g | mulshift-hotset-4g-off48g | 3238.0 | 207232.4 | 0.0 | 0.0 | 0.0 | 0 | 0 |
| phase_mulshift4g_rot_sparse64 | off | 4 | unfriendly_sparse64 | sparse-stride-read-64g | 154.4 | 1235.3 | 0.0 | 0.0 | 0.0 | 0 | 0 |
| phase_mulshift4g_rot_sparse64 | off | 5 | friendly_mulshift4g | mulshift-hotset-4g-off56g | 3207.0 | 205248.5 | 0.0 | 0.0 | 0.0 | 0 | 0 |
| phase_mulshift4g_rot_sparse64 | off | 6 | unfriendly_sparse64 | sparse-stride-read-64g | 153.0 | 1223.9 | 0.0 | 0.0 | 0.0 | 0 | 0 |
| phase_mulshift4g_rot_sparse64 | on | 1 | friendly_mulshift4g | mulshift-hotset-4g-off40g | 3493.2 | 223566.3 | 1747.7 | 100.0 | 2.6 | 104859 | 104859 |
| phase_mulshift4g_rot_sparse64 | on | 2 | unfriendly_sparse64 | sparse-stride-read-64g | 73.1 | 584.7 | 7666.8 | 100.0 | 14.2 | 460010 | 460010 |
| phase_mulshift4g_rot_sparse64 | on | 3 | friendly_mulshift4g | mulshift-hotset-4g-off48g | 3199.5 | 204765.1 | 1435.5 | 100.0 | 5.1 | 86130 | 86130 |
| phase_mulshift4g_rot_sparse64 | on | 4 | unfriendly_sparse64 | sparse-stride-read-64g | 104.1 | 832.6 | 689.7 | 100.0 | 3.5 | 41381 | 41381 |
| phase_mulshift4g_rot_sparse64 | on | 5 | friendly_mulshift4g | mulshift-hotset-4g-off56g | 3114.1 | 199303.7 | 0.5 | 100.0 | 0.0 | 29 | 29 |
| phase_mulshift4g_rot_sparse64 | on | 6 | unfriendly_sparse64 | sparse-stride-read-64g | 118.9 | 950.9 | 0.0 | 100.0 | 0.0 | 1 | 1 |
| phase_mulshift4g_rot_sparse64 | adaptive_cgroup | 1 | friendly_mulshift4g | mulshift-hotset-4g-off40g | 3382.9 | 216503.4 | 1747.7 | 100.0 | 2.8 | 104859 | 104859 |
| phase_mulshift4g_rot_sparse64 | adaptive_cgroup | 2 | unfriendly_sparse64 | sparse-stride-read-64g | 152.1 | 1217.1 | 179.7 | 100.0 | 3.0 | 10780 | 10780 |
| phase_mulshift4g_rot_sparse64 | adaptive_cgroup | 3 | friendly_mulshift4g | mulshift-hotset-4g-off48g | 3104.2 | 198672.0 | 1735.2 | 100.0 | 4.7 | 104110 | 104110 |
| phase_mulshift4g_rot_sparse64 | adaptive_cgroup | 4 | unfriendly_sparse64 | sparse-stride-read-64g | 155.0 | 1239.8 | 1190.2 | 100.0 | 4.1 | 71410 | 71410 |
| phase_mulshift4g_rot_sparse64 | adaptive_cgroup | 5 | friendly_mulshift4g | mulshift-hotset-4g-off56g | 3010.7 | 192683.7 | 1652.2 | 100.0 | 18.3 | 99130 | 99130 |
| phase_mulshift4g_rot_sparse64 | adaptive_cgroup | 6 | unfriendly_sparse64 | sparse-stride-read-64g | 151.9 | 1214.8 | 411.8 | 100.0 | 2.6 | 24710 | 24710 |

Raw artifact root: `/Serverless/iccd/experiments/20260507-refault-compare-phase/qemu-logs/phase_candidate_microbench/refault_compare_rot_sparse64_move16g3s_20260507T044957Z/guest-artifacts/refault_compare_rot_sparse64_move16g3s_20260507T044957Z`
