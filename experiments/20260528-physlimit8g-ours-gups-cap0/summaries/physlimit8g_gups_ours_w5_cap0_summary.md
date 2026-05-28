# Physical 8G GUPS ours, node_capacity=0

- VM: node0 physical 8G, node1 160G.
- Cgroup capacity: disabled (`capacity_pages=0`).
- Control/stat cgroup: non-root cgroup with `node_balancing=2`, `numa_local_fault_on_tiering=10`.
- Controller: window 5s, threshold 80%, consecutive 3, eval lag prev.

## Result

| policy | seconds | note |
|---|---:|---|
| physical off baseline | 656.20 | previous cgfix physical 8G |
| physical on baseline | 1223.32 | previous cgfix physical 8G |
| ours w5 cap0 | 645.00 | off at 45.022s, reason `local_access` |

## Counters

| counter | delta |
|---|---:|
| numa_hint_faults | 15,567,673 |
| pgpromote_success | 1,189,723 |
| pgdemote_total | 2,343,360 |
| pgmigrate_success | 3,666,756 |

## Off decision windows

| window | elapsed_s | pte_delta | refault_delta | access_pct | remote_ratio_pct | local_consecutive | node_balancing |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 7 | 35.019 | 14915 | 14915 | 100.00 | 84.32 | 1 | 2 |
| 8 | 40.020 | 41337 | 41337 | 100.00 | 80.27 | 2 | 2 |
| 9 | 45.021 | 60938 | 60626 | 99.49 | 69.34 | 3 | 2 |
| 9 | 45.022 | 60938 | 60626 | 99.49 | 69.34 | 3 | 0 |