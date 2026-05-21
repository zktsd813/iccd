# GAPBS latest-kernel comparison with placement baselines

Values are GAPBS `Average Time` in seconds; lower is better.

- Kernel: `Linux kernel 6.18.0modified #179 SMP PREEMPT_DYNAMIC Wed May 20 03:30:57 UTC 2026`.
- Graph input: `/root/gapbs_graphs/kron_g28.sg`, loaded with `-f`.
- Placement baseline: migration/local-fault/demotion off, no cgroup node capacity, cgroup `cpuset.mems=0` for all-local and `cpuset.mems=1` for all-remote.
- Canonical VM: node0 32G local DRAM, node1 64G remote CXL, 32 vCPUs pinned to node0.

## Placement baselines

| workload | all-local | all-remote | local/remote |
| --- | ---: | ---: | ---: |
| pr | 22.39903 | 19.31847 | 1.159x |
| bc | 30.34918 | 35.06216 | 0.866x |

## Full comparison

### PR

| cap | window | off | on | one-shot | toggle | all-local | all-remote |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 8g | 5 | 18.70209 | 56.78888 | 20.48353 | 50.53381 | 22.39903 | 19.31847 |
| 8g | 10 | 18.70209 | 56.78888 | 22.97827 | 36.07283 | 22.39903 | 19.31847 |
| 8g | 20 | 18.70209 | 56.78888 | 23.23777 | 38.70491 | 22.39903 | 19.31847 |
| 16g | 5 | 19.02841 | 36.65146 | 19.91645 | 26.63969 | 22.39903 | 19.31847 |
| 16g | 10 | 19.02841 | 36.65146 | 21.39773 | 24.89355 | 22.39903 | 19.31847 |
| 16g | 20 | 19.02841 | 36.65146 | 22.27940 | 25.33062 | 22.39903 | 19.31847 |

### BC

| cap | window | off | on | one-shot | toggle | all-local | all-remote |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 8g | 5 | 16.62260 | 52.52492 | 42.69546 | 54.33519 | 30.34918 | 35.06216 |
| 8g | 10 | 16.62260 | 52.52492 | 32.80896 | 50.06638 | 30.34918 | 35.06216 |
| 8g | 20 | 16.62260 | 52.52492 | 46.05124 | 48.00451 | 30.34918 | 35.06216 |
| 16g | 5 | 49.36582 | 38.22507 | 22.11875 | 38.82430 | 30.34918 | 35.06216 |
| 16g | 10 | 49.36582 | 38.22507 | 19.91531 | 38.38612 | 30.34918 | 35.06216 |
| 16g | 20 | 49.36582 | 38.22507 | 25.88901 | 31.59196 | 30.34918 | 35.06216 |
