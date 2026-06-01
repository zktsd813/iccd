# PR -g29 Global NUMA Results

Date: 2026-06-01 UTC

Kernel: `/Serverless/iccd-git/linux-global-build/arch/x86/boot/bzImage`

Workload: `/root/pr -g 29 -i 20 -t 1e-4 -n 1`, `OMP_NUM_THREADS=32`

Guest runtime knobs: `lru_gen/enabled=0x0007`, demotion enabled, demotion target `0 1`, scan size `256MB`, scan period min `1000ms`.

## VM setups

| VM | Guest node0 | Guest node1 | Host backing | Placement |
| --- | ---: | ---: | --- | --- |
| local16 | 16G, CPUs 0-31 | 176G, memory-only | node0 / node2 | `numactl --cpunodebind=0 --localalloc` |
| all_slow | 16G, CPUs 0-31 | 176G, memory-only | node0 / node2 | `numactl --cpunodebind=0 --membind=1` |
| all_fast | 160G, CPUs 0-31 | 4G, memory-only | node0-1 / node2 | `numactl --cpunodebind=0 --membind=0` |

Host node0 alone is 128G, so the all-fast guest node0 was backed by host DRAM nodes `0-1` to fit the `-g29` footprint.

## Results

| Run | Global NUMA | Avg PR trial | Total wall | Max RSS KB | Sample placement peak | Main deltas |
| --- | ---: | ---: | ---: | ---: | --- | --- |
| migration_off | `0` | 43.85798s | 8:15.09 | 148145908 | N0 15.155GiB, N1 122.824GiB | hint 0, migrated 0, promoted 0, demoted 1999820 |
| migration_on | `2` | 43.46639s | 8:11.60 | 148145460 | N0 15.225GiB, N1 122.779GiB | hint 309, migrated 95, promoted 95, demoted 1945029 |
| all_slow | `0` | 258.40936s | 11:39.66 | 148144868 | N0 0.003GiB, N1 138.002GiB | hint 0, migrated 0, promoted 0, demoted 0 |
| all_fast | `0` | 38.59033s | 5:05.50 | 148145148 | N0 138.005GiB, N1 0.000GiB | hint 0, migrated 0, promoted 0, demoted 0 |

Raw result CSV: `summaries/pr_g29_results.csv`

Raw guest outputs:

- `guest-results/pr-g29-local16/migration_off`
- `guest-results/pr-g29-local16/migration_on`
- `guest-results/pr-g29-local16/all_slow`
- `guest-results/pr-g29-allfast/all_fast`
