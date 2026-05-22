# Phase-Switching Experiment

This experiment tests whether migration remains beneficial inside one
execution after the access pattern or hotset changes. The run should keep one
process, one arena, and one cgroup lifetime while changing only the workload
phase. That exposes policies that look good for a stable hotset but leave pages
in the wrong tier after locality moves.

## Built-In Preset

The built-in `friendly-unfriendly` phase preset alternates between two access
shapes:

- `friendly-bw-reuse`: stable bandwidth reads over a fixed window that should
  give migration enough time to identify hot pages and improve throughput.
- `unfriendly-stream`: a larger streaming `triad` window that sweeps across
  the arena, making stale placement and excess migration visible.

Interpret the preset by phase, not only by whole-run average. A useful policy
should show a throughput gain during the friendly phase, limited disruption at
the phase boundary, and no large sustained loss during the unfriendly phase. If
migration counters rise while unfriendly-phase throughput stays flat or drops,
the policy is probably chasing stale hotness. If the next friendly interval
recovers quickly, the policy is adapting to the new hotset; slow recovery means
old residency is still influencing placement.

## Smoke Command

Use a small arena first so the phase path, sample labels, and counter capture
can be checked quickly:

```bash
make -C Microbenchmark
Microbenchmark/mbench --phase-preset friendly-unfriendly \
  --arena-size 256M --window-size 64M --threads 2 \
  --phase-ms 3000 --sample-ms 250 --csv
```

This smoke run is for plumbing only. It should produce samples tagged with
`phase_elapsed_ms`, `phase_id`, and `phase_name`, and show at least one
friendly-to-unfriendly switch. Phase-preset runs use the configured phase
durations directly, so this smoke path does not wait for the legacy single-mode
fixed warmup and measured window.

## Main Experiment Preparation

- Keep arena size, window size, thread count, placement, and phase timing fixed
  across migration-policy comparisons.
- Run at least a no-migration baseline and the target migration policy in the
  same cgroup/memory-cap configuration.
- Choose phase lengths long enough for the friendly phase to reach steady
  throughput, then keep `--sample-ms` short enough to observe the switch and
  recovery window.
- Save raw CSV/stdout together with kernel and cgroup counters so phase samples
  can be aligned with residency and migration events.

## Metrics

- Phase throughput: steady throughput for each phase, excluding the immediate
  switch transient when reporting steady state.
- Recovery after switch: time from a phase boundary until throughput returns
  near that phase's steady value.
- Migration counters: deltas in counters such as successful/failed migrations,
  NUMA migrations, and policy-specific migration events per phase.
- Stale migration and residency risk: pages left in the previously preferred
  tier, rising migrations without throughput gain, or slow residency movement
  after the hotset changes.
