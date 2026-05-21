# GAPBS On-Only Reclaim-Retry Verification

Setup:

- Kernel: `Linux kernel 6.18.0modified #179 SMP PREEMPT_DYNAMIC Wed May 20 03:30:57 UTC 2026`
- Initrd: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified.img`
- VM: 96G, 32 vCPUs, guest node0 32G on host node0, guest node1 64G on host node2, KVM enabled.
- Graph: `/root/gapbs_graphs/kron_g28.sg`, loaded with `-f`; graph generation/build time excluded.
- Policy: `on` only, `memory.node_balancing=2`, `memory.kswapd_demotion_enabled=1`.
- Scan: 256MiB, 1000ms, fast scan off, hot threshold default.
- Trials: `-n8`.

## Result

| workload | cap | avg trial s | elapsed s | hint faults | promoted | demoted |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| PR | 8G | 45.41178 | 401 | 52,597,020 | 21,198,576 | 33,005,110 |
| PR | 16G | 44.05163 | 379 | 43,907,394 | 11,137,279 | 19,988,482 |
| BC | 8G | 52.61184 | 453 | 60,838,776 | 8,362,356 | 21,209,217 |
| BC | 16G | 19.98134 | 189 | 25,768,089 | 5,865,954 | 16,721,185 |

## Comparison

| workload | cap | previous #176 on | #178 hard-gate on | #179 retry-restored on |
| --- | --- | ---: | ---: | ---: |
| PR | 8G | 73.73012 | 36.44195 | 45.41178 |
| PR | 16G | 33.59678 | 20.83487 | 44.05163 |
| BC | 8G | 50.27976 | 49.49277 | 52.61184 |
| BC | 16G | 37.90892 | 41.87712 | 19.98134 |

Notes:

- All four cases kept `memory.node_balancing=2` and `memory.kswapd_demotion_enabled=1`.
- Promotion/demotion counters increased relative to the #178 hard-gate result in the PR cases, confirming that the reclaim/demotion retry path is active again.
- BC 16G improved substantially relative to both prior runs, so performance is not a byte-for-byte return to the #176 result. The kernel path is restored, but BC remains sensitive to placement/run state.
