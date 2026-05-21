# Local Fault Overhead Microbench A/B/C

Workload: `sparse_stride_read_16g`, 16G arena/window, 32 threads, 4K stride, 180s measured after prefault gate. All pages were first-touched on node0. Local capacity was 28G, demotion disabled, scan 256MB/1000ms/no-fast.

| case | meaning | mean MiB/s | median MiB/s | vs A | vs B | hint faults | PTE updates | local PTE/refault/hit | promote/demote/migrate pages | initial anon N0/N1 GiB |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | --- |
| A-baseline | node_balancing=0, local fault off | 3691.42 | 3691.00 | +0.000% | +0.187% | 0 | 0 | 0/0/0 | 0/0/0 | 16.00/0.00 |
| B-scan-only | node_balancing=2, local fault off | 3684.53 | 3685.00 | -0.187% | +0.000% | 0 | 0 | 0/0/0 | 0/0/0 | 16.00/0.00 |
| C-local-fault-10 | node_balancing=2, local fault 10%, enabled after prefault | 3695.65 | 3695.52 | +0.114% | +0.302% | 419434 | 419434 | 419434/419434/419434 | 0/0/0 | 16.00/0.00 |

## Interpretation

- B produced no NUMA PTE updates/hint faults in this all-local placement, so ordinary node balancing added no measurable scanning activity here. B was -0.187% versus A, within run noise.
- C produced 419,434 local-fault PTE updates and 419,434 refaults, with zero promotion/demotion/migration pages.
- C was +0.302% versus B. Since it is slightly faster in this single run, the local-fault overhead is below the noise floor of this 180s single-rep measurement.
- For a tighter bound, repeat A/B/C at least 5 times or increase the local-fault rate/window coverage. This run validates that the isolation setup works: all pages stayed local and migration counters remained zero.

## Artifacts

- A-baseline: `/Serverless/iccd/experiments/20260519-localfault-overhead-microbench/qemu-logs/phase_candidate_microbench/20260519Tlocalfault-oh-A-baseline/guest-artifacts/20260519Tlocalfault-oh-A-baseline/sparse_stride_read_16g__off__rep1`
- B-scan-only: `/Serverless/iccd/experiments/20260519-localfault-overhead-microbench/qemu-logs/phase_candidate_microbench/20260519Tlocalfault-oh-B-scanonly/guest-artifacts/20260519Tlocalfault-oh-B-scanonly/sparse_stride_read_16g__on__rep1`
- C-local-fault-10: `/Serverless/iccd/experiments/20260519-localfault-overhead-microbench/qemu-logs/phase_candidate_microbench/20260519Tlocalfault-oh-C-localfault10-afterprefault2/guest-artifacts/20260519Tlocalfault-oh-C-localfault10-afterprefault2/sparse_stride_read_16g__on__rep1`
