# Motivation 1 VM32 Selected Results

This directory contains selected VM32 real-world results copied from
`motivation/3_realworld/VM` for submission figure generation.

Selection:

- local memory 16 GiB: `pr`, configs `migration_off`, `tiering_0x2`, `tpp_0x4`
- local memory 32 GiB: `btree`, same configs
- local memory 48 GiB: `gups`, same configs
- `controller_0x2` is excluded

Generated artifacts:

- `vm32_selected_results.csv`: all selected rows
- `vm32_local16_pr_results.csv`
- `vm32_local32_btree_results.csv`
- `vm32_local48_gups_results.csv`
- `vm32_selected_execution_time.{png,pdf,svg}`
- `plot_vm32_selected.py`: source used to regenerate the CSVs and figure

The figure uses dual linear y-axes: execution time bars on the left y-axis and
promoted GiB as a line plot on the right y-axis.
