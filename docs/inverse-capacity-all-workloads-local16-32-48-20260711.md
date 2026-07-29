# Inverse-Capacity Controller Full Workload Sweep

- Date: 2026-07-11
- Kernel: `6.18.0modified #27`
- Controller: `selected-gap` STOP plus `inverse-capacity` START

## Scope

This sweep evaluates the canonical six-workload VM baseline at 16, 32, and
48 GiB of local memory. Remote memory is 192 GiB in every case.

The workload matrix is:

```text
PR, BC, GUPS, BTree, Graph500, Silo
local memory = 16, 32, 48 GiB
total cases = 18
```

Here, "all workloads" means the six workloads frozen in
`baseline/EXPERIMENT_BASELINE.md`. The runner's convenience token
`WORKLOADS=all` also expands to non-baseline Liblinear, so this sweep used an
explicit workload list and intentionally excluded Liblinear.

The results are split across two run roots because Silo alone requires a
main-phase log gate:

- Non-Silo: `20260711T-inverse-capacity-baseline-nosilo-local16-32-48`
- Silo: `20260711T-inverse-capacity-silo-local16-32-48`

All 18 cases, both guest matrices, and both host runners returned status 0.
No QEMU process or result overlay remained after cleanup.

## Configuration

```text
VM CPUs                         32, SMT disabled
fast memory                     16 / 32 / 48 GiB on host node 0
slow memory                     192 GiB on host node 2
normal NUMA scan                256 MiB, 1000 ms minimum
local-fault scan                64 MiB, 1000 ms, rate 5%
controller window               remote_scan_cycles, clamped to 5-20 s
controller input                same-snapshot weighted quantiles and CDFs
local threshold                 P75
STOP policy                     selected-gap, capacity ratio > 0.9
START policy                    inverse-capacity, 2 consecutive windows
initial migration               ON
stop action                     observe
GAPBS                           generated graph, scale 29, build included
GUPS                            64 GiB table
Graph500                        scale 28, one timed BFS plus validation
Silo                            jemalloc, 32 threads, scale 800000,
                                100000000 ops/worker, reverse Zipf
```

PR and BC used generated `-g 29` commands. No case used a prebuilt graph.
Silo was run separately with `MAIN_PHASE_LOG_GATE=1`; the other five
workloads used the gate disabled.

## Policy Evaluated

Let `L` and `R` be current local and remote resident workload pages. The
amount of local capacity represented by local P0-P75 is:

```text
H = 0.75 * L
B = ceil(1,000,000 * H / R) ppm
```

Let `F_lt` be the strict remote CDF below the same-snapshot local P75
latency. The raw START condition is:

```text
F_lt * R >= 0.75 * L
```

START is confirmed after two consecutive raw-positive windows. The existing
STOP rule is unchanged: the inclusive remote candidate capacity is divided
by the local P75-P100 tail capacity (`0.25 * L`), and STOP is requested when
that ratio is greater than 0.9.

The evaluated arbitration is:

```text
confirmed START > STOP > HOLD
```

Therefore a confirmed START keeps or turns migration ON even when STOP is
simultaneously requested.

## Workload Results

The wall column is the inner workload/controller process wall time. PR and
BC metrics are averages over eight trials. Silo transaction time excludes
loading and reverse-Zipf preparation.

| Workload metric | Local 16 | Local 32 | Local 48 |
| --- | ---: | ---: | ---: |
| PR average trial / wall | 48.758 / 887.09 s | 46.363 / 821.19 s | 47.005 / 791.86 s |
| BC average trial / wall | 34.131 / 774.87 s | 33.089 / 723.30 s | 27.445 / 604.44 s |
| GUPS reported / wall | about 559 / 564.24 s | about 712 / 716.05 s | 310.005 / 312.31 s |
| BTree lookup / wall | 540 / 728.26 s | 408 / 554.82 s | 348 / 508.35 s |
| Graph500 end-to-end wall | 401.46 s | 359.74 s | 342.63 s |
| Silo transaction / inner wall | 220.249 / 713.08 s | 205.222 / 681.21 s | 200.285 / 702.05 s |
| Silo aggregate throughput | 14.4491 Mops/s | 15.4308 Mops/s | 15.9047 Mops/s |

The malformed long fractional suffix printed by GUPS at local16 and local32
is an existing unsigned time-formatting defect. Process wall time is the
primary GUPS comparison.

Silo transaction throughput improved by 6.79% from local16 to local32 and by
3.07% from local32 to local48. Local48 was 10.07% above local16. Total Silo
wall time is not monotonic because loading, reverse-Zipf preparation, and the
controller drain are outside the timed transaction region.

## Controller Outcomes

`Stops / starts` counts actual migration transitions. ON percentage covers
the whole controller lifetime. For Silo, that includes the gate-closed load
and preparation phase, during which migration intentionally remains ON.
Final state is the controller CSV state at controller exit. The outer wrapper
restores the migration sysfs knob before the next case, so the later
after-snapshot is not the policy outcome.

| Local GiB | Workload | Stops / starts | Migration ON | Final state |
| ---: | --- | ---: | ---: | --- |
| 16 | PR | 6 / 6 | 80.0% | ON |
| 16 | BC | 4 / 4 | 69.2% | ON |
| 16 | GUPS | 1 / 1 | 96.0% | ON |
| 16 | BTree | 2 / 2 | 91.7% | ON |
| 16 | Graph500 | 3 / 2 | 78.1% | OFF |
| 16 | Silo | 1 / 1 | 96.8% | ON |
| 32 | PR | 9 / 8 | 61.6% | OFF |
| 32 | BC | 6 / 6 | 59.5% | ON |
| 32 | GUPS | 1 / 1 | 97.1% | ON |
| 32 | BTree | 2 / 1 | 28.0% | OFF |
| 32 | Graph500 | 2 / 1 | 61.6% | OFF |
| 32 | Silo | 2 / 1 | 91.1% | OFF |
| 48 | PR | 3 / 2 | 32.4% | OFF |
| 48 | BC | 3 / 2 | 39.6% | OFF |
| 48 | GUPS | 1 / 0 | 9.9% | OFF |
| 48 | BTree | 1 / 0 | 32.4% | OFF |
| 48 | Graph500 | 2 / 1 | 59.2% | OFF |
| 48 | Silo | 2 / 2 | 90.6% | ON |

The broad capacity trend is visible. At local48, GUPS and BTree have less
remote resident capacity than `0.75 * L`, so `B > 100%` and START is
structurally impossible. Both stop once and remain OFF. At local16, remote
capacity is large relative to the local head, so most workloads frequently
satisfy START and spend more time ON.

## Silo Main-Phase Gate

The gate excludes loading and reverse-Zipf preparation. It opens on the first
`time: 5 throughput:` line, not on `starting benchmark...`.

| Local GiB | Gate window / elapsed | Gate-open valid windows | Main-phase transitions | Final |
| ---: | ---: | ---: | --- | --- |
| 16 | W32 / 486.970 s | 12 / 12 | OFF -> START | ON |
| 32 | W34 / 494.262 s | 10 / 10; 9 before workload exit | OFF -> START -> OFF | OFF |
| 48 | W30 / 486.298 s | 12 / 12; last during cleanup | OFF -> START -> OFF -> START | ON |

The gate solved the original missing-main-phase-information problem: every
policy window used for the transaction phase had valid local and remote
samples. No loading-phase sample caused a migration transition. The gate
remains open through process and controller cleanup, so post-transaction rows
are retained in the audit but are identified separately from transaction
behavior.

At local32, the final active STOP was extremely close to the START boundary:
strict fast capacity was about 83 MiB below the required capacity, a CDF
margin of only -0.0949 percentage points. This is within the logged KLL rank
error of 5 percentage points. The strict comparison was executed correctly,
but the exact late transition is not statistically robust.

## Local32 GUPS Path Dependence

The full sweep exposed a reproducibility problem that the earlier standalone
local32 GUPS run did not show.

| Measurement | Fresh standalone | Sequential full sweep |
| --- | ---: | ---: |
| Process wall | 351.84 s | 716.05 s |
| Migration ON | 62.238 s | 695.176 s |
| Migration OFF | 289.388 s | 20.867 s |
| Final state | OFF | ON |
| Promoted / demoted | 1.438 / 1.504 GiB | 5.172 / 10.096 GiB |
| Steady local / remote placement | 30.762 / 33.268 GiB | 30.807 / 33.223 GiB |

The command, policy settings, kernel, RSS, and steady placement are
effectively identical. The difference is the early latency-CDF trajectory.
The sweep confirmed restart with a margin of only +0.4312 percentage points,
well inside the 5 percentage-point KLL rank-error bound. Migration then
remained ON. The ON state kept local P75 around 272-344 ms, which made more
remote samples appear faster than local P75 and continually reinforced START.

The standalone run crossed below the boundary at its next window, turned
OFF, and then observed local P75 around 176-208 ms. That lower threshold kept
the remote fast fraction below `B` and prevented another confirmed START.

PR and BC preceded GUPS in the sequential sweep, while the standalone case
used a fresh VM. The controller advanced to a new empty latency window before
GUPS, so PR/BC samples were not directly mixed into the GUPS CDF. Kernel
window sequence, scan-cycle phase, and broader same-VM history still persist,
however. The data establish order/sampling-path dependence; they do not prove
that PR or BC alone caused the branch change.

This is path-dependent positive feedback, not a capacity-placement difference
or a workload hang. The sequential result is 2.04x the standalone runtime and
is close to the migration-ON branch.

Local48 GUPS does not have this ambiguity. Its `B` is about 196%, so it stops
at 30.902 seconds and remains OFF. Its 312.31-second controller wall time is
within 0.6% of the preceding standalone run.

## Context Against Fixed OFF and ON

The following comparison uses elapsed time only. Fixed local16 comes from the
frozen 2026-07-09 fixed-only supplement; fixed local32/local48 comes from the
frozen 2026-07-10 baseline. Positive percentages are slower. Both fixed runs
used kernel build 23 while this sweep used build 27, so these values are
directional and must not be treated as a controlled kernel-matched performance
claim.

| Local | Workload | New elapsed | Versus fixed OFF | Versus fixed ON |
| ---: | --- | ---: | ---: | ---: |
| 16 | PR | 888 s | +11.4% | +0.8% |
| 16 | BC | 776 s | -29.6% | -35.0% |
| 16 | GUPS | 565 s | +6.4% | +1.1% |
| 16 | BTree | 729 s | -13.6% | +10.0% |
| 16 | Graph500 | 403 s | +6.1% | -1.5% |
| 16 | Silo | 714 s | -19.4% | +0.0% |
| 32 | PR | 822 s | +2.4% | +1.6% |
| 32 | BC | 725 s | -32.5% | -17.0% |
| 32 | GUPS | 717 s | +133.6% | -12.0% |
| 32 | BTree | 556 s | +1.6% | -14.5% |
| 32 | Graph500 | 360 s | -4.8% | -6.0% |
| 32 | Silo | 701 s | -18.1% | +5.9% |
| 48 | PR | 793 s | -0.4% | +8.3% |
| 48 | BC | 606 s | -42.1% | -9.6% |
| 48 | GUPS | 313 s | +8.7% | -64.1% |
| 48 | BTree | 509 s | +4.7% | -21.8% |
| 48 | Graph500 | 344 s | +0.6% | +2.4% |
| 48 | Silo | 703 s | -12.8% | +3.7% |

The local32 GUPS row reflects the unstable ON branch described above. The
fresh standalone inverse-capacity result was 351.84 seconds, not 717 seconds.

## Graph500 Validity

All three Graph500 cases are valid legacy vMitosis end-to-end runs at scale
28. They perform graph generation, CSR construction, an untimed warm-up BFS,
one timed BFS, and validation.

Two legacy output defects make stdout look incomplete:

1. `Graph500 with scale 0` is printed before the parsed scale is assigned.
   The scale-28 allocation sizes confirm the actual scale.
2. A committed `exit(0)` after validation makes the normal TEPS and wrapper
   footer unreachable.

The final 4096 MiB verification allocation is reached only after the timed
BFS returns, and all validation paths returned status 0. Therefore the
reported end-to-end wall times are comparable with the frozen baseline. They
are not official self-reported TEPS measurements. Producing TEPS would require
a source fix, clean rebuild, forced guest restaging, and rerunning both the new
cases and their fixed OFF/ON references.

## Audit

The strict audit found:

```text
status                 PASS
expected / found       18 / 18
complete cases         18
transition evidence    131 rows
errors                 0
incomplete issues      0
warnings               0
```

It independently recomputed the `B` ceiling, strict START cross product,
two-window confirmation, inclusive STOP ratio, START-over-STOP arbitration,
and controller state replay. It also verified return codes, unique window
sequences, the Silo gate split, same-snapshot CDF ordering and range, final
migration knobs, exact policy configuration, and the complete canonical
matrix.

The only repeated runtime error was optional plot generation failing because
the guest Python environment lacks `matplotlib`. Plot failure occurs after
the workload and controller artifacts are complete and does not affect case
status or policy data.

Artifacts:

- [Case summary CSV](../motivation/3_realworld/VM/results/20260711T-inverse-capacity-all-workloads-local16-32-48-audit/inverse_capacity_case_summary.csv)
- [Transition evidence CSV](../motivation/3_realworld/VM/results/20260711T-inverse-capacity-all-workloads-local16-32-48-audit/inverse_capacity_transition_evidence.csv)
- [Strict audit report](../motivation/3_realworld/VM/results/20260711T-inverse-capacity-all-workloads-local16-32-48-audit/inverse_capacity_audit.txt)
- [Audit implementation](../motivation/3_realworld/VM/scripts/audit_inverse_capacity_sweep.py)
- [Frozen baseline](../baseline/EXPERIMENT_BASELINE.md)

## Policy Assessment

The capacity inversion is useful and behaves correctly when the capacity
margin is decisive. It correctly keeps local48 GUPS and BTree OFF, and it
restarts Silo when enough remote lower-tail capacity is faster than local P75.

The current arbitration is not robust near the CDF boundary. In particular,
the two-window START streak can include one observation taken while migration
is ON before STOP and one observation taken after STOP. That permits a restart
after only one full OFF-state observation. Once restarted, local P75 can move
in a direction that reinforces START.

Many individual START margins across the matrix are inside the logged KLL
rank-error bound. Their arithmetic decisions are valid, but a single crossing
inside that uncertainty range should not be interpreted as a stable physical
capacity change.

The next policy revision should preserve the existing STOP rule and address
START confidence:

1. Reset the START streak on every transition to OFF and require two complete
   OFF-state windows before restart.
2. Require the START capacity margin to exceed the snapshot KLL rank-error
   bound, or introduce an equivalent explicit hysteresis margin.
3. Consider a minimum OFF dwell time so one short remote-cycle window cannot
   immediately reverse a valid STOP.
4. Keep the Silo main-phase gate exactly as evaluated here.

The first two changes directly target the local32 GUPS failure while retaining
the inverse-capacity meaning of START. They should be evaluated in fresh-VM
and sequential-order repeats, including repeated order permutations, before
replacing this controller as the default.

## Conclusion

The 18-case sweep completed successfully and the implementation matches the
specified policy. The policy is effective in clear capacity regimes and the
Silo main-phase sampling problem is resolved. It is not yet stable enough to
adopt unchanged: local32 GUPS demonstrates that a near-boundary START can
select and reinforce the slow migration-ON branch. The next controller change
should strengthen restart confirmation rather than alter the existing STOP
criterion.
