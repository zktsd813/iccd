# Node Capacity Microbench Smoke

- Kernel: `Linux kernel 6.18.0modified #178 SMP PREEMPT_DYNAMIC Wed May 20 01:49:47 UTC 2026`
- VM: 16G total, guest node0 8G on host node0, guest node1 8G on host node2, 8 vCPUs pinned to host CPUs 0-7, KVM enabled.
- Workload: `/root/mbench --mode bw --bw-kernel read --arena-size 6G --window-size 6G --move-policy fixed --placement none --bw-stride 512 --bw-block 4K --bw-shared-window --threads 8 --sample-ms 1000 --csv`
- Cgroup knobs: `memory.node_capacity=node0 524288`, `memory.node_balancing=2`, `memory.kswapd_demotion_enabled=0`, MGLRU `0x0007`.
- Runtime: 80s timeout smoke, including mbench warmup and 56 measured 1s samples.

## Result

- Average measured throughput: 6.189 GiB/s.
- Node0 high watermark: 513802 pages.
- During run, `node0_usage_exact` stayed at 513800 pages, just under the high watermark.
- During run, cgroup `anon` placement stayed at `N0=2104524800`, `N1=4338446336`.
- `memory.reclaimd_state`: `wake_count=0`, `run_count=0`, `mode=0`.
- Cgroup demotion counters: `pgdemote_kswapd=0`, `pgdemote_direct=0`, `pgdemote_khugepaged=0`, `pgdemote_proactive=0`.
- Global vmstat deltas: all `pgdemote_*` counters were 0.

Conclusion: with demotion disabled and node0 capacity configured, first-touch allocation was capped near node0 high watermark and the remaining memory was placed on node1 without invoking cgroup reclaimd demotion.
