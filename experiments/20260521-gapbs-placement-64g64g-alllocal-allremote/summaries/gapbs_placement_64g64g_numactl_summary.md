# GAPBS placement baseline, 64G/64G VM, numactl membind

Values are GAPBS `Average Time` seconds; lower is better.

- VM: 128G total, guest node0 64G on host node0 DRAM, guest node1 64G on host node2 CXL.
- CPU: 32 vCPUs pinned to guest node0 / host CPUs 0-31.
- Placement: `numactl --cpunodebind=0 --membind=0` for all-local, `--membind=1` for all-remote.
- Migration/local-fault/demotion/cgroup capacity: off.
- Graph: `/root/gapbs_graphs/kron_g28.sg`, loaded with `-f`; trial count 8.

| workload | all-local avg | all-remote avg | remote/local | local read | remote read |
| --- | ---: | ---: | ---: | ---: | ---: |
| pr | 19.63317 | 88.66312 | 4.516x | 20.82947 | 21.67309 |
| bc | 12.08365 | 59.90764 | 4.958x | 21.03300 | 26.68853 |

## Raw trials

- pr all-local: avg 19.63317s; trials [20.26, 19.59, 19.57, 19.47, 19.48, 19.52, 19.56, 19.60]
- pr all-remote: avg 88.66312s; trials [92.90, 87.98, 88.09, 87.85, 88.06, 87.87, 88.52, 88.03]
- bc all-local: avg 12.08365s; trials [13.67, 11.07, 10.84, 12.02, 12.55, 12.33, 11.30, 12.90]
- bc all-remote: avg 59.90764s; trials [64.50, 57.48, 48.86, 65.68, 60.43, 63.15, 51.05, 68.12]
