# Friendly P1 off/on analysis

Scope:

- Run: `20260509T0518Z-remoteonly-phase2-120s-baseline`
- Candidate: `phase_move15s4g_remote_split32_stream4k_localft`
- Phase: P1 friendly, `move15s-hotset-4g-remote`, 120s

## Distribution

| policy | mean Mops/s | median Mops/s | p10 | p90 |
| --- | ---: | ---: | ---: | ---: |
| off | 228.58 | 228.33 | 227.67 | 229.56 |
| on | 271.48 | 228.20 | 225.44 | 439.54 |
| adaptive | 268.99 | 228.33 | 225.39 | 425.46 |

The mean shows an on/off gain, but the median is effectively identical. That
means the friendly benefit is not steady across the phase; it comes from a few
high-throughput bursts.

## 15s Hotset Buckets

| bucket | hotset offset | off | on | on/off |
| --- | ---: | ---: | ---: | ---: |
| 0-15s | 16G | 223.41 | 342.00 | 1.531x |
| 15-30s | 20G | 228.28 | 330.90 | 1.450x |
| 30-45s | 44G | 228.03 | 235.10 | 1.031x |
| 45-60s | 60G | 228.24 | 222.02 | 0.973x |
| 60-75s | 16G | 228.12 | 232.40 | 1.019x |
| 75-90s | 32G | 228.35 | 226.50 | 0.992x |
| 90-105s | 32G | 228.44 | 227.73 | 0.997x |
| 105-120s | 28G | 228.26 | 343.41 | 1.504x |

Most buckets are flat at the off baseline. Only 0-30s and 105-120s carry most
of the mean gain.

## Promotion Timing

In P1 `on`, promotions are bursty:

- 3-5s: promotion jumps to about 0.43M pages.
- 21-25s: promotion jumps to about 0.95M pages.
- 58-60s: promotion jumps to about 1.38M pages.
- 109-111s: promotion jumps to about 1.84M pages.

The friendly hotset moves every 15s. Promotion therefore often arrives late
relative to the active hotset. If a promotion burst lands near the end of a
hotset window, the next 15s window moves somewhere else and the benefit does
not continue.

## 15s Counter Buckets

`on` P1 counters by hotset bucket:

| bucket | offset | mean Mops/s | hint faults | promotions | direct demotions | node0 anon start/end |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 0-15s | 16G | 342.00 | 1091966 | 433873 | 432040 | 14.60 -> 14.61 GiB |
| 15-30s | 20G | 330.90 | 1099891 | 513110 | 438592 | 14.61 -> 14.89 GiB |
| 30-45s | 44G | 235.10 | 633178 | 0 | 0 | 14.89 -> 14.89 GiB |
| 45-60s | 60G | 222.02 | 861850 | 429694 | 159745 | 14.89 -> 15.92 GiB |
| 60-75s | 16G | 232.40 | 408241 | 0 | 232576 | 15.75 -> 14.86 GiB |
| 75-90s | 32G | 226.50 | 0 | 0 | 0 | 14.86 -> 14.86 GiB |
| 90-105s | 32G | 227.73 | 0 | 0 | 0 | 14.86 -> 14.86 GiB |
| 105-120s | 28G | 343.41 | 1240223 | 469584 | 416284 | 14.86 -> 15.06 GiB |

Across the whole friendly phase, `on` promoted `1846272` pages, about
`7.04 GiB`, but also directly demoted about `6.4 GiB` during the same phase.
The net node0 anonymous residency only changed by about `0.46 GiB`.

This means migration is active, but it is mostly reshuffling pages under the
16 GiB local cap rather than leaving the 4 GiB moving hotset steadily resident
on node0.

The 30-45s bucket is especially revealing: it has remote-ish hint faults but
zero `pgpromote_candidate` and zero promotion. With the temporary latency debug
counters removed from the current kernel, the exact gate is not visible, but
the observable behavior is that these hint faults are filtered before becoming
promotion candidates, likely by the hotness/latency timing path.

## Interpretation

Friendly P1 does have an average on/off gain, but it is not a stable gain.
For most of the phase, `on` behaves like `off`. The current moving-friendly
shape is too dynamic for first-phase promotion to settle consistently:

- active hotset changes every 15s;
- promotion arrives in bursts rather than continuously;
- several hotset buckets get no promotion at all;
- promotion and demotion are nearly balanced under the 16 GiB local cap;
- local capacity pressure causes demotion while the hotset keeps moving;
- there is no prior phase history to pre-position pages.

This explains why P1 friendly looks weak compared with later multi-phase
friendly phases: later phases can benefit from accumulated placement history,
while this 2-phase run starts cold.
