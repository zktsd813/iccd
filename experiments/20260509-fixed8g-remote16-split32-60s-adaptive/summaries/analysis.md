# Fixed 8G Remote Friendly / Split32 Stream 60s Adaptive

## Setup
- `kernel=Linux kernel 6.18.0modified #163 SMP PREEMPT_DYNAMIC Sat May  9 12:53:28 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux`
- `lru_gen_enabled=0x0007`
- `numa_scan_size_mb=256`
- `effective_numa_scan_size_mb=256`
- `numa_scan_period_min_ms=1000`
- `effective_numa_scan_period_min_ms=1000`
- `numa_fast_scan=0`
- `phase_ms=60000`
- `phase_repeat=1`
- `policies=off,on,adaptive_cgroup`
- `candidates=phase_fixed8g_remote_split32_stream4k_localft`
- Friendly phase: `fixed8g-hotset-remote`, 8 GiB mulshift hotset fixed at offset `16G..24G`, inside the unfriendly remote half `16G..32G`.
- Unfriendly phase: `stream-read-32g-split16-4k`, unchanged split32 stream read.
- Placement prefault: `0..16G` local, `16G..64G` remote via head-local/tail-remote `window-split:0,1`.

## Adaptive Controller
```text
2026-05-09T18:10:57Z phase=1 kind=friendly policy=adaptive_cgroup global=0 cgroup_node_balancing=2
2026-05-09T18:11:57Z phase=2 kind=sparse policy=adaptive_cgroup global=0 cgroup_node_balancing=0
```

## Offset Check
- `off` phase1 window offsets: `[17179869184]`
- `on` phase1 window offsets: `[17179869184]`
- `adaptive` phase1 window offsets: `[17179869184]`

## Throughput

| phase | metric | off | on | adaptive | on/off | adaptive/off |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| friendly fixed8g | Mops/s | 227.21 | 1151.28 | 1177.93 | 5.067x | 5.184x |
| unfriendly stream32 | MB/s | 4511.39 | 3721.33 | 4440.93 | 0.825x | 0.984x |

## Migration Counters

| policy | phase | hints | PTE updates | promoted | demoted |
| --- | ---: | ---: | ---: | ---: | ---: |
| off | 1 | 0 | 0.00 GiB | 0.00 GiB | 0.00 GiB |
| off | 2 | 0 | 0.00 GiB | 0.00 GiB | 0.00 GiB |
| on | 1 | 4,166,738 | 62.76 GiB | 8.00 GiB | 7.91 GiB |
| on | 2 | 13,756,706 | 49.89 GiB | 7.61 GiB | 6.33 GiB |
| adaptive | 1 | 4,085,109 | 62.48 GiB | 8.00 GiB | 7.94 GiB |
| adaptive | 2 | 0 | 0.00 GiB | 0.00 GiB | 0.00 GiB |

## Files
- `/Serverless/iccd/experiments/20260509-fixed8g-remote16-split32-60s-adaptive/summaries/phase_summary.csv`
- `/Serverless/iccd/experiments/20260509-fixed8g-remote16-split32-60s-adaptive/summaries/phase_migration.csv`
- `/Serverless/iccd/experiments/20260509-fixed8g-remote16-split32-60s-adaptive/summaries/phase_10s.csv`
