# GUPS Local48 Inverse-Capacity Controller Result

Date: 2026-07-11
Run ID: `20260711T-gups-local48-inverse-capacity-start`

## Objective

Repeat the 64 GiB GUPS inverse-capacity experiment with 48 GiB of local VM
memory. All workload, scan, controller, CPU, and remote-memory settings were
kept the same as the local32 run.

## Configuration

```text
workload                  bench_gups_mt 64 (64 GiB table)
local / remote VM memory  48 / 192 GiB
guest CPUs                32, SMT disabled
normal NUMA scan          256 MiB, 1000 ms minimum
local-fault scan          64 MiB, 1000 ms, rate 5%
controller window         remote_scan_cycles, 5-20 s
stop policy               selected-gap, threshold 0.9
restart policy            inverse-capacity
start confirmation        2 consecutive windows
stop action               observe
initial migration         ON
kernel                    6.18.0modified #27
```

As in the local32 run, the GUPS main-phase log gate was disabled because the
program does not provide a reliably flushed random-update marker. The memory
sampler showed the full 64 GiB resident population by about 27 seconds, before
the first valid stop at 32.835 seconds.

## START Capacity

The controller uses workload resident pages, not the physical 48/192 GiB VM
capacities. At the first valid window it observed:

```text
local resident L          46.266 GiB
remote resident R         17.737 GiB
required head 0.75L       34.700 GiB
B = 0.75L/R              195.630%
```

The required 34.700 GiB is larger than all 17.737 GiB of remote resident
memory. The controller therefore reports:

```text
reason          remote_capacity_below_local_head
START_RAW       false
START count     0
```

This result is independent of remote latency: no remote percentile above P100
exists. After placement stabilized, B remained 195.650% in every window.

## Policy Trace

| Window | Elapsed s | B | START | STOP ratio | Arbitration | State |
| ---: | ---: | ---: | --- | ---: | --- | --- |
| 1 | 20.253 | unavailable | invalid | unavailable | HOLD | ON |
| 2 | 32.835 | 195.630% | false | 1.534 | STOP | OFF |
| 3 | 53.338 | 195.650% | false | 1.145 | STOP | OFF |
| 8 | 97.859 | 195.650% | false | 0.852 | HOLD | OFF |
| 13 | 157.413 | 195.650% | false | 0.885 | HOLD | OFF |
| 23 | 300.310 | 195.650% | false | 1.044 | STOP | OFF |

The first valid STOP disabled migration at 32.835 seconds. START was false in
all 22 valid windows, so there were no restart candidates or restart events.
STOP was true in 20 windows. At windows 8 and 13 STOP briefly fell below its
0.9 threshold, but HOLD correctly preserved the existing OFF state.

```text
initial ON interval        32.835 s
final OFF interval        277.480 s
OFF events                  1
restart events              0
final migration             OFF
```

## Validation

- Workload, controller, guest runner, and host runner returned status 0.
- All 23 policy windows had distinct consecutive sequence numbers 2-24.
- Window 1 was invalid because latency samples were not yet available.
- Windows 2-23 were capacity-valid.
- Recomputed B, START handling, STOP ratios, arbitration, and state transitions
  produced zero mismatches.
- No raw snapshot violated strict/inclusive CDF ordering or ppm bounds.
- START count and confirmed state remained zero for the entire run.

The first STOP ratio of 1.534 had substantial margin above 0.9. Later STOP
values close to the threshold are subject to KLL/window variation, but they
cannot cause a restart because START is structurally impossible at B>100%.

## Performance

```text
GUPS reported time         308.130 s
process wall time          310.43 s
case elapsed               312 s
maximum RSS                67,110,020 KiB
promoted                     0.244 GiB
demoted                      0.376 GiB
final migration            OFF
```

Recorded movement was effectively complete by about 40.6 seconds. Observation
continued after that point, accumulating 51.33 million hint faults and 41.89
million migration-disabled rejected attempts while movement remained off.

Context from earlier local48 runs:

| Mode | Kernel | Process wall time | Promote / Demote |
| --- | --- | ---: | ---: |
| Fixed OFF | #23 | 287.37 s | 0 / 0 GiB |
| Fixed ON | #23 | 872.04 s | 1.801 / 1.802 GiB |
| Previous restarting controller | #23 | 881.46 s | 2.659 / 2.702 GiB |
| Inverse-capacity | #27 | 310.43 s | 0.244 / 0.376 GiB |

The inverse-capacity result was 8.0% slower than the older fixed-OFF wall time,
but 64.4% faster than fixed ON and 64.8% faster than the previous restarting
controller. The remaining difference from fixed OFF includes the initial
32.835-second migration interval and observation-mode scanning overhead.

The older baselines used kernel build 23 and the new run used build 27, so the
performance comparison is directional rather than a controlled attribution.

## Conclusion

Local48 produces a deterministic capacity outcome: the required local-head
equivalent is almost twice the entire remote resident population. START cannot
become true, the first valid STOP disables migration, and the controller stays
OFF for the remaining 277.480 seconds. This avoids the repeated restart
behavior that made the previous local48 GUPS controller slower than fixed ON.
