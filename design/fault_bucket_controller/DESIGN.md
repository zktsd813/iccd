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
0 <=128ms
1 <=256ms
2 <=512ms
3 <=1024ms
4 <=2048ms
5 <=4096ms
6 <=8192ms
7 >8192ms
```

For each valid window:

1. Compute `local_p80_idx` from `local_pages`.
2. Compute `remote_p20_idx` from `remote_pages`.
3. If `local_p80_idx < remote_p20_idx`, count this as `effective`.
4. If `effective` continues for 2 valid windows, stop migration.
5. Otherwise compute `gap = local_p80_idx - remote_p20_idx`.
6. If the next valid window's `gap` shrinks, migration is improving and the
   no-improve counter resets.
7. If `gap` stays the same or grows, increment the no-improve counter.
8. If no-improve reaches 2, stop migration.

Invalid windows are recorded but reset the consecutive stop decision state. A
window is invalid if either local or remote histogram total is below the
configured minimum page count. The default minimum is 1024 pages for each side.

## Restart Policy

When migration is stopped, the controller records a remote-side baseline:

1. Let `n = remote_p20_idx` at the stop window.
2. Let `compare_idx = min(n, last_bucket - 1)`.
3. Record `baseline_share = sum(remote_pages[0:compare_idx+1]) /
   sum(remote_pages)`.

The `last_bucket - 1` clamp avoids a degenerate case. If `remote_p20_idx` is
the final `>8192ms` bucket, summing through `n` would always produce 100%, so a
20% relative increase could never trigger.

During off-state monitoring, the controller recomputes the same relative
prefix share:

```text
current_share = sum(remote_pages[0:compare_idx+1]) / sum(remote_pages)
```

If `current_share >= baseline_share * 1.20` for 2 consecutive valid windows,
the controller writes `/proc/sys/kernel/numa_balancing=2` and resets the stop
state. The threshold is always compared against the stop-time baseline; it does
not compound as `1.20`, then `1.20 * 1.20`. Invalid off-state windows reset the
restart consecutive count. After restart, it skips stop decisions for 1 grace
window while still recording histogram rows.

The restart signal is remote-only by design. Local histograms continue to be
recorded for diagnosis, but they are not used to restart migration.

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
