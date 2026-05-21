# GAPBS PR/BC VM node0 8G/16G root-cgroup on/off

## Setup

- Kernel image: `/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage`.
- Initrd: `/Serverless/Migration-friendly/scripts/kernel/kernel-artifacts/initramfs-6.18.0modified-window-bucket-smoke-20260519.img`.
- VM total memory: 96G, 32 vCPUs pinned to host CPUs 0-31, node0 backed by host node0, node1 backed by host node2, KVM enabled.
- Local sizes: physical guest node0 8G and 16G. No experiment cgroup capacity/controller was used.
- Workload shell moved to root cgroup before running each VM batch; each case reports `self_cgroup=0::/`.
- Graph input: `/root/gapbs_graphs/kron_g28.sg` with GAPBS `-f`; graph generation/build time excluded.
- PR command: `/root/pr -f /root/gapbs_graphs/kron_g28.sg -i20 -t1e-4 -n8`.
- BC command: `/root/bc -f /root/gapbs_graphs/kron_g28.sg -i1 -n8`.
- Before every case: `sync; echo 3 > /proc/sys/vm/drop_caches`.
- Off: `numa_balancing=0`, `demotion_enabled=false`, `demotion_target=0 -1`.
- On: `numa_balancing=2`, `demotion_enabled=true`, `demotion_target=0 1`.
- Runtime scan knobs: `scan_size_mb=256`, `scan_period_min_ms=1000`, MGLRU `0x0007`.

## Average trial time

| local | workload | off avg (s) | on avg (s) | on/off time | off/on speed |
|---:|---|---:|---:|---:|---:|
| 8G | PR | 33.46017 | 79.72247 | 2.383x | 0.420x |
| 8G | BC | 49.05671 | 54.21028 | 1.105x | 0.905x |
| 16G | PR | 30.61052 | 34.97439 | 1.143x | 0.875x |
| 16G | BC | 46.50356 | 46.81693 | 1.007x | 0.993x |

## Migration counters

| local | workload | policy | hint faults | PTE updates | promoted | demoted kswapd | migrated |
|---:|---|---|---:|---:|---:|---:|---:|
| 8G | PR | off | 0 | 0 | 0 | 0 | 0 |
| 8G | PR | on | 39,507,091 | 39,506,937 | 929,402 | 1,958,045 | 2,920,483 |
| 8G | BC | off | 0 | 0 | 0 | 0 | 9,825 |
| 8G | BC | on | 15,215,563 | 15,215,549 | 1,542,031 | 2,964,162 | 4,556,736 |
| 16G | PR | off | 0 | 0 | 0 | 0 | 0 |
| 16G | PR | on | 30,392,618 | 30,834,389 | 1,488,354 | 2,877,356 | 4,459,930 |
| 16G | BC | off | 0 | 0 | 0 | 0 | 1,125 |
| 16G | BC | on | 12,887,595 | 12,887,540 | 1,513,007 | 3,768,985 | 5,348,726 |

## Trial times

| local | workload | policy | read (s) | t1 | t2 | t3 | t4 | t5 | t6 | t7 | t8 |
|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 8G | PR | off | 28.11013 | 25.40482 | 33.21009 | 35.34382 | 34.65507 | 34.47089 | 34.81905 | 34.65516 | 35.12245 |
| 8G | PR | on | 25.57101 | 36.27398 | 61.74583 | 76.78824 | 94.28063 | 81.60085 | 94.77211 | 96.41487 | 95.90326 |
| 8G | BC | off | 24.66335 | 53.67586 | 48.53405 | 42.10180 | 54.57827 | 49.26050 | 50.91230 | 42.26026 | 51.13067 |
| 8G | BC | on | 27.36336 | 53.91789 | 46.63004 | 46.11209 | 60.99749 | 56.74761 | 58.69827 | 47.12585 | 63.45301 |
| 16G | PR | off | 32.94551 | 18.74824 | 24.46748 | 30.86573 | 34.07226 | 34.34605 | 33.76196 | 34.32064 | 34.30181 |
| 16G | PR | on | 23.94151 | 19.01331 | 20.18309 | 29.77808 | 25.79258 | 26.97997 | 50.10625 | 59.92186 | 48.01997 |
| 16G | BC | off | 25.62007 | 54.56201 | 47.79681 | 40.97059 | 47.32277 | 46.39360 | 47.15051 | 40.05031 | 47.78192 |
| 16G | BC | on | 23.61457 | 53.80007 | 41.18565 | 40.50164 | 51.89682 | 47.19774 | 48.34517 | 40.69567 | 50.91266 |

## Artifact directories

- node0=8G: `/Serverless/iccd/experiments/20260519-gapbs-pr-bc-vmnode8-16-rootcg-onoff/qemu-logs/20260519T105857Z-node8-rootcg-onoff/guest-artifacts/gapbs-vmnode8-rootcg-onoff`
- node0=16G: `/Serverless/iccd/experiments/20260519-gapbs-pr-bc-vmnode8-16-rootcg-onoff/qemu-logs/20260519T113054Z-node16-rootcg-onoff/guest-artifacts/gapbs-vmnode16-rootcg-onoff`
