# Unfriendly Remote-Firsttouch On/Off After Balanced-Accounting Fix

Date: 2026-05-07 UTC

## Run

- Experiment: `20260507-unfriendly-remoteft-onoff-balancedfix-256scan-initrd`
- Run ID: `unfriendly_remoteft_onoff_20260507T171412Z`
- Candidate: `sparse_stride_read_64g_block2m_remoteft`
- Expected role: unfriendly candidate
- Policies: `off,on`, one repetition each
- Placement: 64 GiB arena remote-first-touched on node1 before measurement
- Output root: `/Serverless/iccd/experiments/20260507-unfriendly-remoteft-onoff-balancedfix-256scan-initrd/qemu-logs/phase_candidate_microbench/unfriendly_remoteft_onoff_20260507T171412Z`

## Kernel And VM Setup

- Kernel image: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Initrd image: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T171412Z-unfriendly.img`
- Guest kernel: `Linux kernel 6.18.0modified #121 SMP PREEMPT_DYNAMIC Thu May 7 16:47:15 UTC 2026 x86_64`
- Initrd build: enabled for this run, launcher reported `jobs=64`
- KVM: enabled, QEMU launched with `-accel kvm`
- VM CPU: `CPUS=32`, `HOST_CPUS=0-31`, guest node0 CPUs `0-31`
- VM memory: `MEMORY=96G`, guest node0 `32G`, guest node1 `64G`
- Host binding: guest node0 memory bound to host node0 DRAM, guest node1 memory bound to host node2 CXL
- QEMU memory policy: `NUMA_MEM_POLICY=bind`, `NUMA_PREALLOC=1`
- cgroup cap: `CAPACITY_PAGES=4194304` pages, 16 GiB local cap
- Migration knobs: `GLOBAL_NUMA_ON=0`, `NODE_BALANCING_ON=2`
- Demotion knobs: `KSWAPD_DEMOTION_ON=1`, `OFF_DEMOTION_ON=1`
- Scan tuning: `NUMA_SCAN_SIZE_MB=256`, `SCAN_PERIOD_SCALE=1`, `HOT_THRESHOLD_MS=0`
- MGLRU runtime: `/sys/kernel/mm/lru_gen/enabled=0x0007`, `min_ttl_ms=0`

Initial cgroup anon residency before measurement:

| policy | node0 anon | node1 anon |
| --- | ---: | ---: |
| off | 0.00 GiB | 62.38 GiB |
| on | 0.00 GiB | 62.37 GiB |

## Results

| policy | steady mean | steady median | promoted | demoted | hint faults | promotion candidates | over-high failures |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| off | 407.79 MiB/s | 408.00 MiB/s | 0 pages / 0.00 GiB | 0 pages / 0.00 GiB | 0 | 0 | 0 |
| on | 1077.16 MiB/s | 1104.00 MiB/s | 3,718,762 pages / 14.19 GiB | 356,984 pages / 1.36 GiB | 5,411,573 | 1,744,754 | 1,320,932 |

On/off ratios:

- Full-run steady mean: `2.641x`
- Full-run steady median: `2.706x`
- Last 10 seconds mean: about `1.92x`

Throughput windows:

| policy | 0-20s mean | 20-40s mean | 40-60s mean | 50-60s mean |
| --- | ---: | ---: | ---: | ---: |
| off | 408.80 MiB/s | 404.40 MiB/s | 410.20 MiB/s | 410.91 MiB/s |
| on | 1032.22 MiB/s | 1375.20 MiB/s | 792.84 MiB/s | 789.60 MiB/s |

## Interpretation

This run does not validate `sparse_stride_read_64g_block2m_remoteft` as an
unfriendly negative case under the current 256 MiB scan and balanced-accounting
kernel. Migration on improved full-run mean throughput by `2.641x`, even
though the later window drops as the 64 GiB sparse footprint churns.

The on-policy run promoted `14.19 GiB` and demoted `1.36 GiB`. The kernel also
recorded `numa_demote_promoted=351,441` pages, so some promoted pages were
demoted again, but not enough to make migration harmful. Debug counters show
`debug_promote_rate_limited=0` and `debug_promote_latency_fail=0`; remaining
failures are primarily post-candidate over-high rejects.

Use this result as another rejection of the current remote-firsttouch block2M
sparse candidate as the unfriendly baseline for 256 MiB scan experiments. It
still needs a replacement or a different tuning if a negative case is required.

## Artifacts

- OFF summary: `/Serverless/iccd/experiments/20260507-unfriendly-remoteft-onoff-balancedfix-256scan-initrd/qemu-logs/phase_candidate_microbench/unfriendly_remoteft_onoff_20260507T171412Z/guest-artifacts/unfriendly_remoteft_onoff_20260507T171412Z/sparse_stride_read_64g_block2m_remoteft__off__rep1/summary.json`
- ON summary: `/Serverless/iccd/experiments/20260507-unfriendly-remoteft-onoff-balancedfix-256scan-initrd/qemu-logs/phase_candidate_microbench/unfriendly_remoteft_onoff_20260507T171412Z/guest-artifacts/unfriendly_remoteft_onoff_20260507T171412Z/sparse_stride_read_64g_block2m_remoteft__on__rep1/summary.json`
- Run metadata: `/Serverless/iccd/experiments/20260507-unfriendly-remoteft-onoff-balancedfix-256scan-initrd/qemu-logs/phase_candidate_microbench/unfriendly_remoteft_onoff_20260507T171412Z/guest-artifacts/unfriendly_remoteft_onoff_20260507T171412Z/run_meta.txt`
