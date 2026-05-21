# GAPBS g28 local16 fast-scan period sweep

Experiment:
`/Serverless/iccd/experiments/20260510-gapbs-g28-local16-fastscan-period-sweep`

Run IDs:

| workload | run ID |
| --- | --- |
| PR | `20260510T101837Z-prg28-local16-fastscan-period-sweep` |
| BC | `20260510T104246Z-bcg28-local16-fastscan-period-sweep` |

## Setup

| item | value |
| --- | --- |
| VM topology | 32 vCPUs, 96G, node0 32G on host node0, node1 64G on host node2 |
| local cap | 16G, `CAPACITY_PAGES=4194304` |
| migration | always on, cgroup `node_balancing=2` |
| demotion | on |
| scan size | 256MB |
| fast scan | on, `numa_balancing_fast_scan=1` |
| periods | 250ms, 500ms, 1000ms |
| kernel | `Linux kernel 6.18.0modified #172 SMP PREEMPT_DYNAMIC Sun May 10 07:45:36 UTC 2026` |
| MGLRU | `0x0007` |
| earlystop / pingpong stat | 0 / 0 |

Commands:

| workload | command |
| --- | --- |
| PR | `/root/mbench -g28 -i20 -t1e-4 -n10` |
| BC | `/root/mbench -g28 -i1 -n10 -l` |

BC used the GAPBS default source picker, without `-r`. The source changes each
trial. Because GAPBS uses a deterministic default RNG, the 10-source sequence
is the same across period runs:
`11861354, 58815963, 46138365, 83490977, 76756715, 129667248, 78589531, 179326557, 190407941, 172132829`.

## Performance

| workload | period_ms | trial_avg_s | trial_median_s | stdev_s | min_s | max_s | elapsed_s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| PR | 250 | 20.97887 | 20.67458 | 1.07857 | 19.75791 | 23.36653 | 423 |
| PR | 500 | 21.04988 | 21.27643 | 0.70190 | 19.95722 | 22.06829 | 434 |
| PR | 1000 | 30.33131 | 21.98754 | 15.93423 | 19.97074 | 65.28508 | 537 |
| BC | 250 | 14.60561 | 14.33915 | 1.65414 | 12.34926 | 17.56307 | 373 |
| BC | 500 | 16.66401 | 14.16023 | 6.37691 | 12.18171 | 28.58529 | 436 |
| BC | 1000 | 15.14754 | 14.28604 | 3.15073 | 12.18232 | 21.65290 | 385 |

Trial times:

| workload | period_ms | trial times |
| --- | ---: | --- |
| PR | 250 | 19.75791, 19.90592, 20.56716, 21.22752, 20.78200, 20.38038, 21.98339, 23.36653, 21.39875, 20.41913 |
| PR | 500 | 20.01759, 21.32977, 20.91915, 19.95722, 22.06829, 20.46635, 21.23355, 21.31930, 21.55305, 21.63454 |
| PR | 1000 | 19.97074, 22.22302, 22.53141, 20.61773, 65.28508, 21.75205, 20.31611, 21.31121, 50.55077, 38.75495 |
| BC | 250 | 13.40755, 12.80340, 12.34926, 15.27137, 15.79598, 13.74771, 14.29843, 16.43946, 17.56307, 14.37987 |
| BC | 500 | 13.67797, 12.23988, 12.77550, 15.04327, 28.58529, 14.64248, 12.18171, 16.00329, 13.00904, 28.48171 |
| BC | 1000 | 13.52002, 12.23159, 12.56295, 15.06479, 19.31302, 14.12958, 12.18232, 16.37574, 21.65290, 14.44249 |

## Migration counters

| workload | period_ms | hint_faults | pte_updates | promoted_pages | promoted_GiB | demoted_direct_pages | demoted_direct_GiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| PR | 250 | 39879875 | 46252577 | 12915802 | 49.27 | 19092319 | 72.83 |
| PR | 500 | 42141313 | 49686728 | 13135892 | 50.11 | 19244148 | 73.41 |
| PR | 1000 | 52275108 | 60065471 | 13446543 | 51.29 | 19996511 | 76.28 |
| BC | 250 | 33953056 | 40181971 | 10297349 | 39.28 | 18476117 | 70.48 |
| BC | 500 | 38030741 | 46871377 | 12057710 | 45.99 | 19754058 | 75.36 |
| BC | 1000 | 34644499 | 43442373 | 10777246 | 41.11 | 18506004 | 70.59 |

## Notes

- PR 250ms and 500ms are almost identical by average and median. PR 1000ms has
  similar median but a much higher average because trials 5, 9, and 10 are
  large outliers.
- BC 250ms is the best by average. BC 500ms has two large outliers and the
  highest migration counter totals. BC 1000ms sits between 250ms and 500ms.
- All six runs completed with return code 0; stderr and sampler error logs are
  empty.

CSV:
`/Serverless/iccd/experiments/20260510-gapbs-g28-local16-fastscan-period-sweep/summaries/gapbs_g28_local16_fastscan_period_sweep_summary.csv`
