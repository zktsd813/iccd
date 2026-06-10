# Fault Bucket Controller Design

## Summary

This design implements a userspace controller for global NUMA migration. It
uses the kernel fault latency histogram window as the control signal:

- local signal: P80 bucket index from `local_pages`
- remote signal: P20 bucket index from `remote_pages`
- migration control: `/proc/sys/kernel/numa_balancing`

The controller does not add kernel APIs. It reads and writes the current ICCD
NUMA balancing sysfs/proc knobs.

## Kernel Interaction

Required paths:

```text
/sys/kernel/mm/numa_balancing/fault_latency_histograms
/sys/kernel/mm/numa_balancing/local_fault_window
/sys/kernel/mm/numa_balancing/local_fault_rate
/sys/kernel/mm/numa_balancing/remote_fault_rate
/proc/sys/kernel/numa_balancing
```

Startup behavior:

- Set `/proc/sys/kernel/numa_balancing=2`.
- Set `local_fault_rate=5`.
- Set `remote_fault_rate=5`.
- At the start of every controller window, write `1` to `local_fault_window`
  to advance/reset the kernel histogram bucket.

Stop behavior:

- When the policy decides to stop migration, write
  `/proc/sys/kernel/numa_balancing=0`.
- Keep `local_fault_rate=5` and `remote_fault_rate=5`.
- Continue monitoring until the workload exits or a stop file is created.
- Off-state windows are recorded as `monitor_off`; they do not advance the
  stop counters.
- Re-enable migration when the remote restart signal says remote hotness is
  increasing again.

## Policy

Buckets are indexed as:

```text
0 <=1ms
1 <=16ms
2 <=64ms
3 <=128ms
4 <=256ms
5 <=512ms
6 <=1024ms
7 <=2048ms
8 <=4096ms
9 <=8192ms
10 >8192ms
```

For each valid window while migration is on:

1. Compute `local_p80_idx` from `local_pages`.
2. Compute `remote_p20_idx` from `remote_pages`.
3. Compute `gap = local_p80_idx - remote_p20_idx`.
4. The first valid window is skipped and is not used for a decision.
5. If `gap < 0`, local P80 is faster than remote P20. This is the
   migration-unnecessary region. The controller also computes
   `effective_gap = remote_p20_idx - local_p80_idx`. The first valid window in
   this region establishes an effective baseline. If `effective_gap` increases,
   migration may still be changing the distribution and the stop counter is not
   incremented. If `effective_gap` stays the same or decreases, increment the
   effective stop counter. If the counter reaches 2, stop migration with
   `stop_reason=effective`.
6. If `gap >= 0`, migration is still needed. The first such valid window
   establishes a baseline gap. If later `gap` shrinks, migration is improving
   and stays enabled. If `gap` stays the same or grows, stop migration
   immediately with `stop_reason=no_improve`.

Invalid windows are recorded but reset the stop decision baseline. A window is
invalid when either local or remote histogram total is below the configured
minimum page count, or when either percentile is unavailable. The default
minimum is 1024 pages for each side. Low-sample sides are not mapped to the
final bucket.

After the controller has observed the first valid remote histogram in the
current on-state, a later on-state window with remote samples below the remote
minimum stops migration with `stop_reason=remote_low_sample`.

## Restart Policy

Restart depends on why migration was stopped.

If migration was stopped with `stop_reason=effective`, the controller treats a
new `gap >= 0` valid off-state window as migration-needed again and immediately
restarts migration.

If migration was stopped with `stop_reason=no_improve`, the controller keeps
the existing remote-share restart policy. The stop window is not used as the
restart baseline. Instead, the first valid off-state protected window arms the
restart baseline:

1. Let `n = remote_p20_idx` at the protected window.
2. Let `compare_idx = n`.
3. Record `baseline_share = sum(remote_pages[0:compare_idx+1]) /
   sum(remote_pages)`.
Invalid protected windows reset the protected count, so the baseline is taken
from one valid off-state window.

During off-state monitoring, the controller recomputes the same relative
prefix share:

```text
current_share = sum(remote_pages[0:compare_idx+1]) / sum(remote_pages)
```

If `current_share >= baseline_share * 1.20` for 2 consecutive valid windows,
the controller writes `/proc/sys/kernel/numa_balancing=2` and resets the stop
state. The threshold is always compared against the protected-window baseline;
it does not compound as `1.20`, then `1.20 * 1.20`. Invalid off-state windows
reset the restart consecutive count. After restart, it skips stop decisions for
1 grace window while still recording histogram rows.

The `no_improve` restart signal is remote-only by design. Local histograms
continue to be recorded for diagnosis. The `effective` restart signal uses both
local and remote percentiles, because it is checking whether the workload has
returned to the migration-needed region.

## Files

- `bucket_latency_controller.py`: controller implementation.
- `run_guest.sh`: guest-side workload runner that starts the controller,
  executes a workload, and stores raw windows/results.
- `plot_controller.py`: plots controller bucket indices and gap/counter state.
- `test_bucket_latency_controller.py`: parser and policy tests.

## Example

Inside a prepared guest:

```bash
OUTROOT=/root/fault-bucket-btree \
RUN_NAME=btree-local32-rate5 \
WINDOW_SEC=5 \
LOCAL_RATE=5 \
REMOTE_RATE=5 \
/root/design/fault_bucket_controller/run_guest.sh
```

The run directory contains:

```text
controller.csv
fault_latency_windows/window_*.fault_latency_histograms
before.meta
after.meta
time.txt
stdout.txt
stderr.txt
figures/*.svg
figures/*.pdf
```
