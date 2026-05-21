# node1=128G HSS32 pointer-chase rerun

Date: 2026-05-08

Artifact:
`/Serverless/iccd/experiments/20260508-cgroup-hss32-pc-node1-128g-120s/qemu-logs/phase_candidate_microbench/20260508T103525Z`

Run directory:
`guest-artifacts/20260508T103525Z/pc_lf_windowremote_32g_fixed_rss16g_chase1_persistent__on__rep1`

## VM and kernel settings

- Kernel image: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Kernel build: wrapper rebuilt with `make -C /Serverless/Migration-friendly/linux -j64 bzImage modules`
- Kernel build id: `6.18.0modified #143`
- Initrd: fresh `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260508-node1-128g.img`
- QEMU: KVM, 32 vCPUs, 160G guest memory
- NUMA node0: 32G, CPUs 0-31, host node bind 0
- NUMA node1: 128G, host node bind 2
- cgroup cap: `CAPACITY_PAGES=4194304` (16GiB node0 local capacity)
- MGLRU: `enabled=0x0007`
- NUMA scan: `NUMA_SCAN_SIZE_MB=4096`, `SCAN_PERIOD_SCALE=100`
- Workload: `mbench --arena-size 64G --mode pc --window-size 32G --window-offset 0 --move-policy fixed --pc-chains 1 --pc-pattern random --hotset-prefault-node 1 --threads 32 --duration-ms 120000`
- Explicitly disabled knobs:
  - `NUMA_MIGRATION_STOP_ENABLED=0`
  - `NUMA_PINGPONG_STAT_ENABLED=0`
  - `NUMA_PROMOTE_SAMPLE_STAT_ENABLED=0`
  - `NUMA_PROMOTE_SAMPLE_RATE=0`

Note: live CSV shows `cg_earlystop_running=1`, but code inspection confirms this is the raw `numa_page_migration_running` state. The effective earlystop path requires both `numa_migration_stop_enabled` and `numa_pingpong_stat_enabled`; this run has `numa_migration_stop_effective=0`, so earlystop was not active.

## Final counters

| metric | node1=64G previous | node1=128G rerun |
| --- | ---: | ---: |
| promotion success | 103,921 pages / 0.40GiB | 2,333,135 pages / 8.90GiB |
| demotion | 6,386,529 pages / 24.36GiB | 3,579,197 pages / 13.65GiB |
| promotion candidates | 2,581,630 pages / 9.85GiB | 5,252,918 pages / 20.04GiB |
| promotion over_high fail | 1,851,551 pages / 7.06GiB | 2,919,788 pages / 11.14GiB |
| vmstat pgmigrate_fail | 3,270,852 pages / 12.48GiB | 2,920,174 pages / 11.14GiB |
| pgmigrate_fail - over_high | 1,419,301 pages / 5.41GiB | 386 pages / 0.0015GiB |
| reclaimd run/wake diff | 0 / 0 | 5 / 5 |
| steady mean ops/s | 130.19M | 95.43M |
| steady median ops/s | 160.47M | 159.25M |

HSS is 32GiB. In the 128G rerun, candidate event volume is 20.04GiB, about 62.6% of HSS, and promotion success is 8.90GiB, about 27.8% of HSS.

## 10s live timeline

Values are raw live counters in GiB, so demotion includes prefault-time baseline.

| elapsed | mem | anon_n0 | anon_n1 | promoted | demoted_raw | over_high | candidate | reclaimd_runs |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0.0s | 64.35 | 15.68 | 48.54 | 0.00 | 20.58 | 0.00 | 0.00 | 1 |
| 10.1s | 96.20 | 14.98 | 81.02 | 0.00 | 26.17 | 0.00 | 0.00 | 1 |
| 20.1s | 96.20 | 14.42 | 81.58 | 0.00 | 26.73 | 0.00 | 0.00 | 1 |
| 30.1s | 96.20 | 15.36 | 80.64 | 0.94 | 26.73 | 0.00 | 0.94 | 1 |
| 40.2s | 96.20 | 15.44 | 80.56 | 2.31 | 28.02 | 0.94 | 3.25 | 2 |
| 50.2s | 96.20 | 15.28 | 80.72 | 3.10 | 28.97 | 1.20 | 4.30 | 3 |
| 60.2s | 89.02 | 14.96 | 73.85 | 4.75 | 30.64 | 2.63 | 7.39 | 4 |
| 70.3s | 84.17 | 15.17 | 68.83 | 7.32 | 32.90 | 8.19 | 15.51 | 5 |
| 80.3s | 64.13 | 14.98 | 49.02 | 7.32 | 33.09 | 8.19 | 15.51 | 5 |
| 90.3s | 64.13 | 14.98 | 49.02 | 7.32 | 33.09 | 8.19 | 15.51 | 5 |
| 100.3s | 64.13 | 14.98 | 49.02 | 7.32 | 33.09 | 8.19 | 15.51 | 5 |
| 110.4s | 64.13 | 14.98 | 49.02 | 7.32 | 33.09 | 8.19 | 15.51 | 5 |
| 120.4s | 64.13 | 14.98 | 49.02 | 7.32 | 33.09 | 8.19 | 15.51 | 5 |
| 140.5s | 60.74 | 13.92 | 46.69 | 8.90 | 34.23 | 11.14 | 20.04 | 6 |

Max live resident state before process exit:

- `memory_current`: 96.20GiB
- `anon_n0`: 15.68GiB
- `anon_n1`: 81.58GiB

## Interpretation

The node1 target allocation-pressure problem is resolved by node1=128G. The strongest evidence is that `pgmigrate_fail - promotion_over_high` drops from about 5.41GiB to about 0.0015GiB. In the previous 64G-node1 diagnostic this residual matched the demotion target allocation failure hook; in this rerun it is effectively gone.

This does not mean promotion is fully healthy. Promotion increased substantially, from 0.40GiB to 8.90GiB, but the remaining migration failures are now almost entirely `promotion_over_high`. That points back to the cgroup node0 watermark/gating side rather than node1 allocation capacity. Reclaimd does wake and run in this patched kernel, but the promotion gate still rejects a large event volume once node0 is above the allowed band.
