# Host topology note

Run: `refault_compare_bound_cxl_20260507T054501Z`

This run uses the required local-vs-CXL topology:

- QEMU CPU affinity: host CPUs `0-31` on host NUMA node0.
- Guest NUMA node0: 32G memory backend bound to host NUMA node0 DRAM.
- Guest NUMA node1: 64G memory backend bound to host NUMA node2 CXL memory.
- Memory backend policy: `bind`.
- Memory backend preallocation: `on`.

QEMU launch log contains:

```text
-object memory-backend-ram,id=mem0,size=32G,host-nodes=0,policy=bind,prealloc=on
-object memory-backend-ram,id=mem1,size=64G,host-nodes=2,policy=bind,prealloc=on
-numa node,nodeid=0,cpus=0-31,memdev=mem0
-numa node,nodeid=1,memdev=mem1
```

During the run, the QEMU process was checked with:

```text
taskset -pc <qemu-pid> -> 0-31
sudo awk ... /proc/<qemu-pid>/numa_maps -> N0 32.1 GiB, N2 64.0 GiB
```

Previous runs without these host CPU/memory bindings are invalid for local-vs-CXL performance interpretation.
