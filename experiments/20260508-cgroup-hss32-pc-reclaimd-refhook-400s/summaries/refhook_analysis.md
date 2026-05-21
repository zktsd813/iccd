# Reclaimd Reference Hook Analysis

Experiment: `20260508-cgroup-hss32-pc-reclaimd-refhook-400s`
Run: `cgroup_hss32_pc_refhook_400s_on_20260508T092827Z`
Candidate: `pc_lf_windowremote_32g_fixed_rss16g_chase1_persistent` policy `on` duration 400s

## Overall, measured window after prefault

- Promotion success: 1,376,542 pages = 5.25 GiB
- Promotion over_high failures: 9,795,754 pages = 37.37 GiB
- Demote selected by reclaimd after reference check: 19,300,997 pages = 73.63 GiB
- Demote success: 5,715,382 pages = 21.80 GiB (29.6% of selected)
- Demote fail after selection: 13,585,615 pages = 51.83 GiB (70.4% of selected)
- Reference ACTIVATE: 2,844,738 pages = 10.85 GiB
- Reference KEEP: 271,788 pages = 1.04 GiB
- Reference RECLAIM: 19,111,817 pages = 72.91 GiB (86.0% of reference decisions)
- Reference-blocked event volume (ACTIVATE+KEEP): 3,116,526 pages = 11.89 GiB (14.0% of reference decisions)

## Prefault-to-before snapshot

- Before the measured run, reclaimd had already selected 5,008,328 pages = 19.11 GiB and demoted 5,008,328 pages = 19.11 GiB.
- In that pre-measurement segment, reference-blocked volume was 2 pages = 0.0000 GiB, while RECLAIM was 5,008,328 pages = 19.11 GiB.

## Interpretation

- This does not look like demotion is failing because all 16 GiB of local memory are referenced. Most folios reaching `folio_check_references()` are classified as reclaimable, and reclaimd selects a large demotion volume.
- The dominant loss is after selection: the selected folios enter the demotion path, but a large fraction remains after `demote_folio_list()`. This hook does not classify the lower-level migration failure cause.
- Counters here are event volume, not unique-page coverage. Repeated scans can count the same page more than once.

## Phase CSV

- 60s summary: `/Serverless/iccd/experiments/20260508-cgroup-hss32-pc-reclaimd-refhook-400s/summaries/refhook_phase_60s.csv`
- live deltas: `/Serverless/iccd/experiments/20260508-cgroup-hss32-pc-reclaimd-refhook-400s/summaries/refhook_live_delta.csv`
