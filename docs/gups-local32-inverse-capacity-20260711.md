# GUPS Local32 Inverse-Capacity Controller Result

Date: 2026-07-11
Run ID: `20260711T-gups-local32-inverse-capacity-start`

## Question

The Silo run kept migration enabled because its inverse-capacity START signal
remained above the required percentile until the workload ended. GUPS is the
opposite performance case: fixed migration is much slower than fixed OFF, so
the controller should consume the initial opportunity and converge to OFF.

## Configuration

```text
workload                  bench_gups_mt 64 (64 GiB table)
local / remote VM memory  32 / 192 GiB
guest CPUs                32, SMT disabled
normal NUMA scan          256 MiB, 1000 ms minimum
local-fault scan          64 MiB, 1000 ms, rate 5%
controller window         remote_scan_cycles, 5-20 s
stop policy               selected-gap, threshold 0.9
restart policy            inverse-capacity
start confirmation        2 consecutive windows
stop action               observe
initial migration         ON
final migration           OFF
kernel                    6.18.0modified #27
```

GUPS has no reliable log marker for the beginning of its random-update phase:
its output is buffered under redirection. The Silo main-phase log gate was
therefore disabled. The controller began making decisions once both latency
sample populations became valid. The memory sampler showed the full 64 GiB
resident population by about 32 seconds, before the first valid stop at 35.869
seconds, but the exact random-update start was not logged.

The implementation uses dynamic workload resident pages from `numa_maps`, not
the physical 32/192 GiB VM capacities. At steady state it observed about
30.76 GiB local and 33.24 GiB remote, producing:

```text
B = 0.75 * local resident / remote resident = about 69.40%
```

## Policy Trace

| Window | Elapsed s | B | Remote CDF `<` local P75 | Raw START | Count | STOP | Result |
| ---: | ---: | ---: | ---: | --- | ---: | --- | --- |
| 2 | 35.869 | 69.0818% | 100.0000% | true | 1 | true | OFF |
| 3 | 56.452 | 69.0346% | 71.2575% | true | 2 | true | RESTART |
| 4 | 77.168 | 69.3815% | 73.8601% | true | 2 | true | keep ON |
| 5 | 82.821 | 69.4701% | 67.8669% | false | 0 | true | OFF |
| 6 | 103.558 | 69.3998% | 66.5179% | false | 0 | true | keep OFF |
| 7 | 109.278 | 69.3998% | 76.7137% | true | 1 | true | keep OFF |
| 8 | 130.001 | 69.3998% | 68.4242% | false | 0 | true | keep OFF |

The first valid window had one raw START observation, so STOP won and disabled
migration. The next window confirmed START and restarted migration. At window
5 the fast-remote fraction fell below B, clearing confirmation and allowing
the unchanged STOP rule to disable migration again.

After window 5, raw START briefly returned at windows 7, 12, 16, and 19. Every
positive observation was followed by a negative observation, so none reached
the required count of two. Migration remained OFF through the end of window
21.

Controller-state durations were:

```text
initial ON                 35.869 s
first OFF interval         20.583 s
second ON interval         26.369 s
final OFF interval        268.805 s
total ON                   62.238 s
```

There were two OFF events, one restart, and no later oscillation. NUMA scanning
and fault sampling remained enabled while migration was off.

## Validation

- Workload, controller, and guest runner returned status 0.
- All 21 sample rows used distinct consecutive window sequences 2-22.
- The first row was capacity-invalid because no latency samples existed yet.
- The remaining 20 rows were capacity-valid.
- Recomputed `B`, strict-CDF cross multiplication, STOP, counts, arbitration,
  and migration state produced zero mismatches.
- No snapshot violated `CDF(<q) <= CDF(<=q)` or the CDF ppm range.
- STOP remained true in every valid window, with a capacity ratio from 2.70 to
  4.34 against the 0.9 threshold.

Most START margins were close to the KLL rank-error bound of 50,000 ppm. For
example, window 3 was only 22,229 ppm above B and window 5 was 16,032 ppm below
B. The two-consecutive-window requirement was important: it rejected isolated
positive observations after the final stop, but the exact crossing window is
still sensitive to sketch error.

The inferred strict-fast remote capacity fell by about 2 GiB from window 4 to
window 5, while that short window recorded far less actual promotion. The
crossing should therefore be interpreted as a latency-sample distribution
change, not literal depletion of 2 GiB of distinct fast pages. Later windows
provide stronger evidence for remaining OFF: margins at windows 10, 15, 18,
and 21 were respectively -7.50, -5.75, -5.06, and -5.18 percentage points.

## Performance

```text
GUPS reported time        about 349 s
process wall time          351.84 s
case elapsed               352 s
maximum RSS                67,110,020 KiB
promoted                     1.438 GiB
demoted                      1.504 GiB
final migration            OFF
```

Context from the earlier local32 64-GiB GUPS matrix:

| Mode | Kernel | GUPS time | Process wall time |
| --- | --- | ---: | ---: |
| Fixed OFF | #23 | 304.372 s | 306.59 s |
| Fixed ON | #23 | 809.632 s | 815.08 s |
| Previous controller | #23 | about 654 s | 657.92 s |
| Inverse-capacity | #27 | about 349 s | 351.84 s |

The inverse-capacity run was 14.8% slower than the older fixed-OFF wall time,
but 56.8% faster than fixed ON and 46.5% faster than the previous controller.
The remaining difference from fixed OFF includes 62.238 seconds of
migration-ON operation and the cost of leaving NUMA scanning and controller
sampling enabled during the final OFF interval. Fixed OFF disables NUMA
balancing entirely.

The GUPS program printed a malformed fractional component of the reported
duration (`18446744073709551613`), consistent with unsigned time-formatting
underflow. The process wall times are therefore the primary comparison.

These are directional comparisons rather than a controlled performance claim:
the prior matrix used kernel build 23 and the new run used build 27.

## Conclusion

The concern that GUPS would remain ON was not reproduced. Its START signal was
near the B boundary, crossed below it at window 5, and allowed STOP to disable
migration. Later positive noise was not consecutive, so the controller stayed
OFF for the remaining 268.805 seconds and finished much closer to fixed-OFF
performance than to fixed-ON performance.
