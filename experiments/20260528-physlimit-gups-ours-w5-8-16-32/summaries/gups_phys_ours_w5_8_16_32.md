# GUPS physical ours w5, 8G/16G/32G

Date: 2026-05-28.

Kernel image: `/Serverless/iccd/linux-build-mt/arch/x86/boot/bzImage`.
Initrd: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified.img`.
Guest kernel: `6.18.0modified+ #10 SMP PREEMPT_DYNAMIC Fri May 22 03:33:06 UTC 2026`.
MGLRU runtime: `0x0007`.

Topology: 32 vCPUs pinned to host CPUs 0-31. Guest node0 is backed by host node0 DRAM and physically sized to 8G, 16G, or 32G. Guest node1 is backed by host node2 CXL memory, with total VM memory fixed at 168G. QEMU memory policy was `bind` with preallocation.

Policy: `ours`, 5s window, `node_balancing=2` initially, local-fault sampling knob `numa_local_fault_on_tiering=10`, `numa_local_fault_refault_hit_ms=2000`, threshold 80%, 3 consecutive windows, eval lag `prev`. Cgroup node capacity was disabled with `capacity_pages=0`; this is the physical node0-size experiment.

## Result

| physical local | node0 size | node1 size | GUPS Took (s) | script elapsed (s) | migration off |
| --- | ---: | ---: | ---: | ---: | --- |
| 8G | 7,958 MiB | 161,276 MiB | 649.809 | 653 | 55.025s, window 11 |
| 16G | 16,022 MiB | 153,212 MiB | 526.184 | 529 | 45.020s, window 9 |
| 32G | 32,150 MiB | 137,084 MiB | 316.184 | 318 | 45.023s, window 9 |

## Off Decision Row

| physical local | reason | access pct | remote ratio pct | pte delta | refault delta | hint fault delta |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 8G | local_access | 100.00 | 24.38 | 45,456 | 45,456 | 1,008,979 |
| 16G | local_access | 99.08 | 85.41 | 64,391 | 63,797 | 2,351,443 |
| 32G | local_access | 100.00 | 96.42 | 19,683 | 19,683 | 3,136,053 |

## VMStat Deltas

| physical local | hint faults | promoted | demote kswapd | demote direct | demote total | migrate success |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 8G | 15,627,013 | 1,170,340 | 2,217,855 | 0 | 2,217,855 | 3,588,956 |
| 16G | 13,972,474 | 907,755 | 1,682,297 | 0 | 1,682,297 | 2,591,627 |
| 32G | 9,387,072 | 614,077 | 629,170 | 0 | 629,170 | 1,553,814 |

## Local-Fault Totals

| physical local | PTE updates | refault | refault hit |
| --- | ---: | ---: | ---: |
| 8G | 521,933 | 422,306 | 306,165 |
| 16G | 867,553 | 796,562 | 496,246 |
| 32G | 1,628,620 | 1,628,613 | 1,000,360 |

Artifacts:

- Runner: `notes/run_phys_gups_ours_w5.sh`
- Raw results: `guest-results/{8g,16g,32g}/ours_w5/`
- CSV summary: `summaries/gups_phys_ours_w5_8_16_32.csv`
