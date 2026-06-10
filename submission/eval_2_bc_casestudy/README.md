# BC Case Study

This directory contains the local32GiB BC case-study figure for memory tiering
and migration-gatekeeper.

Run root:

`/Serverless/iccd-git/motivation/3_realworld/VM/results/20260610T083046Z-eval2-bc-promotion-local32`

Inputs:

- Workload: GAPBS BC, prebuilt graph, `bc`.
- VM local memory: 32 GiB.
- Policies: `tiering_0x2` and `controller_0x2`.
- Promotion metric: `/proc/vmstat` `pgpromote_success`, sampled every 5s during
  the workload and linearly interpolated at BC trial boundaries.

Timing sources:

- `/Serverless/iccd-git/motivation/3_realworld/VM/results/20260610T083046Z-eval2-bc-promotion-local32/guest-results/local32/tiering_0x2/bc/workload.stdout.log`
- `/Serverless/iccd-git/motivation/3_realworld/VM/results/20260610T083046Z-eval2-bc-promotion-local32/guest-results/local32/controller_0x2/bc/controller/stdout.txt`
- `/Serverless/iccd-git/motivation/3_realworld/VM/results/20260610T083046Z-eval2-bc-promotion-local32/guest-results/local32/controller_0x2/bc/controller/controller.csv`

Artifacts:

- `bc_controller_promotion_timeline.pdf`: migration state plus per-trial
  promotion counts.
- `bc_controller_migration_events.csv`: controller off/restart positions
  recalculated with exact trial boundaries.
- `bc_trial_promotions.csv`: per-trial promotion counts.
- `bc_trial_boundaries.csv`: Read Time plus cumulative trial boundaries.
