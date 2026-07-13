# Resident-Capacity Quantile Controller

## Scope

This controller implements one policy for two-tier NUMA memory. Decisions use
only the current quantile window and current resident capacity.

State retained across windows is limited to the raw START confirmation count;
the P75-stagnation trigger's previous P75, count, and three trigger values; and
the latched guard state, fixed local P75, fixed remote rank and latency, and
joint restart counter. The default normal START confirmation length is two
windows.

## Required Kernel Interface

The controller and its production runner use these paths under
`/sys/kernel/mm/numa_balancing`:

```text
numa_scan_size_mb       configure normal NUMA scan size
numa_scan_period_min_ms configure the minimum normal scan period
numa_scan_period_max_ms configure the maximum normal scan period
numa_scan_delay_ms      configure the initial normal scan delay
fault_latency_quantiles  read weighted-KLL window data
remote_quantile_rank_ppm write the remote inverse-CDF query rank
local_fault_window       write 1 to advance the sampling window
local_fault_rate         keep local and remote policy sampling enabled
migration_enabled        enable or disable page migration
remote_scan_cycles       read the completed remote scan cycle count
```

It also keeps `/proc/sys/kernel/numa_balancing=2`. A policy transition changes
only `migration_enabled`; NUMA scanning and fault sampling continue while
migration is off.

The `quantile_snapshot_v4` source must report:

```text
algorithm kll_weighted_ms_v1
value_source sketch_latency_ms_to_ns
local_total
remote_total
local_q75_ns
remote_query_rank_ppm
remote_query_q_ns
remote_query_valid
remote_cdf_lt_local_q75_ppm
remote_cdf_le_local_q75_ppm
```

Any source other than the required weighted KLL implementation is rejected.
`local_fault_rate` must be in `[1, 100]` for a controller run. When it is zero,
the kernel skips local probes, remote KLL updates, and remote scan-cycle
accounting so baseline modes do not pay policy-measurement overhead.

## Resident Capacity

Every policy window rereads the workload process tree from the PID in
`--workload-pid-file`. The controller sums `N<local>=` and `N<remote>=` pages
from `/proc/<pid>/numa_maps`:

```text
L = current local resident pages
R = current remote resident pages
```

These values are not cached across windows. A missing PID, unreadable process
tree, or zero capacity makes the relevant observation invalid and cannot cause
a transition.

## STOP

Let `local_p75_latency` be the same-window local P75 latency. The inclusive
remote CDF query reports the fraction of remote samples whose latency is less
than or equal to that latency.

```text
local_tail_pages       = 0.25 * local_resident_pages
remote_candidate_pages = remote_cdf_at_or_below_local_p75
                         * remote_resident_pages
stop_ratio             = remote_candidate_pages / local_tail_pages

STOP_RAW = stop_ratio > 0.9
```

The comparison is strictly greater than the threshold. A ratio exactly equal
to `0.9` does not request STOP. STOP has no consecutive-window counter.

## START

START is a latency comparison. Capacity determines which remote latency
quantile to compare; capacity is not the final comparison signal.

First choose the remote quantile rank that represents the required capacity:

```text
local_head_pages = 0.75 * local_resident_pages
start_required_pages = (1 + start_capacity_margin_pct / 100)
                       * local_head_pages
start_remote_quantile_rank_ppm =
    ceil(1,000,000 * start_required_pages / remote_resident_pages)
start_remote_quantile_rank = start_remote_quantile_rank_ppm / 1,000,000
```

Then compare latency with latency:

```text
start_remote_latency = Q_remote(start_remote_quantile_rank)
local_reference_latency = Q_local(0.75)

START_RAW = start_remote_latency < local_reference_latency
```

For ordinary START, the controller uses the strict remote CDF below local P75
to evaluate the exactly equivalent inverse-quantile condition:

```text
remote_cdf_below_local_p75 >= start_remote_quantile_rank
```

The implementation uses integer cross multiplication, so no floating-point
rounding changes the boundary:

```text
100 * remote_cdf_below_local_p75 * remote_resident_pages
    >= (100 + start_capacity_margin_pct)
       * 0.75 * local_resident_pages
```

The strict CDF preserves the strict latency comparison by excluding remote
observations tied at local P75. With the default 10% margin, the selected
remote quantile represents 10% more capacity than the unmodified local head.
If `start_remote_quantile_rank > 100%`, the remote resident population cannot
represent the required capacity, START is false, and
`start_reason=remote_capacity_below_start_requirement` is recorded.

START_RAW must be true for two consecutive valid windows. A false or invalid
window resets the counter to zero.

## Local/Remote Restart Guard

When raw START and raw STOP are both true, the controller compares local P75
with the immediately preceding jointly valid local P75. A decrease smaller
than 10% increments the guard count. A decrease of exactly 10% or more, or an
end to the START/STOP overlap, resets the count. An invalid or zero-P75 window
resets both the count and comparison reference.

Three consecutive stagnant comparisons latch `FORCED_OFF`. The fixed restart
reference is the maximum local P75 among the three windows that incremented the
count; the preceding comparison baseline is not included. On entry, the normal
START confirmation count is reset. It remains frozen while the guard is
latched.

Before each snapshot, the controller writes a remote quantile query rank. In
`NORMAL`, this is the same capacity-selected rank used by START. The snapshot
must echo that rank and contain a valid remote quantile. When the guard latches,
the STOP-window rank and its remote quantile latency are saved as fixed restart
references. In `FORCED_OFF`, the controller queries that same frozen rank even
though the ordinary START rank continues to follow current resident capacity.

`FORCED_OFF` keeps migration off regardless of the normal START and STOP
results. It counts a restart candidate only when all of the following are true:

```text
START is valid
START_RAW is true
local_p75 >= (1 + restart_degradation_pct / 100) * fixed_reference_p75
current_remote_q(fixed_rank)
    <= (1 - remote_restart_improvement_pct / 100)
       * fixed_reference_remote_q
```

Both comparisons are latency comparisons. Local P75 must be at least 10% worse
than its fixed reference, while the fixed-rank remote fault latency must be at
least 10% smaller than its fixed reference. Smaller fault latency means the
remote page was accessed sooner and is hotter. Equality qualifies at both
boundaries. The echoed query rank must match the frozen rank.

Any false or invalid candidate resets the joint counter. The third consecutive
joint candidate starts migration immediately, returns the guard to `NORMAL`,
and seeds the independent START confirmation count as confirmed. There is no
`REARMING` state. Trigger history is reset with that window's local P75 as the
next comparison baseline.

```text
NORMAL --three stagnant overlap comparisons--> FORCED_OFF
FORCED_OFF --three joint local/remote START candidates--> NORMAL + START
FORCED_OFF --false or invalid window--> FORCED_OFF with count zero
```

## Arbitration And State Transitions

The order is fixed:

```text
latched P75-stagnation STOP
    > P75-stagnation restart
    > confirmed normal START
    > raw STOP
    > HOLD
```

Outside the guard, confirmed START keeps or turns migration on even if raw STOP
is also true in the same window. Before confirmation, a simultaneous raw STOP
can turn migration off; a second consecutive raw START can turn it back on in
the next window. An ordinary migration state change does not reset the START
counter. A guard latch does reset it, freezes it until restart succeeds, and
then seeds it as confirmed.

```text
START while off  -> migration_enabled=1
STOP while on    -> migration_enabled=0
HOLD              -> preserve the current state
```

## Windowing

Window evaluation follows `remote_scan_cycles`. The controller polls at
`--window-sec`, waits at least `--cycle-window-min-sec`, and accepts a window
when the cycle count advances. `--cycle-window-max-sec` provides an upper bound
when a cycle does not advance. After reading a completed window, the controller
writes `1` to `local_fault_window`.

Defaults are a one-second poll, five-second minimum, and twenty-second maximum.

## Command-Line Interface

The workload PID file is the only required argument:

```bash
bucket_latency_controller.py \
  --workload-pid-file /run/workload.pid \
  --output /results/controller.csv \
  --stop-file /results/stop-controller
```

Policy parameters:

```text
--start-consecutive                 default 2
--start-capacity-margin-pct         default 10
--stop-capacity-ratio-threshold     default 0.9
--p75-stagnation-required-decrease-pct  default 10
--p75-stagnation-required-windows       default 3
--p75-stagnation-restart-degradation-pct default 10
--p75-stagnation-restart-required-windows default 3
--remote-restart-improvement-pct     default 10
--min-local-pages                   default 1024
--min-remote-pages                  default 1024
```

System and window parameters:

```text
--window-sec
--cycle-window-min-sec
--cycle-window-max-sec
--local-rate
--local-node
--remote-node
--sysfs-numa-dir
--numa-balancing-path
--migration-enabled-path
--remote-scan-cycles-path
```

## Output

`controller.csv` records only inputs and outcomes needed to audit this policy:

- KLL sample totals, local P75, remote query rank/latency/validity, and
  strict/inclusive remote CDF values
- current resident `L` and `R`
- STOP capacity values, ratio, validity, and raw result
- START base/required capacity, capacity-selected remote quantile rank,
  relative margin, validity, latency-comparison result, count, and confirmation
- P75-stagnation trigger threshold, previous P75, pairwise decrease, and count
- guard state and transition, fixed local P75 and remote rank/latency
  references, local degradation, remote improvement, joint counter, forced
  STOP result, and confirmed guard restart
- arbitration, controller state, and migration transition

The capacity-selected rank is named `start_remote_quantile_rank_ppm`.
`config.meta` records
`policy=capacity_rank_latency_local_remote_restart_v3` and
`controller_csv_schema=capacity_rank_latency_local_remote_restart_v3`.

Transition rows use `event=off` for a STOP transition and `event=on` for a
confirmed START transition. `transition_action` records `migration_stop` or
`migration_start` respectively.

The controller does not archive a duplicate raw sysfs snapshot for every
window and does not plot inside the timed guest run. `controller.csv` contains
the same policy inputs and outcomes; plots are generated on the host after
results have been copied out of the guest.
