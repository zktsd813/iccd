# Silo Local16 Inverse-Capacity Migration Policy

Date: 2026-07-11
Run ID: `20260711T-silo-local16-inverse-capacity-start`

## Objective

Keep the existing migration-stop decision, but add a symmetric capacity-based
start decision so that a false stop can recover on the next valid windows.
The policy must use samples from Silo's transaction phase, not the sparse
initialization phase.

## Policy

For one valid fault-latency window, define:

- `L`: local resident pages in the workload process tree.
- `R`: remote resident pages in the same process tree.
- `q`: local P75 fault latency.
- `F_R(<q)`: fraction of remote samples strictly faster than `q`.
- `F_R(<=q)`: fraction of remote samples no slower than `q`.

The existing stop condition is unchanged:

```text
local_tail_pages       = 0.25 * L
remote_candidate_pages = F_R(<=q) * R
STOP_RAW = remote_candidate_pages / local_tail_pages > 0.9
```

The new start condition works in the opposite direction:

```text
local_head_pages = 0.75 * L
B                = local_head_pages / R
START_RAW        = remote P_B < local P75
                 = F_R(<q) * R >= 0.75 * L
```

The controller evaluates the final expression with integer cross
multiplication. It records `B` in ppm as:

```text
B_ppm = ceil(750000 * L / R)
```

`START_RAW` must be true for two consecutive valid, gate-open windows before
it becomes `START_CONFIRMED`. A false or invalid observation clears the count.
Closing the main-phase gate also clears it. Migration OFF/ON transitions do
not clear it, which allows a first-window stop to recover on the second
window.

The arbitration order is:

```text
START_CONFIRMED > STOP_RAW > HOLD
```

Therefore the first raw start candidate does not override stop, but a
confirmed start does. If the start condition later fails while stop remains
true, stop wins again.

## Implementation

### Kernel

`fault_latency_quantiles` now emits `quantile_snapshot_v2`. The kernel derives
the following fields from one copied weighted-KLL snapshot and the same local
P75 value:

```text
local_cdf_lt_local_q75_ppm
local_cdf_le_local_q75_ppm
remote_cdf_lt_local_q75_ppm
remote_cdf_le_local_q75_ppm
```

The strict fields stop before samples equal to local P75. The inclusive fields
include ties. This avoids the previous userspace query/read race and preserves
the inclusive CDF used by the existing stop condition.

### Controller

The new restart policy is selected with:

```text
--restart-policy inverse-capacity
```

It requires quantile input, local P75, resident-page capacity, continuous
monitoring, `stop_action=observe`, and fault sampling to remain enabled while
migration is off. The CSV records the raw and confirmed start decisions,
resident capacities, derived remote percentile, strict CDF, stop request,
arbitration result, prior controller state, and transition action.

## Verification

- Controller unit tests: 45 passed.
- Kernel build: `bzImage` build number 27 completed successfully.
- Guest kernel: `6.18.0modified #27`.
- All 42 sampled controller windows had distinct, increasing window sequences.
- All emitted CDF values were in `[0, 1000000]`.
- No window violated `CDF(<q) <= CDF(<=q)`.
- Recomputing `B_ppm` and `START_RAW` from every main-phase CSV row produced
  zero mismatches.

## Experiment Configuration

```text
local memory             16 GiB
remote memory            192 GiB
guest CPUs / Silo threads 32 / 32
SMT                      disabled
Silo allocator           jemalloc
Silo scale factor        800000
Silo operations/worker   100000000
Silo Zipf                theta 0.5, reverse enabled
normal NUMA scan         256 MiB, 1000 ms minimum
local-fault scan         64 MiB, 1000 ms, rate 5%
controller window        remote_scan_cycles, 5-20 s
main-phase log gate      enabled
initial migration        enabled
stop action              observe
start confirmation       2 windows
```

## Observed Transition

The main-phase gate opened at controller window 32, 492.026 seconds after the
controller started.

| Window | Elapsed s | B | Remote CDF `<` P75 | Start count | Stop | Arbitration | Action |
| ---: | ---: | ---: | ---: | ---: | --- | --- | --- |
| 32 | 492.026 | 11.0806% | 14.1931% | 1 | true | STOP | migration off |
| 33 | 498.596 | 11.1568% | 53.1211% | 2 | true | START | migration on |
| 34 | 521.032 | 11.2466% | 57.2239% | 2 | true | START | keep on |

Migration was disabled for 6.570 seconds. Windows 32-42 all had both raw start
and stop true. Window 32 stopped because start was not yet confirmed; windows
33-42 used START priority. There was one OFF event and one restart event, and
the final migration state was ON. During the OFF interval, the kernel recorded
3,567,900 migration-disabled rejected pages (13.610 GiB), confirming that the
migration-off knob took effect rather than being only a controller-state
change.

The 11 main-phase windows were all valid:

```text
local samples/window:  min 114,520, median 287,869, max 1,197,972
remote samples/window: min 3,240,466, median 7,727,024, max 12,774,421
```

This confirms that the earlier sparse-sample observation described the Silo
initialization phase, not the transaction phase.

## Performance

```text
Silo transaction runtime       210.425 s
aggregate throughput           15.0842 million operations/s
full process wall time         701.73 s
maximum RSS                    121,302,336 KiB
promoted                       55.538 GiB
demoted                        86.599 GiB
```

Context from earlier local16 runs with the same Silo command and memory sizes:

| Run | Kernel | Transaction runtime | Throughput |
| --- | --- | ---: | ---: |
| Fixed migration ON | #23 | 205.298 s | 15.3748 Mops/s |
| Fixed migration OFF | #23 | 435.918 s | 7.22259 Mops/s |
| Previous main-gated stop, no restart | #26 | 250.310 s | 12.7453 Mops/s |
| Inverse-capacity policy | #27 | 210.425 s | 15.0842 Mops/s |

The new run is within 2.5% of the older fixed-ON runtime and is 2.07x faster
than the older fixed-OFF runtime. These are directional comparisons, not a
controlled performance claim, because the fixed baselines used kernel build
23 and the new run used build 27. A same-kernel repeated ON/OFF/policy matrix
is still required for a publishable comparison.

## Limitations

- The weighted-KLL snapshot reports a rank error of 50,000 ppm. At window 32,
  the strict remote CDF exceeded `B` by 31,125 ppm, which is inside that error
  bound. Window 33 had a much larger 419,643 ppm margin. The implementation
  follows the requested comparison exactly and does not add an error margin.
- Raw start remained true for every main-phase window, so the runtime branch
  that turns migration off after a later raw-start failure was covered by unit
  tests but was not exercised by this Silo run.
- The kernel fields are mutually consistent within one copied snapshot. The
  pre-existing per-CPU snapshot collection can still be a fuzzy cut if an
  external writer advances the window during collection. This run disabled
  auto-advance and advanced windows sequentially from the controller.
- Guest-side plot generation was skipped because the guest image lacks
  Matplotlib. The controller CSV, raw window snapshots, and workload results
  were collected successfully.

## Result

The policy behaved as designed. The unchanged stop rule turned migration off
on the first main-phase window. The new inverse-capacity rule preserved that
first decision, confirmed on the next distinct window, overrode the
simultaneous stop request, and restored migration. It then kept migration on
for the rest of Silo's transaction phase.
