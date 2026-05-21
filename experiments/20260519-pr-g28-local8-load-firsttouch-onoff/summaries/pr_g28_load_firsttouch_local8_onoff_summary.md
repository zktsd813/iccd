# PR g28 load-only first-touch local8 on/off

Run ID: `20260519T045208Z-prg28-load-local8-onoff-kvm`

Artifacts: `/Serverless/iccd/experiments/20260519-pr-g28-local8-load-firsttouch-onoff/qemu-logs/pr_g28_local8_load_firsttouch_onoff/20260519T045208Z-prg28-load-local8-onoff-kvm`

## Setup

| item | value |
| --- | --- |
| workload | GAPBS PageRank g28 |
| command | `/root/pr -f /root/gapbs_graphs/kron_g28.sg -i20 -t1e-4 -n3` |
| graph input | prebuilt serialized graph, generation excluded |
| graph file | `/root/gapbs_graphs/kron_g28.sg` |
| placement | default first-touch; no numactl/mempolicy placement override |
| local capacity | 2097152 pages = 8 GiB |
| VM | 32 vCPUs, 96G; node0 32G on host node0, node1 64G on host node2 |
| kernel | Linux 6.18.0modified #176, KVM |
| MGLRU | 0x0007 |
| scan | 256MB, min period 1000ms, fast scan off |
| demotion | on for both policies |
| graph cache handling | copied to guest before measurement; dropped page cache before each policy |

## Runtime

| policy | node_balancing | Read Time s | Trial avg s | Trial times s | elapsed s |
| --- | ---: | ---: | ---: | --- | ---: |
| off | 0 | 30.91569 | 19.11743 | 19.53829, 18.89169, 18.92230 | 90 |
| on | 2 | 26.26831 | 55.99104 | 53.45255, 49.50145, 65.01911 | 197 |

- on/off trial-time ratio: `2.929x` slower
- on/off throughput ratio: `0.341x`

## Migration Counters

| policy | hint faults | PTE updates | promoted pages | promoted GiB | demoted pages | demoted GiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| off | 0 | 0 | 0 | 0.00 | 10176841 | 38.82 |
| on | 29702070 | 29898160 | 13100805 | 49.98 | 23218700 | 88.57 |

## Notes

`on` is pure migration-on: `node_balancing=2`, demotion on, local-fault sampling off. `off` keeps demotion on but disables NUMA balancing. The graph is loaded via `-f`; `converter -g28` was not run in the measured path.
