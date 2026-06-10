# Fault Latency Histogram - Local 16G / Hotset 32G

## Configuration

- VM: fast/local 16G, slow 64G, host-cxl
- Workload: existing fixed-ops microbenchmark, 32G shared hotset, 32 threads
- Placement: `window-split:0,1`, `window_split_local=16G`
- Cases: migration off (`numa_balancing=0`) and migration on (`numa_balancing=2`)
- Target ops: `43686414250`
- Kernel: `/Serverless/iccd-git/linux-global-build/arch/x86/boot/bzImage`

## Result

| case | elapsed_s | ns/op | system_cpu_s | hint_faults | migrated_pages | migrated_GiB |
|---|---:|---:|---:|---:|---:|---:|
| off | 264.169 | 6.010 | 30.600 | 0 | 0 | 0.00 |
| on | 717.758 | 16.326 | 4805.080 | 64254203 | 6120817 | 23.35 |

Migration on took `2.717x` longer than off for the same fixed ops.

## Remote Fault Latency Histogram

The histogram is from `on/after.fault_latency_histograms`. Counts are pages.

| bucket_ms | pages | percent |
|---|---:|---:|
| <=128 | 4197883 | 6.53% |
| <=256 | 1964192 | 3.06% |
| <=512 | 3824747 | 5.95% |
| <=1024 | 8873815 | 13.81% |
| <=2048 | 16043458 | 24.97% |
| <=4096 | 24759753 | 38.53% |
| <=8192 | 4590337 | 7.14% |
| >8192 | 18 | 0.00% |

Total remote histogram pages: `64254203`, matching `numa_hint_faults_delta`.
