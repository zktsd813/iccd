# Fault Latency Histogram - Local 16G / Sample Rate 10 / On Only

## Configuration

- VM: fast/local 16G, slow 64G, host-cxl
- Workload: existing fixed-ops microbenchmark, 32G shared hotset, 32 threads
- Placement: `window-split:0,1`, `window_split_local=16G`
- Case: migration on only (`numa_balancing=2`)
- `local_fault_rate=10`
- `target_ops=21843207125`

## Result

| elapsed_s | ns/op | system_cpu_s | hint_faults | migrated_pages | migrated_GiB |
|---:|---:|---:|---:|---:|---:|
| 335.738072 | 15.018 | 2489.06 | 33637606 | 3254704 | 12.42 |

## Local And Remote Fault Latency Histogram

- local total pages: `375506`
- remote total pages: `33262100`

| bucket_ms | local_pages | local_pct | remote_pages | remote_pct |
|---|---:|---:|---:|---:|
| <=128 | 3209 | 0.85% | 2520589 | 7.58% |
| <=256 | 0 | 0.00% | 1212262 | 3.64% |
| <=512 | 0 | 0.00% | 2277296 | 6.85% |
| <=1024 | 0 | 0.00% | 4807221 | 14.45% |
| <=2048 | 0 | 0.00% | 7741015 | 23.27% |
| <=4096 | 14 | 0.00% | 12378541 | 37.22% |
| <=8192 | 32 | 0.01% | 2325160 | 6.99% |
| >8192 | 372251 | 99.13% | 16 | 0.00% |
