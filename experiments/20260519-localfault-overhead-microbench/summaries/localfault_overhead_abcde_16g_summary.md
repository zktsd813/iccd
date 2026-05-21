# Local Fault Overhead Microbench A/B/C/D/E

Workload: `sparse_stride_read_16g`, 16G arena/window, 32 threads, 4K stride, 180s measured after prefault gate. A/B/C isolate local-fault overhead with all pages local and no migration. D/E use 8G local capacity with demotion enabled to measure the migration-on path.

| case | meaning | cap | mean MiB/s | median MiB/s | vs A | vs D | hint faults | PTE updates | local PTE/refault/hit/lost | promoted GiB | demoted GiB | initial anon N0/N1 GiB |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | --- |
| A-baseline | node_balancing=0, local fault off, cap 28G, demotion off | 28G | 3691.42 | 3691.00 | +0.000% |  | 0 | 0 | 0/0/0/0 | 0.00 | 0.00 | 16.00/0.00 |
| B-scan-only | node_balancing=2, local fault off, cap 28G, demotion off | 28G | 3684.53 | 3685.00 | -0.187% |  | 0 | 0 | 0/0/0/0 | 0.00 | 0.00 | 16.00/0.00 |
| C-local-fault-10 | node_balancing=2, local fault 10%, cap 28G, demotion off | 28G | 3695.65 | 3695.52 | +0.114% |  | 419434 | 419434 | 419434/419434/419434/0 | 0.00 | 0.00 | 16.00/0.00 |
| D-migration-on | node_balancing=2, local fault off, cap 8G, demotion on | 8G | 1737.67 | 1636.00 | -52.927% | +0.000% | 11402913 | 10773650 | 0/0/0/0 | 22.76 | 22.10 | 7.15/8.85 |
| E-migration+local-fault-10 | node_balancing=2, local fault 10%, cap 8G, demotion on | 8G | 1876.46 | 1830.00 | -49.167% | +7.987% | 11490934 | 10748105 | 213508/213232/213232/276 | 22.19 | 21.74 | 7.15/8.85 |

## Readout

- A/B/C isolation still holds: C generated 419,434 local refaults with 0 promoted/demoted/migrated pages, and was +0.302% vs B. In this single run, local-fault-only overhead is below measurement noise.
- D turned on migration under an 8G local cap. Throughput dropped to 1737.67 MiB/s, with 22.76 GiB promoted and 22.10 GiB demoted.
- E added local fault sampling to the same migration setting. It generated 213,232 local refaults, promoted 22.19 GiB and demoted 21.74 GiB. Throughput was +7.987% vs D.
- Do not interpret E-D as pure local-fault overhead: migration volume changed too. The pure overhead estimate is C-B; D/E show behavior when the mechanism is combined with migration churn.

## Artifacts

- A-baseline: `/Serverless/iccd/experiments/20260519-localfault-overhead-microbench/qemu-logs/phase_candidate_microbench/20260519Tlocalfault-oh-A-baseline/guest-artifacts/20260519Tlocalfault-oh-A-baseline/sparse_stride_read_16g__off__rep1`
- B-scan-only: `/Serverless/iccd/experiments/20260519-localfault-overhead-microbench/qemu-logs/phase_candidate_microbench/20260519Tlocalfault-oh-B-scanonly/guest-artifacts/20260519Tlocalfault-oh-B-scanonly/sparse_stride_read_16g__on__rep1`
- C-local-fault-10: `/Serverless/iccd/experiments/20260519-localfault-overhead-microbench/qemu-logs/phase_candidate_microbench/20260519Tlocalfault-oh-C-localfault10-afterprefault2/guest-artifacts/20260519Tlocalfault-oh-C-localfault10-afterprefault2/sparse_stride_read_16g__on__rep1`
- D-migration-on: `/Serverless/iccd/experiments/20260519-localfault-overhead-microbench/qemu-logs/phase_candidate_microbench/20260519Tlocalfault-oh-D-migration-on/guest-artifacts/20260519Tlocalfault-oh-D-migration-on/sparse_stride_read_16g__on__rep1`
- E-migration+local-fault-10: `/Serverless/iccd/experiments/20260519-localfault-overhead-microbench/qemu-logs/phase_candidate_microbench/20260519Tlocalfault-oh-E-migration-localfault10/guest-artifacts/20260519Tlocalfault-oh-E-migration-localfault10/sparse_stride_read_16g__on__rep1`
