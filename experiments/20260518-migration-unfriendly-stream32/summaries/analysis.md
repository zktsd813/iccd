# Migration-Unfriendly Stream32 Validation

Date: 2026-05-18 UTC

## Setup

- Kernel image: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Fresh initrd: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-unfriendly-stream32-20260518.img`
- Guest kernel: `Linux kernel 6.18.0modified #174 SMP PREEMPT_DYNAMIC Mon May 18 05:41:20 UTC 2026`
- KVM: enabled (`-accel kvm`)
- VM: `CPUS=32`, `MEMORY=96G`
- Guest node0: CPUs `0-31`, memory `32G`, host node `0`
- Guest node1: memory `64G`, host node `2`
- QEMU memory policy: `bind`, prealloc enabled
- MGLRU runtime: `lru_gen_enabled=0x0007`
- Cgroup local cap: `CAPACITY_PAGES=4194304` (`16 GiB`)
- Scan tuning: `NUMA_SCAN_SIZE_MB=4096`, effective scan period min `1000 ms`, `NUMA_FAST_SCAN=0`
- Migration policy: off vs on, with `NODE_BALANCING_ON=2`, `KSWAPD_DEMOTION_ON=1`, `GLOBAL_NUMA_ON=0`
- Diagnostic/adaptive knobs: earlystop off, pingpong-stat off, promote-sample-stat off, local-fault sampling off

## Workload

```text
stream_read_32g_split16_4kstride
```

Guest command shape:

```text
mbench --mode bw --bw-kernel read \
  --arena-size 32G --window-size 32G \
  --move-policy fixed \
  --placement window-split:0,1 \
  --bw-stride 512 --bw-block 4K \
  --threads 32
```

The 32 GiB active window is initially split across node0 and node1. Before
measurement, cgroup anon residency was approximately:

| policy | node0 anon | node1 anon |
| --- | ---: | ---: |
| off | 14.60 GiB | 17.40 GiB |
| on | 14.60 GiB | 17.40 GiB |

## Result

| policy | steady mean | steady median | CV | promoted | demoted | hint faults | PTE updates |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| off | 4293.37 MiB/s | 4294.00 MiB/s | 0.0025 | 0 pages | 0 pages | 0 | 0 |
| on | 1515.70 MiB/s | 1460.00 MiB/s | 0.2637 | 3,054,275 pages / 11.65 GiB | 2,898,169 pages / 11.06 GiB | 13,642,702 | 13,642,746 |

- Mean on/off ratio: `0.353x`
- Median on/off ratio: `0.340x`
- Mean slowdown: `2.83x`

## Conclusion

The benchmark is still strongly migration-unfriendly with the freshly rebuilt
kernel and initrd. Migration-on causes about 11.65 GiB of promotions and
11.06 GiB of direct demotions during the measured window, while throughput drops
to about 35% of migration-off.

Run root:

```text
/Serverless/iccd/experiments/20260518-migration-unfriendly-stream32/qemu-logs/phase_candidate_microbench/20260518T053827Z-stream32-unfriendly
```
