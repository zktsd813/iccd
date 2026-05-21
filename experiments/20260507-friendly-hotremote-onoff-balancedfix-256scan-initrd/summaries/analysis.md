# FRIENDLY Hotset-Remote On/Off After Balanced-Accounting Fix

Date: 2026-05-07 UTC

## Run

- Experiment: `20260507-friendly-hotremote-onoff-balancedfix-256scan-initrd`
- Run ID: `friendly_hotremote_onoff_20260507T165745Z`
- Candidate: `skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent`
- Expected role: friendly
- Policies: `off,on`, one repetition each
- Placement: local-first-touch arena with only the 4 GiB friendly hotset/window first-touched on remote node1
- Output root: `/Serverless/iccd/experiments/20260507-friendly-hotremote-onoff-balancedfix-256scan-initrd/qemu-logs/phase_candidate_microbench/friendly_hotremote_onoff_20260507T165745Z`

## Kernel And VM Setup

- Kernel image: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`
- Initrd image: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-20260507T164413Z-promotion-debug.img`
- Guest kernel: `Linux kernel 6.18.0modified #121 SMP PREEMPT_DYNAMIC Thu May 7 16:47:15 UTC 2026 x86_64`
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

The initrd above was the fresh image built from the current `/Serverless/Migration-friendly/linux` tree for the active debug kernel. No kernel rebuild was needed for this on/off run.

Initial cgroup anon residency before measurement:

| policy | node0 anon | node1 anon |
| --- | ---: | ---: |
| off | 15.56 GiB | 48.44 GiB |
| on | 15.43 GiB | 48.57 GiB |

## Results

| policy | steady mean | steady median | promoted | demoted | hint faults | promotion candidates | over-high failures |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| off | 619.66 Mops/s | 620.82 Mops/s | 0 pages / 0.00 GiB | 123,648 pages / 0.47 GiB | 0 | 0 | 0 |
| on | 1441.81 Mops/s | 613.00 Mops/s | 1,048,575 pages / 4.00 GiB | 1,020,225 pages / 3.89 GiB | 2,931,230 | 1,493,279 | 443,762 |

On/off ratios:

- Full-run steady mean: `2.327x`
- Full-run steady median: `0.987x`
- Last 10 seconds mean: about `4.98x`

Throughput windows:

| policy | 0-20s mean | 20-40s mean | 40-60s mean | 50-60s mean |
| --- | ---: | ---: | ---: | ---: |
| off | 615.32 Mops/s | 622.83 Mops/s | 620.70 Mops/s | 619.50 Mops/s |
| on | 609.19 Mops/s | 629.28 Mops/s | 2961.95 Mops/s | 3085.21 Mops/s |

## Interpretation

This run confirms the FRIENDLY candidate under the current balanced-accounting
reclaimd fix. With migration off, the hotset remains remote and throughput stays
near 620 Mops/s. With migration on, the kernel promoted essentially the full 4
GiB hotset (`1,048,575` pages) and demoted about 3.89 GiB to preserve the local
cap. After the promotion ramp, throughput reaches about 3.09 Gops/s in the last
10 seconds, roughly 4.98x the off-policy tail rate.

The full-run median is misleading here because the on-policy run spends the
first half of the 60 second window before the hotset is fully local. The mean
and tail windows show the intended friendly behavior once promotion completes.

Debug counters show no rate-limit block: `debug_promote_rate_limited=0`.
Remaining promotion failures are post-candidate over-high rejects after the
useful 4 GiB hotset has already been promoted.

## Artifacts

- OFF summary: `/Serverless/iccd/experiments/20260507-friendly-hotremote-onoff-balancedfix-256scan-initrd/qemu-logs/phase_candidate_microbench/friendly_hotremote_onoff_20260507T165745Z/guest-artifacts/friendly_hotremote_onoff_20260507T165745Z/skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent__off__rep1/summary.json`
- ON summary: `/Serverless/iccd/experiments/20260507-friendly-hotremote-onoff-balancedfix-256scan-initrd/qemu-logs/phase_candidate_microbench/friendly_hotremote_onoff_20260507T165745Z/guest-artifacts/friendly_hotremote_onoff_20260507T165745Z/skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent__on__rep1/summary.json`
- Run metadata: `/Serverless/iccd/experiments/20260507-friendly-hotremote-onoff-balancedfix-256scan-initrd/qemu-logs/phase_candidate_microbench/friendly_hotremote_onoff_20260507T165745Z/guest-artifacts/friendly_hotremote_onoff_20260507T165745Z/run_meta.txt`
