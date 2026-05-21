# Pause before kernel push

Paused at: 2026-05-21T05:31:17Z to 2026-05-21T05:32:22Z.

Experiment:

- Name: `20260521-gapbs-full-latest-placement-audit`
- Guest output copied to:
  `/Serverless/iccd/experiments/20260521-gapbs-full-latest-placement-audit/guest-results/partial-before-kernel-push`
- VM: canonical 96G topology, node0 32G host node0, node1 64G host node2, 32 vCPUs on node0.
- Kernel: `Linux kernel 6.18.0modified #179 SMP PREEMPT_DYNAMIC Wed May 20 03:30:57 UTC 2026`.
- Graph: `/root/gapbs_graphs/kron_g28.sg`, loaded with GAPBS `-f`.
- Live audit interval: 5s `memory.numa_stat`, `memory.current`, migration stats, and local-fault stats.

Completed before pause:

- `pr-8g/off`
- `pr-8g/on`
- `pr-8g/oneshot-w5`

Not yet run:

- `pr-8g/toggle-w5`
- `pr-8g/oneshot-w10`
- `pr-8g/toggle-w10`
- `pr-8g/oneshot-w20`
- `pr-8g/toggle-w20`
- All remaining PR 16G and BC 8G/16G cases.

Resume point:

- Continue from `pr-8g/toggle-w5` or rerun the whole sweep in a fresh guest output directory after kernel push.
