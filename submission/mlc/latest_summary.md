# VM MLC Result (20260610T054936Z-vm-mlc)

## VM setup

- Kernel: `Linux kernel 6.18.0modified #11 SMP PREEMPT_DYNAMIC Tue Jun  9 17:21:21 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux`
- VM memory: node0 fast `16G` backed by host node0, node1 slow `32G` backed by host node2
- Guest CPUs: node0 `0-31`; guest node1 is CPU-less
- Slow memory mode: `host-cxl` with HMAT `80 ns / 40000M` fast and `250 ns / 10000M` slow
- Network device used for this run: `e1000` with static qemu-usernet `10.0.2.15/24`
- Runtime knobs before MLC: `numa_balancing=0`, `demotion_enabled=false`, `lru_gen_enabled=0x0007`
- Guest memory tiers: `/sys/devices/virtual/memory_tiering/memory_tier4/nodelist=0; /sys/devices/virtual/memory_tiering/memory_tier56/nodelist=1`

## Host backing check

| Host node | QEMU memory MB |
| --- | ---: |
| node0 | 16431.66 |
| node1 | 3.23 |
| node2 | 32768.05 |

## MLC results

Latency command: `/root/mlc --latency_matrix -e -r`  
Bandwidth command: `/root/mlc --bandwidth_matrix -e`

| CPU node -> memory node | Latency ns | Read bandwidth MB/s |
| --- | ---: | ---: |
| guest node0 -> guest node0 | 151.4 | 138585.5 |
| guest node0 -> guest node1 | 273.8 | 23445.2 |

Slow/fast latency ratio: `1.808x`  
Slow/fast bandwidth ratio: `0.169x`

## Raw files

- `guest-logs/mlc_latency_matrix.txt`
- `guest-logs/mlc_bandwidth_matrix.txt`
- `guest-logs/pre-mlc-metadata.txt`
- `host-logs/placement.log`
- `host-logs/serial-final.log`
