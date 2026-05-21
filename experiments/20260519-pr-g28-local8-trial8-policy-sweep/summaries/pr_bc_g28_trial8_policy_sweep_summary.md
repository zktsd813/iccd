# PR/BC g28 Trial8 Policy Sweep

Common setup: `-f /root/gapbs_graphs/kron_g28.sg`, local cap 8GiB, scan 256MiB, 1000ms, fast scan off, local fault 10% for ours, window stop threshold local>=80% or residual remote<=20% for 3 windows.

## PR

| case | avg trial s | read s | elapsed s | stop ms | stop window | reason | local % | remote ratio % | vs on | vs off |
| --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: |
| off | 18.83042 | 30.19156 | 183 |  |  |  |  |  | 3.915x | 1.000x |
| on | 73.73012 | 26.45474 | 620 |  |  |  |  |  | 1.000x | 3.915x |
| ours-w5 | 20.47566 | 26.43205 | 192 | 40022 | 8 | local_access | 100.00 | 80.70 | 3.601x | 1.087x |
| ours-w10 | 24.29297 | 26.34585 | 222 | 50011 | 5 | local_access | 100.00 | 39.19 | 3.035x | 1.290x |
| ours-w20 | 23.47862 | 26.35976 | 217 | 80008 | 4 | local_access | 100.00 | 77.64 | 3.140x | 1.247x |

## BC

| case | avg trial s | read s | elapsed s | stop ms | stop window | reason | local % | remote ratio % | vs on | vs off |
| --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: |
| off | 23.08023 | 28.73214 | 215 |  |  |  |  |  | 2.178x | 1.000x |
| on | 50.27976 | 26.44289 | 434 |  |  |  |  |  | 1.000x | 2.178x |
| ours-w5 | 24.71080 | 26.54806 | 228 | 65026 | 13 | local_access | 99.85 | 89.94 | 2.035x | 1.071x |
| ours-w10 | 39.20943 | 26.54050 | 344 | 90013 | 9 | local_access | 85.31 | 66.68 | 1.282x | 1.699x |
| ours-w20 | 46.06731 | 26.46846 | 399 | 140012 | 7 | local_access | 99.10 | 82.56 | 1.091x | 1.996x |

Artifacts are under `qemu-logs/20260519T075641Z-prg28-trial8-policy-sweep/guest-artifacts/`.
