# Latency-Bucket Phase-On Verification

Run: `/Serverless/iccd/experiments/20260508-latencybucket-phase-on-verify-initrd/qemu-logs/phase_candidate_microbench/latbucket-phase-on-20260508T132738Z`

## Setup

- Kernel: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Initrd: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-latbucket-phase-on-20260508.img`
- Guest kernel: `Linux kernel 6.18.0modified #154 SMP PREEMPT_DYNAMIC Fri May 8 13:29:54 UTC 2026`
- KVM: enabled
- VM: `CPUS=32`, `MEMORY=96G`, node0 `32G`, node1 `64G`
- Host binding: node0 memory bound to host node0, node1 memory bound to host node2, `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1`
- Cgroup cap: `CAPACITY_PAGES=4194304` (16GiB)
- MGLRU: `lru_gen_enabled=0x0007`
- Knobs: `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2`, `KSWAPD_DEMOTION_ON=1`, `OFF_DEMOTION_ON=1`
- Diagnostics: `NUMA_MIGRATION_STOP_ENABLED=0`, `NUMA_PINGPONG_STAT_ENABLED=0`, `NUMA_PROMOTE_SAMPLE_STAT_ENABLED=0`
- Scan: `NUMA_SCAN_SIZE_MB=256`, effective `256`, `SCAN_PERIOD_SCALE=100`, `HOT_THRESHOLD_MS=0`
- Workload: `phase_mulshift4g_block2m_sparse64_localft`, policy `on`, `PHASE_MS=60000`, `PHASE_REPEAT=3`, local-first-touch placement.
- Command: `mbench --phase-preset mulshift4g-block2m-sparse64 --phase-ms 60000 --phase-repeat 3 --threads 32 --duration-ms 360000`

Initial measured residency after prefault:

- `anon N0=16597979136` bytes = 15.46GiB
- `anon N1=52121747456` bytes = 48.54GiB

Initial node0 reclaimd values from live sample:

- capacity: 4194304 pages = 16.00GiB
- low watermark: 3984588 pages = 15.20GiB
- high watermark: 4110417 pages = 15.68GiB
- usage_lru: 4052259 pages = 15.46GiB

## Result

Overall measured deltas:

- hint faults: 25,802,860 pages
- promoted: 5,574,448 pages = 21.26GiB
- demoted: 6,164,811 pages = 23.52GiB (`pgdemote_direct`; `pgdemote_kswapd=0`)
- promotion allocation/over-high/block failures: all 0
- `debug_promote_wmark_bypass=0`
- `debug_promote_wmark_no_bypass=25,802,860`
- `debug_promote_latency_pass=5,574,448`
- `debug_promote_latency_fail=20,228,412`
- latency buckets:
  - `<1s`: 4,691,232
  - `1-2s`: 2,352,327
  - `2-4s`: 2,479,113
  - `4-8s`: 818,026
  - `8-60s`: 8,266,477
  - `>=60s`: 7,195,685

## Phase Deltas

| phase | workload | promoted | demoted direct | enter | bypass | no-bypass | latency pass | latency fail | pass ratio | threshold end |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | friendly | 0 / 0.00GiB | 135,724 / 0.52GiB | 0 | 0 | 0 | 0 | 0 | 0.0% | 0 |
| 2 | sparse | 2,308,103 / 8.80GiB | 2,039,098 / 7.78GiB | 11,919,885 | 0 | 11,919,886 | 2,308,105 | 9,611,783 | 19.4% | 1125 |
| 3 | friendly | 0 / 0.00GiB | 0 / 0.00GiB | 0 | 0 | 0 | 0 | 0 | 0.0% | 1250 |
| 4 | sparse | 997,318 / 3.80GiB | 997,316 / 3.80GiB | 2,493,908 | 0 | 2,493,908 | 997,319 | 1,496,589 | 40.0% | 1375 |
| 5 | friendly | 0 / 0.00GiB | 0 / 0.00GiB | 0 | 0 | 0 | 0 | 0 | 0.0% | 1500 |
| 6 | sparse | 1,353,375 / 5.16GiB | 1,091,337 / 4.16GiB | 5,598,030 | 0 | 5,598,030 | 1,353,346 | 4,244,684 | 24.2% | 1625 |

## Interpretation

The tested hypothesis was: early promotion was high because local memory headroom allowed watermark bypass, then later phases failed the latency pass.

This run does not support the first half. `debug_promote_wmark_bypass` stayed at 0 for the whole run. All promotion decisions went through `wmark_no_bypass` and then the latency filter. Initial node0 usage was already around 15.46GiB against a 16GiB cap, above the low watermark and close to the high watermark, so there was no broad "free headroom bypass" window.

The second half is largely correct: once candidates appeared, most candidates failed the latency filter. Overall only 21.6% of promote-enter pages passed latency, while 78.4% failed. The high failure volume is not an over-high or node1 allocation problem in this run; those counters remained 0. The dominant failure signal is long scan-to-fault latency, especially the `8-60s` and `>=60s` buckets.

The first large promotion burst happened at the first sparse phase, not during the first friendly phase. With `SCAN_PERIOD_SCALE=100` and `NUMA_SCAN_SIZE_MB=256`, the first friendly 60s phase had no hint-fault/promote events in the steady sample window. The first scan/candidate burst arrived around the phase-1 to phase-2 boundary, so the apparent early promotion is better explained as delayed scanner/candidate timing plus latency-pass subset, not local-headroom bypass.
