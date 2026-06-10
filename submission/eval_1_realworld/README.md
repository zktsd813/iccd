# Eval 1 Real-World Figure

This directory contains the real-world VM32 normalized execution-time figure
with promotion counts.

- `eval_1_realworld_normalized_execution_time_promotions.pdf`
- `eval_1_realworld_normalized_execution_time_promotions.svg`
- `eval_1_realworld_normalized_execution_time_promotions.png`
- `eval_1_realworld_normalized_execution_time_promotions.csv`
- `plot_eval_1_realworld.py`

The figure uses three horizontal subplots for local memory sizes 16 GiB, 32
GiB, and 48 GiB. Bars use normalized execution time:

```text
normalized execution time = policy_elapsed_s / migration_off_elapsed_s
```

Thus `1.0` is equal to migration off, values above `1.0` are slower, and
values below `1.0` are faster. The right y-axis shows `pgpromote_success` in
millions. Promotion lines are drawn only within each workload group, connecting
the policy points for that workload; lines are not connected across workloads.

Included workloads:

- PR
- BC
- GUPS
- Graph500
- BTree
- Redis-U
- Redis-A
- FASTER-U
- FASTER-A

Included policies:

- memory tiering
- TPP
- migration-gatekeeper

The source CSV is copied under `source/`. A latest copy is also placed under
`experiments/figure/submission_eval_1_realworld_normalized_execution_time_promotions.{pdf,svg,png}`.

## Current VM Runner Notes

New eval_1 VM runs use the VM32 runner under
`motivation/3_realworld/VM/scripts/`. The default workload set is the nine
workloads included in this figure; `silo` and `liblinear` are no longer part of
the default matrix and must be requested explicitly.

GAPBS PR/BC use a shared raw ext4 data disk instead of copying the serialized
graph into the rootfs overlay for every VM:

```text
host image: motivation/3_realworld/VM/data/gapbs_g29_ext4_80g.raw
guest path: /mnt/data/gapbs/kron_g29.sg
QEMU drive: format=raw,cache=none,aio=native
```

The runner mounts the disk before the workload phase, drops host page cache
before running, and records the graph path as `/mnt/data/gapbs/kron_g29.sg` in
new result metadata.
