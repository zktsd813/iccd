# BC ours window 10/20 rerun (#179)

- Workload: `/root/bc -f /root/gapbs_graphs/kron_g28.sg -i1 -n 8`
- Kernel: `Linux kernel 6.18.0modified #179 SMP PREEMPT_DYNAMIC Wed May 20 03:30:57 UTC 2026`
- VM: 96G, 32 vCPUs, guest node0 32G on host node0, guest node1 64G on host node2, KVM, bind/prealloc
- Runtime knobs: MGLRU `0x0007`, scan size 256MB, scan period min 1000ms, fast scan off, hot threshold 0
- Ours policy: local fault sample 10%, local access threshold 80% x3 windows, remote ratio threshold 20% x3 windows, eval lag `prev`

## New runs

| cap | window | avg trial s | off time s | off window | reason | hint faults | promoted | demoted | trials |
| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | --- |
| 16g | 10 | 23.23782 | 90.012 | 9 | local_access | 12,518,759 | 2,102,338 | 12,576,706 | 50.54359, 37.05259, 32.15797, 15.61446, 12.68514, 13.07917, 10.96859, 13.80102 |
| 16g | 20 | 25.90131 | 100.006 | 5 | local_access | 13,688,487 | 2,274,093 | 12,910,021 | 51.50396, 43.54152, 33.00278, 28.40482, 12.76388, 13.15489, 11.06302, 13.77564 |
| 8g | 10 | 36.72230 | 90.013 | 9 | local_access | 15,561,612 | 2,390,382 | 14,638,262 | 41.24396, 44.77459, 35.45785, 38.43018, 39.66815, 37.66776, 33.68937, 22.84656 |
| 8g | 20 | 41.60252 | 140.009 | 7 | local_access | 23,515,042 | 3,931,516 | 16,425,799 | 47.74116, 42.00543, 36.27358, 45.30437, 38.73447, 43.46620, 36.10453, 43.19039 |

## Compare with existing 5s ours

| cap | window | avg trial s | off time s | off window |
| --- | ---: | ---: | ---: | ---: |
| 16g | 5 | 14.17649 | 45.020 | 9 |
| 16g | 10 | 23.23782 | 90.012 | 9 |
| 16g | 20 | 25.90131 | 100.006 | 5 |
| 8g | 5 | 41.69187 | 70.027 | 14 |
| 8g | 10 | 36.72230 | 90.013 | 9 |
| 8g | 20 | 41.60252 | 140.009 | 7 |

## Short read

- BC 8G: 10s window is best among these runs: 36.72s vs 41.69s at 5s and 41.60s at 20s.
- BC 16G: 5s window remains best: 14.18s. 10s and 20s delay migration-off to 90s/100s and raise the mean to 23.24s/25.90s.
- All new runs stopped by `local_access`; the remote-ratio condition did not trigger first.
