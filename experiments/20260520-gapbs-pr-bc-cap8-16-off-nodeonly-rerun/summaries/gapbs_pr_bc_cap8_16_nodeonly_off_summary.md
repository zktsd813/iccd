# GAPBS PR/BC g28 Capacity 8G/16G Policy Rerun

Setup:

- Kernel: `Linux kernel 6.18.0modified #178 SMP PREEMPT_DYNAMIC Wed May 20 01:49:47 UTC 2026`
- VM: 96G, 32 vCPUs, guest node0 32G on host node0, guest node1 64G on host node2, KVM enabled.
- Graph: `/root/gapbs_graphs/kron_g28.sg`, loaded with `-f`; graph generation/build time excluded.
- Trials: `-n8`.
- Scan: 256MiB, 1000ms, fast scan off, hot threshold default.
- Ours: 5s window, local-access >=80% for 3 windows or residual remote <=20% for 3 windows.
- Off semantics for this rerun: node capacity configured, `memory.node_balancing=0`, `memory.kswapd_demotion_enabled=0`, global demotion disabled.

## Trial Average

Lower is better.

| workload | cap | off | on | ours | on/off | ours/off | on/ours |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| PR | 8G | 18.87299 | 36.44195 | 20.36242 | 1.931x | 1.079x | 1.790x |
| PR | 16G | 19.06677 | 20.83487 | 20.05267 | 1.093x | 1.052x | 1.039x |
| BC | 8G | 16.39678 | 49.49277 | 30.26469 | 3.018x | 1.846x | 1.635x |
| BC | 16G | 49.38733 | 41.87712 | 22.98882 | 0.848x | 0.465x | 1.822x |

## Counters

| workload | cap | policy | avg trial s | stop | hint faults | promoted | demoted |
| --- | --- | --- | ---: | --- | ---: | ---: | ---: |
| PR | 8G | off | 18.87299 |  | 0 | 0 | 0 |
| PR | 8G | on | 36.44195 |  | 45,164,520 | 6,527,491 | 15,685,628 |
| PR | 8G | ours | 20.36242 | 40.0s w8 local_access | 7,375,040 | 1,962,992 | 10,732,380 |
| PR | 16G | off | 19.06677 |  | 0 | 0 | 0 |
| PR | 16G | on | 20.83487 |  | 16,460,892 | 4,232,720 | 13,132,631 |
| PR | 16G | ours | 20.05267 | 35.0s w7 local_access | 5,365,535 | 1,061,961 | 10,034,397 |
| BC | 8G | off | 16.39678 |  | 0 | 0 | 0 |
| BC | 8G | on | 49.49277 |  | 58,695,591 | 7,249,562 | 20,535,422 |
| BC | 8G | ours | 30.26469 | 65.0s w13 local_access | 11,757,836 | 1,640,313 | 12,608,241 |
| BC | 16G | off | 49.38733 |  | 0 | 0 | 0 |
| BC | 16G | on | 41.87712 |  | 41,480,970 | 6,071,976 | 17,720,851 |
| BC | 16G | ours | 22.98882 | 70.0s w14 local_access | 10,502,170 | 1,326,698 | 12,225,913 |

Notes:

- All off cases recorded `kswapd_demotion_on=0` and `global_demotion_enabled=0`.
- Off demotion counters were all zero.
- Ours disabled migration in all four ours cases via `local_access`.
- BC 16G is the standout: node-only off was slower than on, while ours was fastest.
