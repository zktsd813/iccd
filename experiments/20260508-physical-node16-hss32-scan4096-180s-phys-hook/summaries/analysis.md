# Physical node-limit HSS32 hook run

## Run

- Experiment: `20260508-physical-node16-hss32-scan4096-180s-phys-hook`
- Run id: `physical_node16_hss32_scan4096_180s_phys_hook_20260508T075140Z`
- Kernel image during hook run: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Fresh initrd during hook run: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260508-phys-hook.img`
- Guest kernel: `Linux kernel 6.18.0modified #131 SMP PREEMPT_DYNAMIC Fri May 8 07:53:56 UTC 2026`
- KVM: enabled
- VM: `CPUS=32`, `MEMORY=80G`, `HOST_CPUS=0-31`, guest node0 `16G` on host node0, guest node1 `64G` on host node2, `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1`
- Cgroup: no workload cgroup/root cgroup, no cgroup capacity cap
- Runtime knobs: `numa_balancing=2`, `demotion_enabled=true`, `demotion_target=0 1`, `lru_gen_enabled=0x0007`, `scan_size_mb=4096`, `rootcg_scan_period_scale=100`, `rootcg_migration_stop=0`, `rootcg_pingpong_stat=0`, `rootcg_promote_sample_stat=0`
- Workload: `skew_lf_hotremote_32g_fixed_rss16g_mulshift_persistent`, arena `64G`, HSS `32G` (`8,388,608` pages), hotset-only remote prefault on node1, 32 threads, 180s
- Initial process residency after prefault: node0 `14.11 GiB`, node1 `49.89 GiB`

## Totals

- Throughput: steady mean `293.67 Mops/s`, first-10s `208.75 Mops/s`, last-10s `373.75 Mops/s`
- Promotion: `3,598,026` pages (`13.73 GiB`), `42.9%` of HSS
- Demotion: `3,599,299` pages (`13.73 GiB`), `42.9%` of HSS; all via `pgdemote_kswapd`
- Candidate event volume: `29,580,893` events, `352.6%` of HSS. This is event volume, not unique hotset coverage.
- Migration failures: `128` pages

## 10s-style deltas

The live sampler requested 10s cadence, but reading `/proc/<pid>/numa_maps` makes the actual intervals about 11-14s. The table uses each row's elapsed timestamp.

| window(s) | ops M/s | promote | demote | candidate | fail | pgscan_kswapd | pgsteal_kswapd | hook cold | hook protected | proc N0 GiB |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0.0-11.0 | 212.2 | 368338 | 358589 | 2795690 | 113 | 359622 | 358513 | 359528 | 3407 | 15.01 |
| 11.0-23.9 | 242.9 | 380715 | 380540 | 2960252 | 13 | 380683 | 380540 | 380683 | 554 | 14.87 |
| 23.9-37.0 | 248.4 | 230149 | 239157 | 1968656 | 1 | 239118 | 239157 | 239118 | 235 | 14.93 |
| 37.0-50.2 | 271.2 | 232162 | 227892 | 1953760 | 0 | 228067 | 227892 | 228067 | 78 | 14.81 |
| 50.2-63.6 | 257.4 | 242438 | 237971 | 1994840 | 0 | 238230 | 237971 | 238230 | 43 | 14.98 |
| 63.6-77.1 | 279.4 | 70124 | 86659 | 643662 | 0 | 86663 | 86659 | 86663 | 71 | 14.95 |
| 77.1-90.9 | 264.7 | 265764 | 253831 | 2112125 | 1 | 253880 | 253831 | 253880 | 84 | 14.85 |
| 90.9-104.5 | 301.2 | 343090 | 360160 | 3033304 | 0 | 360329 | 360160 | 360329 | 21 | 14.79 |
| 104.5-118.3 | 308.8 | 133617 | 107951 | 1009982 | 0 | 108329 | 107951 | 108329 | 6 | 15.02 |
| 118.3-132.0 | 301.7 | 305701 | 315165 | 2794437 | 0 | 315637 | 315165 | 315637 | 236 | 14.81 |
| 132.0-145.9 | 330.5 | 276383 | 274179 | 2189991 | 0 | 274407 | 274179 | 274471 | 79 | 14.98 |
| 145.9-159.8 | 345.1 | 66572 | 80339 | 650815 | 0 | 80278 | 80339 | 80214 | 0 | 14.98 |
| 159.8-174.2 | 375.0 | 362846 | 341972 | 2912489 | 0 | 341986 | 341972 | 341986 | 0 | 14.88 |
| 174.2-180.0 | 392.6 | 248437 | 254382 | 1960364 | 0 | 257540 | 254382 | 257604 | 6 | 15.02 |

CSV: `summaries/physical_hss32_10s_deltas.csv`

## Hook interpretation

- Physical kswapd did not show the cgroup/reclaimd plateau pattern. It continuously found cold folios: hook `sort_cold=3,605,361`, `scan_folios_isolated=3,605,361`, and `pgsteal_kswapd=3,599,299` are all aligned.
- MGLRU protection was small in this physical run: hook `sort_protected=4,839` versus `sort_cold=3,605,361`.
- `can_demote_true=58,087`, `can_demote_false=0`, so the demotion path itself was available throughout kswapd reclaim.
- In the late interval from about 118s to 180s, physical still made `1,259,939` promotions (`4.81 GiB`) and `1,266,037` demotions (`4.83 GiB`) with `10,508,096` candidate events.
- The prior cgroup reclaimd poll for the same HSS32/180s investigation only added about `211,161` promotions (`0.81 GiB`) from roughly 120s to 180s. That is the key behavioral difference: physical kswapd keeps making headroom and promotion progress, while cgroup reclaimd entered a low-progress plateau.

## Conclusion

The same phenomenon does not reproduce in the physical node-limit path. Physical node0 pressure wakes kswapd, kswapd scans MGLRU, isolates cold folios, demotes them to node1, and promotion continues with very low migration failure count. The cgroup path's problem is therefore not simply "MGLRU never has cold folios" under this workload. It is specific to the cgroup/reclaimd control loop and/or the lruvec/memcg state seen by that loop, where late-run reclaim progress collapses while promotion candidates keep arriving.

## Cleanup

The temporary physical hook was removed from `/Serverless/Migration-friendly/linux/mm/vmscan.c` after this run. A clean hook-free `bzImage` was rebuilt as kernel build `#132`.
