# GAPBS g28 Graph Cache

Generated host-side serialized graph:

```text
/Serverless/benchmark/gapbs/benchmark/graphs/kron_g28.sg
```

Build command:

```bash
cd /Serverless/benchmark/gapbs
env OMP_NUM_THREADS=32 OMP_PROC_BIND=true OMP_PLACES=cores \
  ./converter -g28 -b benchmark/graphs/kron_g28.sg
```

Observed build:

```text
Generate Time: 45.67093 s
Build Time: 83.08067 s
Graph has 268435455 nodes and 4236159892 undirected edges for degree: 15
Wall time: 2:41.07
Max RSS: 73984776 KiB
Output size: 34 GiB
```

Smoke load:

```bash
cd /Serverless/benchmark/gapbs
env OMP_NUM_THREADS=32 OMP_PROC_BIND=true OMP_PLACES=cores \
  ./pr -f benchmark/graphs/kron_g28.sg -i1 -t1e-4 -n1
```

Observed load:

```text
Read Time: 15.70605 s
Graph has 268435455 nodes and 4236159892 undirected edges for degree: 15
Trial Time: 3.99287 s
Average Time: 3.99287 s
```

The PR/BC guest wrappers now default to `GAPBS_PREBUILD_GRAPH=1`. They prepare
`/root/gapbs_graphs/kron_g28.sg` once if absent, then run measured PR/BC commands
with `-f /root/gapbs_graphs/kron_g28.sg` instead of `-g28`.
