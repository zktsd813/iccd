# Physical Node16 HSS16 Scan4096 No-Cgroup On

Date: 2026-05-08

## Goal

Run the current HSS16 hotset workload on the physical-node capacity path:
guest node0 is physically limited to 16G, guest node1 is 64G, and the workload
runs in the root cgroup with global memory tiering enabled. The focus is the
candidate/HSS ratio, promotion/HSS ratio, and migration failure counters.

## Setup

| item | value |
| --- | --- |
| kernel image | `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage` |
| initrd | `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260508T003500Z-nostop-noping.img` |
| guest kernel | `Linux kernel 6.18.0modified #122 SMP PREEMPT_DYNAMIC Thu May 7 23:30:15 UTC 2026 x86_64` |
| KVM | enabled (`-accel kvm`) |
| VM topology | `MEMORY=80G`, `CPUS=32`, node0 `16G`, node1 `64G` |
| host binding | node0 on host node0, node1 on host node2 CXL, `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1` |
| cgroup cap | none; runner and benchmark in root cgroup `0::/` |
| global NUMA mode | `/proc/sys/kernel/numa_balancing=2` |
| demotion | `/sys/kernel/mm/numa/demotion_enabled=true`, target `0 1` |
| MGLRU | `/sys/kernel/mm/lru_gen/enabled=0x0007` |
| scan tuning | `scan_size_mb=4096` |

Workload:

```text
taskset -c 0-31 /root/mbench --csv --quiet --sample-ms 1000
  --ops-per-pass 65536 --pause-ns 100000 --arena-size 64G
  --mode skewed-hotset --window-size 16G --window-offset 0
  --move-policy fixed --hotset-pages 4194304 --hot-prob-pct 100
  --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0
  --hotset-index-mode mulshift --hotset-prefault-node 1
  --threads 32 --duration-ms 60000
```

Initial process residency after prefault:

| node | pages | GiB |
| --- | ---: | ---: |
| node0 | `3,712,928` | `14.16 GiB` |
| node1 | `13,064,852` | `49.84 GiB` |

## Result

| metric | value |
| --- | ---: |
| mean throughput | `527.08 Mops/s` |
| median throughput | `527.24 Mops/s` |
| first10 throughput | `457.12 Mops/s` |
| last10 throughput | `582.27 Mops/s` |
| HSS | `4,194,304` pages (`16 GiB`) |
| promotion candidates | `6,140,394` |
| candidate/HSS | `146.40%` |
| promoted | `622,940` pages (`2.38 GiB`) |
| promoted/HSS | `14.85%` |
| promoted/candidate | `10.14%` |
| demoted | `638,895` pages (`2.44 GiB`) |
| `pgmigrate_fail` | `74` |
| `pgmigrate_fail/HSS` | `0.0018%` |
| `pgmigrate_success` | `1,261,835` |
| hint faults | `8,237,728` |

Relevant vmstat diff:

```text
numa_hint_faults 8237728
numa_hint_faults_local 0
numa_pages_migrated 622940
pgpromote_candidate 6140394
pgpromote_candidate_nrl 124
pgpromote_success 622940
pgmigrate_success 1261835
pgmigrate_fail 74
pgdemote_direct 0
pgdemote_kswapd 638895
pgscan_kswapd 639949
pgsteal_kswapd 638895
```

## Comparison To Cgroup HSS16 Scan4096

| metric | cgroup cap scan4096 on | physical node16 no-cg on |
| --- | ---: | ---: |
| candidates | `3,953,878` | `6,140,394` |
| candidate/HSS | `94.27%` | `146.40%` |
| promoted | `1,952,531` (`7.45 GiB`) | `622,940` (`2.38 GiB`) |
| promoted/HSS | `46.55%` | `14.85%` |
| promoted/candidate | `49.38%` | `10.14%` |
| migration failures | `2,001,344` | `74` |
| demotion path | `pgdemote_direct=1,983,040` | `pgdemote_kswapd=638,895` |

## Interpretation

The physical path does not have the cgroup over-high failure storm. With global
memory tiering and physical node0 pressure, `pgmigrate_fail` is effectively
zero (`74` events) even though candidate events are abundant.

`candidate/HSS` exceeds 100%, so this counter should be read as candidate event
volume, not unique hotset coverage. With 4096 MiB scanning, pages can be
re-armed and counted again during the 60 second run.

The surprising part is promotion volume: physical node16 promoted only
`14.85%` of HSS, much less than the cgroup scan4096 run's `46.55%`, despite
having almost no migration failures. The physical path is not failing at
migration allocation; it is balancing promotion with kswapd demotion under a
true 16G local node and ends up moving about `2.4 GiB` in this run.

Artifacts:

- `/Serverless/iccd/experiments/20260508-physical-node16-hss16-scan4096-nocg/qemu-logs/phase_candidate_microbench/physical_node16_hss16_scan4096_nocg_on_20260508T043822Z`
- guest runner: `/Serverless/iccd/experiments/20260508-physical-node16-hss16-scan4096-nocg/notes/run_physical_hss16_guest.sh`
