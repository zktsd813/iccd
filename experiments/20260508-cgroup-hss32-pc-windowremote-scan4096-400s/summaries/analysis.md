# Cgroup HSS32 Pointer-Chase Run

## Setup

- Experiment: `20260508-cgroup-hss32-pc-windowremote-scan4096-400s`
- Candidate: `pc_lf_windowremote_32g_fixed_rss16g_chase1_persistent`
- Policy: `on`
- Command: `timeout --signal=TERM 1200 /root/mbench --csv --quiet --sample-ms 1000 --ops-per-pass 65536 --pause-ns 100000 --arena-size 64G --mode pc --window-size 32G --window-offset 0 --move-policy fixed --pc-chains 1 --pc-pattern random --hotset-prefault-node 1 --threads 32 --duration-ms 400000`
- Kernel: `Linux kernel 6.18.0modified #136 SMP PREEMPT_DYNAMIC Fri May  8 09:05:52 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux`
- Kernel image: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Initrd image: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260508-pc-cgroup.img`
- QEMU/KVM: `accel=kvm`, VM `CPUS=32`, `MEMORY=96G`, `HOST_CPUS=0-31`
- VM NUMA: node0 `32G` on host node0, node1 `64G` on host node2, `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1`
- Cgroup: `CAPACITY_PAGES=4194304` (16 GiB), `CPUSET_CPUS=0-31`, `CPUSET_MEMS=0,1`
- NUMA policy: `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2`, `KSWAPD_DEMOTION_ON=1`, `OFF_DEMOTION_ON=1`
- Scan/threshold: `NUMA_SCAN_SIZE_MB=4096`, effective `4096`, `SCAN_PERIOD_SCALE=100`, `HOT_THRESHOLD_MS=0`
- MGLRU: `lru_gen_enabled=0x0007`, `lru_gen_min_ttl_ms=0`
- Diagnostics disabled: `NUMA_MIGRATION_STOP_ENABLED=0`, `NUMA_PINGPONG_STAT_ENABLED=0`, `NUMA_PROMOTE_SAMPLE_STAT_ENABLED=0`, `NUMA_PROMOTE_SAMPLE_RATE=0`
- Placement: local-first-touch arena with only the pointer-chase 32 GiB window remote-first-touched via `--hotset-prefault-node 1`; `remote_firsttouch=0` and `PREFAULT_PHASE_GATE=1`
- Initial measured cgroup anon residency after prefault: node0 `15.43 GiB`, node1 `48.57 GiB`

## Result

| metric | value | HSS32 ratio |
| --- | ---: | ---: |
| steady mean throughput | `97.56 Mops/s` | |
| steady median throughput | `100.99 Mops/s` | |
| hint fault event volume | `22,874,170` pages (`87.26 GiB`) | `272.7%` |
| latency-passed promotion candidates | `15,680,305` pages (`59.82 GiB`) | `186.9%` |
| promoted | `1,064,733` pages (`4.06 GiB`) | `12.7%` |
| demoted | `13,568,178` pages (`51.76 GiB`) | `161.7%` |
| over-high promotion failures | `14,631,200` pages (`55.81 GiB`) | `174.4%` |
| latency failures before candidacy | `6,815,244` events (`26.00 GiB if page-scaled`) | `81.2%` |

## Interpretation

Pointer chasing made the workload much slower, but did not increase useful promotion. Promotion reached only `4.06 GiB` out of the 32 GiB remote window. Candidate event volume was large (`59.82 GiB`), but most candidate attempts hit the same over-high gate (`55.81 GiB`) rather than turning into successful promotion.

Compared with the previous cgroup HSS32 mulshift/scan4096 run, this pc run promoted much less (`4.06 GiB` vs `15.89 GiB`) and delivered much lower throughput (`97.56 Mops/s` vs about `460.62 Mops/s`). So simply slowing the access stream with pointer chasing does not solve the low-promotion problem; it reduces candidate supply and still leaves the headroom gate as the dominant post-candidate failure.

Detailed timelines:

- `summaries/phase_60s_gib.csv`
- `summaries/live_10s_gib.csv`
