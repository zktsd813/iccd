# Physical node-limit HSS32 400s hook run

## Setup

- Run id: `physical_node16_hss32_scan4096_400s_phys_hook_20260508T081525Z`
- Kernel/initrd: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`, `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260508-phys-hook-400s.img`
- Guest kernel: `Linux kernel 6.18.0modified #134 SMP PREEMPT_DYNAMIC Fri May 8 08:15:56 UTC 2026`
- VM: KVM, `CPUS=32`, `MEMORY=80G`, node0 `16G` on host node0, node1 `64G` on host node2, `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1`
- Cgroup: none/root cgroup, no cgroup cap
- Knobs: `numa_balancing=2`, `demotion_enabled=true`, `demotion_target=0 1`, `lru_gen_enabled=0x0007`, `scan_size_mb=4096`, `rootcg_scan_period_scale=100`, earlystop/pingpong/promote-sample stat all `0`
- Workload: HSS32 hotset-only remote prefault, arena `64G`, 32 threads, duration `400s`
- Initial process residency: node0 `14.08 GiB`, node1 `49.92 GiB`

## Totals

- Promotion: `4,088,332` pages = `16.75 GB` (`15.60 GiB`)
- Demotion: `4,062,116` pages = `16.64 GB` (`15.50 GiB`), all via `pgdemote_kswapd`
- Candidate event volume: `51,944,573` events = `212.76 GB` event volume
- Migration failures: `1,905` pages = `0.008 GB`
- Throughput: steady mean `369.71 Mops/s`, last-10s `435.13 Mops/s`

## 60s Phases

| phase | interval | promote GB | demote GB | candidate-event GB | fail pages | total promote GB | total demote GB | ops M/s | N0 GiB |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 0-60 | 5.91 | 5.86 | 46.18 | 684 | 5.91 | 5.86 | 247.1 | 14.87 |
| 2 | 60-120 | 3.60 | 3.64 | 30.00 | 0 | 9.51 | 9.51 | 285.2 | 14.87 |
| 3 | 120-180 | 4.33 | 4.33 | 35.79 | 0 | 13.83 | 13.84 | 337.1 | 14.74 |
| 4 | 180-240 | 2.64 | 2.65 | 25.35 | 26 | 16.47 | 16.49 | 388.2 | 15.04 |
| 5 | 240-300 | 0.20 | 0.10 | 22.68 | 696 | 16.67 | 16.59 | 450.1 | 15.17 |
| 6 | 300-360 | 0.04 | 0.03 | 30.52 | 283 | 16.71 | 16.62 | 453.4 | 15.18 |
| 7 | 360-400 | 0.02 | 0.02 | 17.15 | 154 | 16.73 | 16.63 | 448.5 | 15.18 |

## Interpretation

- Longer run confirms the missing observation from the 180s run: physical promotion reaches the 16 GB local-node scale at about 200-220s, then flattens near `16.75 GB`.
- This is still different from the cgroup plateau. After reaching the physical node capacity, candidate events continue, but `pgmigrate_fail` only totals `1,905` pages (`0.008 GB`), not tens or hundreds of GB of over-high failures.
- Physical kswapd keeps scanning heavily after promotion flattens: hook `sort_promoted` grows as already-hot/younger folios are rotated, while `sort_cold`/`pgsteal_kswapd` only grow modestly. So the late plateau is mostly because the local 16G tier is full of already-promoted/hot pages, not because kswapd cannot run or because allocation failures explode.
- Compared with cgroup statefix HSS32 scan4096: cgroup reached about `12.50 GB` promotion by 120s and then added only `0.04 GB` from 120-180s with large over-high event volume. Physical added `4.40 GB` from 120-180s and only plateaued after it reached about `16 GB`.

- CSV: `/Serverless/iccd/experiments/20260508-physical-node16-hss32-scan4096-400s-phys-hook/summaries/phase_60s_gb.csv`
- Live GB timeline: `/Serverless/iccd/experiments/20260508-physical-node16-hss32-scan4096-400s-phys-hook/summaries/timeline_live_gb.csv`

## Cleanup

Temporary hook was removed from `/Serverless/Migration-friendly/linux/mm/vmscan.c`; hook-free clean `bzImage` rebuilt as kernel build `#135`.
