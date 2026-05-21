# PR/BC g28 Local16 W5 Trial8

Common setup: `-f /root/gapbs_graphs/kron_g28.sg`, local cap 16GiB, scan 256MiB, 1000ms, fast scan off, local fault 10% for ours, 5s controller window, trial count 8.

## PR

| case | avg trial s | read s | elapsed s | stop ms | stop window | reason | local % | remote ratio % | vs on | vs off |
| --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: |
| off | 19.03500 | 27.26490 | 182 |  |  |  |  |  | 1.765x | 1.000x |
| on | 33.59678 | 23.89406 | 296 |  |  |  |  |  | 1.000x | 1.765x |
| ours-w5 | 19.99597 | 23.92865 | 186 | 35016 | 7 | local_access | 100.00 | 74.38 | 1.680x | 1.050x |

## BC

| case | avg trial s | read s | elapsed s | stop ms | stop window | reason | local % | remote ratio % | vs on | vs off |
| --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: |
| off | 19.83175 | 23.65247 | 184 |  |  |  |  |  | 1.912x | 1.000x |
| on | 37.90892 | 23.75081 | 333 |  |  |  |  |  | 1.000x | 1.912x |
| ours-w5 | 15.15155 | 24.23526 | 149 | 45017 | 9 | local_access | 84.44 | 0.00 | 2.502x | 0.764x |

## Local8 vs Local16 W5

| cap | workload | case | avg trial s | stop ms | reason |
| --- | --- | --- | ---: | ---: | --- |
| 8G | bc | off | 23.08023 |  |  |
| 16G | bc | off | 19.83175 |  |  |
| 8G | bc | on | 50.27976 |  |  |
| 16G | bc | on | 37.90892 |  |  |
| 8G | bc | ours-w5 | 24.71080 | 65026 | local_access |
| 16G | bc | ours-w5 | 15.15155 | 45017 | local_access |
| 8G | pr | off | 18.83042 |  |  |
| 16G | pr | off | 19.03500 |  |  |
| 8G | pr | on | 73.73012 |  |  |
| 16G | pr | on | 33.59678 |  |  |
| 8G | pr | ours-w5 | 20.47566 | 40022 | local_access |
| 16G | pr | ours-w5 | 19.99597 | 35016 | local_access |
