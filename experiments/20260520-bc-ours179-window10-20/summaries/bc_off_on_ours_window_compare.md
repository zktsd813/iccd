# BC off/on/ours window comparison

Workload: `/root/bc -f /root/gapbs_graphs/kron_g28.sg -i1 -n 8`

| cap | off | on | ours 5s | ours 10s | ours 20s |
| --- | ---: | ---: | ---: | ---: | ---: |
| 8G | 16.39678 | 52.61184 | 41.69187 | 36.72230 | 41.60252 |
| 16G | 49.38733 | 19.98134 | 14.17649 | 23.23782 | 25.90131 |

Notes:
- `off`: #178 node-capacity off baseline.
- `on`: #179 migration-on baseline.
- `ours 5s`: #179 local-fault adaptive controller, window 5s.
- `ours 10s` and `ours 20s`: #179 rerun from `20260520-bc-ours179-window10-20`.

Stop points for `ours`:

| cap | window | off time s | off window | reason |
| --- | ---: | ---: | ---: | --- |
| 8G | 5 | 70.027 | 14 | local_access |
| 8G | 10 | 90.013 | 9 | local_access |
| 8G | 20 | 140.009 | 7 | local_access |
| 16G | 5 | 45.020 | 9 | local_access |
| 16G | 10 | 90.012 | 9 | local_access |
| 16G | 20 | 100.006 | 5 | local_access |
