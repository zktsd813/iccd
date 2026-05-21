# Friendly move-60s remote-only on/off comparison

Compared runs:

- `off`: `20260509T0729Z-friendly-move60s-remoteonly-off`
- `on`: `20260509T0723Z-friendly-move60s-remoteonly-on`

Candidate:
`skew_lf_hotremote_4g_move_60s_remoteonly_mulshift_persistent`

Shape:

- 4 GiB moving friendly hotset
- remote-only offset range `16G..60G`
- random move, `move-step=4G`
- move interval `60s`
- duration `120s`
- read-only mulshift hotset

## Overall

| policy | mean Mops/s | median Mops/s | promoted GiB | demoted GiB | hint faults |
| --- | ---: | ---: | ---: | ---: | ---: |
| off | 228.22 | 228.26 | 0.00 | 1.33 | 0 |
| on | 1289.93 | 1799.36 | 8.01 | 6.69 | 4696404 |

Overall mean on/off: `5.65x`.

## 60s Windows

| window | offset | off mean | on mean | on/off mean | off median | on median | on/off median |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0-60s | 16G | 228.36 | 1451.68 | 6.357x | 228.33 | 1800.40 | 7.885x |
| 60-120s | 20G | 228.09 | 1108.70 | 4.861x | 228.07 | 409.67 | 1.796x |

## 15s Detail

| bucket | offset | off mean | on mean | on/off |
| --- | ---: | ---: | ---: | ---: |
| 0-15s | 16G | 228.38 | 514.82 | 2.254x |
| 15-30s | 16G | 228.34 | 1632.59 | 7.150x |
| 30-45s | 16G | 228.36 | 1822.01 | 7.979x |
| 45-60s | 16G | 228.37 | 1800.02 | 7.882x |
| 60-75s | 20G | 228.16 | 316.91 | 1.389x |
| 75-90s | 20G | 228.20 | 407.70 | 1.787x |
| 90-105s | 20G | 227.97 | 1831.15 | 8.032x |
| 105-120s | 20G | 228.02 | 1879.04 | 8.241x |

## Counter Readout

| policy | window | hints | promotions | direct demotions | active anon node0 |
| --- | --- | ---: | ---: | ---: | --- |
| off | 0-60s | 0 | 0 | 313980 | 0.00 -> 0.00 GiB |
| off | 60-120s | 0 | 0 | 0 | 0.00 -> 0.00 GiB |
| on | 0-60s | 1685875 | 1050384 | 873104 | 0.00 -> 3.63 GiB |
| on | 60-120s | 2803654 | 891479 | 881326 | 3.63 -> 2.84 GiB |

## Interpretation

The `off` run is flat at about `228 Mops/s`, which is the remote-access
baseline.

With migration `on`, the hotset stays in one position long enough for scanning
and promotion to catch up. After the cold part of each 60s window, throughput
settles around `1.8-1.9G Mops/s`.

This confirms the earlier diagnosis: the 15s moving-friendly case looked weak
because the hotset moved too quickly for promotion to stabilize. At 60s, the
same friendly shape becomes strongly migration-friendly.
