# BC controller case study

Source run: `/Serverless/iccd-git/submission_socc/final_experiments/runs/20260714T221803Z-eval3-bc-case-v3-v4abi-matched`

This package maps controller elapsed time to GAPBS BC generated-graph phases using stdout durations:
generate, build, then trial1..trial8.

Key CSV files:

- `summary.csv`: elapsed time, migration volume, and controller event counts.
- `bc_phase_timeline.csv`: generated graph/build/trial interval reconstruction.
- `controller_transitions.csv`: actual migration ON/OFF transitions.
- `controller_windows.csv`: selected controller fields for every sampled window.
- `trial_state_summary.csv`: whether migration changed during each of the 8 trials.
