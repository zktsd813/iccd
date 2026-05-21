# GAPBS toggle ours window sweep

- Workload graph: `/root/gapbs_graphs/kron_g28.sg` loaded with `-f`.
- Workloads: PR `/root/pr -f ... -i20 -t1e-4 -n 8`, BC `/root/bc -f ... -i1 -n 8`.
- Kernel: `Linux kernel 6.18.0modified #179 SMP PREEMPT_DYNAMIC Wed May 20 03:30:57 UTC 2026`.
- VM: 96G, 32 vCPUs, node0 32G on host node0, node1 64G on host node2, KVM bind/prealloc.
- Knobs: MGLRU `0x0007`, scan size 256MB, scan period min 1000ms, fast scan off, hot threshold 0.
- Toggle policy: start with migration on, stop after local-util condition, re-enable after the stop condition is not satisfied for 2 consecutive windows.

## PR

| cap | window | avg trial s | off s | on s | off/on count | final state | hint faults | promoted | demoted |
| --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: |
| 16g | 5 | 42.13903 | 35.017 | 50.022 | 1/1 | on | 40,421,785 | 8,951,092 | 18,085,209 |
| 16g | 10 | 30.10791 | 50.009 | 80.012 | 1/1 | on | 29,764,062 | 7,753,854 | 17,332,002 |
| 16g | 20 | 29.17429 | 80.009 | 140.013 | 1/1 | on | 24,670,179 | 7,584,769 | 16,761,914 |
| 8g | 5 | 50.36476 | 45.027 | 60.032 | 1/1 | on | 56,726,664 | 10,253,926 | 21,327,955 |
| 8g | 10 | 34.85731 | 50.013 | 80.016 | 1/1 | on | 37,609,563 | 17,496,649 | 27,988,639 |
| 8g | 20 | 33.86487 | 80.010 | 140.013 | 1/1 | on | 33,753,056 | 10,879,215 | 21,182,944 |

## BC

| cap | window | avg trial s | off s | on s | off/on count | final state | hint faults | promoted | demoted |
| --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: |
| 16g | 5 | 35.36535 | 65.022 | 85.026 | 1/1 | on | 33,995,312 | 5,995,238 | 16,408,810 |
| 16g | 10 | 18.59924 | 80.013 | 110.017 | 1/1 | on | 20,542,547 | 4,260,561 | 14,417,698 |
| 16g | 20 | 19.65504 | 80.006 | 140.009 | 1/1 | on | 18,597,994 | 4,036,259 | 14,268,199 |
| 8g | 5 | 50.62334 | 65.026 | 80.032 | 1/1 | on | 57,378,503 | 8,402,130 | 21,258,929 |
| 8g | 10 | 50.74007 | 90.015 | 130.018 | 1/1 | on | 53,294,851 | 7,492,917 | 21,515,194 |
| 8g | 20 | 49.08597 | 140.010 | 200.014 | 1/1 | on | 50,408,335 | 6,525,993 | 18,736,252 |

## Observation

- Every case toggled exactly once: one `off` followed by one `on`, and the final controller state was `on`.
- After re-enable, these runs generally did not accumulate enough local PTE-update/refault evidence to stop again, so the latter part of each run behaves closer to migration-on than one-shot `ours`.
- The strongest regressions are PR 8G/5s and BC 8G all windows, where re-enabling keeps migration cost high for most later trials.
