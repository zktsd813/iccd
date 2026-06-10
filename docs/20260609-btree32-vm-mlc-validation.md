# 2026-06-09 btree32 VM and MLC validation

This note records the VM configuration, software versions, btree migration
on/off rerun, and host-vs-guest MLC comparison discussed on 2026-06-09.

## Source artifacts

- btree rerun root:
  `/Serverless/iccd-git/motivation/3_realworld/VM/results/20260609T_btree32_onoff_rerun`
- btree summary:
  `/Serverless/iccd-git/motivation/3_realworld/VM/results/20260609T_btree32_onoff_rerun/summaries/summary.csv`
- btree markdown summary:
  `/Serverless/iccd-git/motivation/3_realworld/VM/results/20260609T_btree32_onoff_rerun/summaries/summary.md`
- MLC comparison root:
  `/tmp/iccd_mlc_compare`
- MLC VM overlay left in place:
  `/tmp/iccd_mlc_compare/vm/mlc-compare.qcow2`

## Software versions

- Host kernel at check time:
  `Linux ubuntu 6.18.0modified #9 SMP PREEMPT_DYNAMIC Mon Jun 8 06:07:14 UTC 2026 x86_64`
- Guest kernel used by the btree rerun:
  `Linux kernel 6.18.0modified #10 SMP PREEMPT_DYNAMIC Tue Jun 9 04:32:10 UTC 2026 x86_64`
- Kernel image:
  `/Serverless/iccd-git/linux-global-build/arch/x86/boot/bzImage`
- Repo HEAD:
  `ef77f8b3c`
- Linux tree HEAD:
  `ef77f8b3c`
- QEMU:
  `qemu-system-x86_64 9.2.4`
- qemu-img:
  `qemu-img 9.2.4`
- Intel MLC:
  `Intel(R) Memory Latency Checker - v3.11`

## btree rerun setup

- Run ID: `20260609T_btree32_onoff_rerun`
- Workload: `btree`
- Configs: `migration_off`, `tiering_0x2`
- Local fast memory size: `32G`
- Slow memory size: `128G`
- Total VM memory: `160G`
- Rootfs base:
  `/Serverless/Migration-friendly/qemu/build/ubuntu.img`
- Rootfs format: `raw`
- Rootfs virtual size: `300G`
- Root device: `/dev/vda2`
- VM image cleanup: `DELETE_VM_IMAGES=1`; btree qcow2 overlays were deleted
  after the run.
- Host CPU pinning: `HOST_CPUS=0-31`
- Guest CPUs: `CPUS=32`
- Guest node0 CPUs: `NUMA_NODE0_CPUS=0-31`
- Guest node1: memory-only, no CPUs
- Fast host node: `0`
- Slow host node: `2`
- Slow memory mode: `host-cxl`
- QEMU memory policy: `bind`
- QEMU preallocation: enabled
- QEMU machine: `q35,hmat=on`
- QEMU CPU model: `host`
- HMAT fast latency/bandwidth: `80 ns`, `40000M`
- HMAT slow latency/bandwidth: `250 ns`, `10000M`
- SMT control: `off`
- Timeout: `21600` seconds
- Sampling interval: `5` seconds
- OMP threads: `32`
- Size profile: `rss60`

The measured btree command in the guest was:

```bash
timeout 21600 numactl --cpunodebind=0 /root/benchmark/vmitosis-workloads/bin/bench_btree_mt
```

## btree VM topology and backing

The guest topology observed for both btree configs was:

- Guest node0: CPUs `0-31`, about `32150 MB`
- Guest node1: CPU-less, about `129020 MB`
- Guest NUMA distance: local `10`, remote `20`
- Guest memory tiers: `memory_tier4=0`, `memory_tier56=1`

QEMU host backing was verified with `numastat -p`:

| Config | Host node0 MB | Host node1 MB | Host node2 MB |
| --- | ---: | ---: | ---: |
| migration_off | 32827.04 | 2.81 | 131072.06 |
| tiering_0x2 | 32827.29 | 2.81 | 131072.06 |

This confirms the fast guest node was backed by host node0 DRAM and the slow
guest node was backed by host node2 CXL memory. Host node1 was not used for
guest memory backing except for a tiny QEMU allocation.

## btree runtime knobs

Common runtime state:

- MGLRU: `0x0007`
- THP: `always [madvise] never`
- THP defrag: `always defer defer+madvise [madvise] never`
- NUMA scan size: `256 MB`
- NUMA scan period min: `1000 ms`
- Hot threshold: `1000 ms`
- Local fault scan size: `256 MB`
- Local fault scan period: `1000 ms`

Policy-specific state:

| Config | numa_balancing | demotion_enabled | demotion_target |
| --- | ---: | --- | --- |
| migration_off | 0 | false | `0 -1 1 -1` |
| tiering_0x2 | 2 | true | `0 1 1 -1` |

## btree results

| Metric | migration_off | tiering_0x2 |
| --- | ---: | ---: |
| Return code | 0 | 0 |
| Elapsed seconds | 533 | 642 |
| Wall time | 8:53.20 | 10:42.67 |
| Max RSS KiB | 69086032 | 69086032 |
| Max process N0 GiB | 30.672176 | 31.275360 |
| Max process N1 GiB | 35.217369 | 35.812424 |
| Max node0 used GiB | 31.228401 | 31.231152 |
| Max node1 used GiB | 36.098934 | 36.969749 |
| Promoted GiB | 0.000000 | 52.075512 |
| Demoted GiB | 0.000000 | 54.903053 |
| NUMA hint faults | 0 | 86541799 |
| NUMA PTE updates | 0 | 82968267 |
| Latency reject pages | 0 | 18332840 |
| Hot pages | 0 | 68208959 |
| pgpromote_candidate | 0 | 68208942 |
| pgpromote_candidate_demoted | 0 | 13658923 |
| pgpromote_success | 0 | 13651283 |
| pgdemote_kswapd | 0 | 14392506 |
| pgdemote_direct | 0 | 0 |

The tiering run took `642 / 533 = 1.2045x` the migration-off runtime, or about
`20.5%` slower for this rerun.

## MLC setup

MLC was run once on the host and once inside a VM. The VM was stopped after the
measurement.

Host commands:

```bash
/Serverless/benchmark/mlc/Linux/mlc --latency_matrix -e -r
/Serverless/benchmark/mlc/Linux/mlc --bandwidth_matrix -e
```

Guest commands:

```bash
/root/mlc --latency_matrix -e -r
/root/mlc --bandwidth_matrix -e
```

MLC VM setup:

- VM name: `mlc-compare-20260609`
- Rootfs overlay: `/tmp/iccd_mlc_compare/vm/mlc-compare.qcow2`
- Kernel image: `/Serverless/iccd-git/linux-global-build/arch/x86/boot/bzImage`
- Machine: `q35,hmat=on`
- CPU model: `host`
- KVM: enabled
- Host CPU pinning: `0-31`
- Guest CPUs: `32`
- Guest node0 CPUs: `0-31`
- Guest node0 memory: `16G`, backed by host node0
- Guest node1 memory: `32G`, backed by host node2
- Guest node1 CPUs: none
- Total VM memory: `48G`
- Slow memory mode: `host-cxl`
- HMAT fast latency/bandwidth: `80 ns`, `40000M`
- HMAT slow latency/bandwidth: `250 ns`, `10000M`
- Guest runtime before MLC: `numa_balancing=0`, `lru_gen_enabled=0x0007`,
  `demotion_enabled=false`

MLC VM backing was verified with `numastat -p`:

| Host node | QEMU memory MB |
| --- | ---: |
| node0 | 16432.82 |
| node1 | 2.79 |
| node2 | 32768.02 |

The guest topology for the MLC VM was:

- Guest node0: CPUs `0-31`, about `16022 MB`
- Guest node1: CPU-less, about `32253 MB`
- Guest memory tiers: `memory_tier4=0`, `memory_tier56=1`

## MLC results

Host latency matrix, random idle latency in ns:

| CPU node \\ memory node | node0 | node1 | node2 |
| --- | ---: | ---: | ---: |
| node0 | 99.1 | 169.2 | 242.7 |
| node1 | 174.9 | 104.5 | 394.1 |

Host bandwidth matrix, read-only MB/s:

| CPU node \\ memory node | node0 | node1 | node2 |
| --- | ---: | ---: | ---: |
| node0 | 139956.8 | 119971.1 | 23535.3 |
| node1 | 119868.1 | 139918.0 | 16347.5 |

Guest latency matrix, random idle latency in ns:

| CPU node \\ memory node | node0 | node1 |
| --- | ---: | ---: |
| node0 | 139.0 | 266.3 |

Guest bandwidth matrix, read-only MB/s:

| CPU node \\ memory node | node0 | node1 |
| --- | ---: | ---: |
| node0 | 139062.8 | 23522.9 |

## MLC interpretation

Directly comparable mappings are host `node0 -> node0` vs guest
`node0 -> node0`, and host `node0 -> node2` vs guest `node0 -> node1`.

| Path | Host | Guest | Delta |
| --- | ---: | ---: | ---: |
| Fast latency | 99.1 ns | 139.0 ns | +40.3% |
| Slow/CXL latency | 242.7 ns | 266.3 ns | +9.7% |
| Fast bandwidth | 139956.8 MB/s | 139062.8 MB/s | -0.64% |
| Slow/CXL bandwidth | 23535.3 MB/s | 23522.9 MB/s | -0.05% |

Bandwidth passes through almost identically in the VM. Latency is higher in the
VM, especially for local DRAM. The slow/CXL path still preserves the expected
latency gap and bandwidth gap relative to the fast node.
