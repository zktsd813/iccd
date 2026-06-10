# Fixed-Ops Microbenchmark Migration Overhead

Workload: `stream_read_32g_split16_4kstride`.

## Headline

- off elapsed: `264.169s`
- on elapsed: `717.758s`
- on/off execution-time ratio: `2.717x`
- extra wall time with migration on: `453.589s`
- on migrated pages: `6120817` (23.35 GiB)
- on NUMA hint faults: `64254203`

## Case Metrics

| case | target_ops | elapsed_s | ns/op | system_cpu_s | hint_faults | migrated_GiB | psi_some_s |
|---|---:|---:|---:|---:|---:|---:|---:|
| off | 43686414250 | 264.169 | 6.010 | 30.600 | 0 | 0.00 | 0.732 |
| on | 43686414250 | 717.758 | 16.326 | 4805.080 | 64254203 | 23.35 | 6.032 |
