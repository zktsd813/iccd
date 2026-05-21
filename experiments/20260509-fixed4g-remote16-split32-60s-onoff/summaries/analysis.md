# Fixed 4G Remote Friendly / Split32 Stream 60s On-Off

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
- `policies=off,on`
- `candidates=phase_fixed4g_remote_split32_stream4k_localft`
- Friendly phase: `fixed4g-hotset-remote`, 4 GiB mulshift hotset fixed at offset `16G..20G`, inside the unfriendly remote half `16G..32G`.
- Unfriendly phase: `stream-read-32g-split16-4k`, unchanged split32 stream read.
- Placement prefault: 0..16G local, 16G..64G remote via `window-split:0,1` head-local/tail-remote path.

## Offset Check
- `off` phase1 window offsets: `[17179869184]`
- `on` phase1 window offsets: `[17179869184]`

## Throughput

| phase | metric | off | on | on/off |
| --- | --- | ---: | ---: | ---: |
| friendly fixed4g | Mops/s | 228.83 | 1414.39 | 6.181x |
| unfriendly stream32 | MB/s | 4492.52 | 3150.06 | 0.701x |

## Migration Counters

| policy | phase | hints | PTE updates | promoted | demoted |
| --- | ---: | ---: | ---: | ---: | ---: |
| off | 1 | 0 | 0.00 GiB | 0.00 GiB | 0.00 GiB |
| off | 2 | 0 | 0.00 GiB | 0.00 GiB | 0.00 GiB |
| on | 1 | 1,637,496 | 55.52 GiB | 4.00 GiB | 4.28 GiB |
| on | 2 | 14,414,280 | 48.49 GiB | 10.05 GiB | 8.38 GiB |

## Artifacts
- `/Serverless/iccd/experiments/20260509-fixed4g-remote16-split32-60s-onoff/summaries/phase_summary.csv`
- `/Serverless/iccd/experiments/20260509-fixed4g-remote16-split32-60s-onoff/summaries/phase_migration.csv`
- `/Serverless/iccd/experiments/20260509-fixed4g-remote16-split32-60s-onoff/summaries/phase_10s.csv`
