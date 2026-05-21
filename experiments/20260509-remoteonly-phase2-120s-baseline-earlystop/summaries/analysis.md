# Remote-only 2-phase 120s run

Candidate: `phase_move15s4g_remote_split32_stream4k_localft`

Shape:

- Phase 1: friendly, `move15s-hotset-4g-remote`, 120s
- Phase 2: unfriendly, `stream-read-32g-split16-4k`, 120s
- `PHASE_REPEAT=1`, `PHASE_MS=120000`
- Policies: `off`, `on`, `oracle_cgroup_global0`
- `NUMA_SCAN_SIZE_MB=4096`, `SCAN_PERIOD_SCALE=100`, `HOT_THRESHOLD_MS=0`
- MGLRU runtime: `0x0007`
- Kernel: `6.18.0modified #157`

Runs:

- Baseline: `20260509T0518Z-remoteonly-phase2-120s-baseline`
- Earlystop/pingpong diagnostic: `20260509T0532Z-remoteonly-phase2-120s-earlystop-pingpong`

Both runs completed with `ret=0` for all policies.

## Baseline

Earlystop and pingpong stat disabled.

| policy | friendly P1 Mops/s | unfriendly P2 MB/s | P1 vs off | P2 vs off | promoted GiB | demoted GiB | hint faults |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| off | 228.58 | 4513.00 | 1.000x | 1.000x | 0.00 | 0.00 | 0 |
| on | 272.19 | 2197.60 | 1.191x | 0.487x | 15.43 | 14.33 | 23839372 |
| adaptive | 269.67 | 4199.70 | 1.180x | 0.931x | 6.97 | 6.66 | 13880560 |

Per-phase counters:

| policy | phase | kind | hint faults | promotions | direct demote GiB | reclaimd runs |
| --- | ---: | --- | ---: | ---: | ---: | ---: |
| off | 1 | friendly | 0 | 0 | 0.00 | 0 |
| off | 2 | unfriendly | 0 | 0 | 0.00 | 0 |
| on | 1 | friendly | 10623217 | 1846272 | 6.58 | 4 |
| on | 2 | unfriendly | 9486696 | 2199556 | 7.73 | 2 |
| adaptive | 1 | friendly | 10475772 | 1826651 | 6.66 | 4 |
| adaptive | 2 | unfriendly | 2295452 | 0 | 0.00 | 0 |

## Earlystop + Pingpong Diagnostic

`NUMA_MIGRATION_STOP_ENABLED=1`, `NUMA_PINGPONG_STAT_ENABLED=1`.

| policy | friendly P1 Mops/s | unfriendly P2 MB/s | P1 vs off | P2 vs off | promoted GiB | demoted GiB | hint faults | earlystop cnt |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| off | 228.54 | 4506.70 | 1.000x | 1.000x | 0.00 | 0.00 | 0 | 0 |
| on | 258.93 | 2320.15 | 1.133x | 0.515x | 11.65 | 10.71 | 20244192 | 5 |
| adaptive | 258.24 | 4235.06 | 1.130x | 0.940x | 3.54 | 3.31 | 10432908 | 0 |

Per-phase counters:

| policy | phase | kind | hint faults | promotions | direct demote GiB | reclaimd runs | stop start | stop end |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| off | 1 | friendly | 0 | 0 | 0.00 | 0 | 0 | 0 |
| off | 2 | unfriendly | 0 | 0 | 0.00 | 0 | 0 | 0 |
| on | 1 | friendly | 8291797 | 936098 | 3.32 | 2 | 1 | 1 |
| on | 2 | unfriendly | 11637432 | 2116977 | 7.31 | 2 | 1 | 1 |
| adaptive | 1 | friendly | 8291114 | 928121 | 3.31 | 2 | 1 | 1 |
| adaptive | 2 | unfriendly | 1693520 | 0 | 0.00 | 0 | 1 | 0 |

## Readout

- The 2-phase baseline isolates the immediate friendly-to-unfriendly transition.
- Full `on` improves friendly modestly but hurts the following unfriendly phase
  badly: `0.487x` of off.
- Baseline adaptive keeps the friendly gain and recovers the unfriendly phase to
  `0.931x` of off, with less migration than full `on`.
- Enabling earlystop/pingpong reduces full-on migration volume
  (`15.43 -> 11.65 GiB` promoted) and slightly improves full-on unfriendly
  throughput (`2197.60 -> 2320.15 MB/s`), but it also reduces friendly gain.
- Diagnostic adaptive still behaves close to baseline adaptive in the
  unfriendly phase (`4235.06` vs `4199.70 MB/s`) because phase 2 already has
  cgroup node balancing disabled by the adaptive controller.
