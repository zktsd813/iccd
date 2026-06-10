# Motivation 3 Microbenchmark Figure

This directory packages the VM fixed-ops microbenchmark data from
`motivation/2_microbenchmark` for submission.

Source data:

- `source/placement_modes.csv`

Selection:

- `local_mem_gib = 16`
- modes: `all_fast`, `half_fast` (source row `half_local`), `all_slow`
- each x-axis group shows migration off/on execution time for the same target
  operation count

Generated artifacts:

- `motivation2_vm_microbench_selected.csv`
- `motivation2_vm_microbench_execution_time.{png,pdf,svg}`
- `plot_motivation2_vm_microbench.py`

The figure reports elapsed seconds to complete the fixed `target_ops`, so lower
is better. Throughput is retained in the selected CSV and shown below for
reference.

| Mode | Initial placement | Off s | On s | On/off time | Off Mops/s | On Mops/s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| all_fast | 16G / 16G | 261.0 | 699.1 | 2.68x | 168.4 | 63.0 |
| half_fast | 8G / 24G | 377.2 | 725.1 | 1.92x | 116.5 | 60.7 |
| all_slow | 0G / 32G | 499.4 | 845.9 | 1.69x | 88.0 | 52.2 |
