# Migration-Unfriendly Microbenchmark Prep

Date: 2026-05-18 UTC

## Target

Use the current documented standalone unfriendly candidate:

```text
stream_read_32g_split16_4kstride
```

This maps to:

```text
mbench --mode bw --bw-kernel read \
  --arena-size 32G --window-size 32G \
  --move-policy fixed \
  --placement window-split:0,1 \
  --bw-stride 512 --bw-block 4K \
  --threads 32
```

`--bw-stride 512` means 512 double elements, or one 8-byte access per 4 KiB
page. The window is first-touched as 16 GiB on node0 and 16 GiB on node1, then
the VMA policy is reset to default so NUMA balancing can scan and migrate it.

## Purpose

This is the migration-unfriendly benchmark because the working set is a 32 GiB
streaming read while the fast-tier cgroup cap is 16 GiB. Migration-on tends to
promote and demote pages for a streaming pattern that does not reuse a stable
local hotset, so the migration traffic and hint-fault overhead reduce
throughput.

The current reference result from 2026-05-08 was:

| policy | steady mean | steady median | promoted | demoted | hint faults |
| --- | ---: | ---: | ---: | ---: | ---: |
| off | 4312.96 MiB/s | 4314.00 MiB/s | 0 | 0 | 0 |
| on | 1544.30 MiB/s | 1524.00 MiB/s | 2,963,323 pages | 2,807,093 pages | 14,000,138 |

Mean on/off ratio: `0.358x`.

## Prepared Run

Run from the host:

```bash
/Serverless/iccd/experiments/20260518-migration-unfriendly-stream32/run_unfriendly_stream32.sh
```

Prepared settings:

```text
MEMORY=96G
CPUS=32
HOST_CPUS=0-31
NUMA_NODE0_CPUS=0-31
NUMA_NODE0_MEM=32G
NUMA_NODE1_MEM=64G
NUMA_NODE0_HOST_NODES=0
NUMA_NODE1_HOST_NODES=2
NUMA_MEM_POLICY=bind
NUMA_PREALLOC=1
CAPACITY_PAGES=4194304
LOCAL_NODE=0
REMOTE_NODE=1
CPUSET_CPUS=0-31
CPUSET_MEMS=0,1
POLICIES=off,on
TIMEOUT_SEC=220
NUMA_SCAN_SIZE_MB=4096
NUMA_FAST_SCAN=0
HOT_THRESHOLD_MS=0
NODE_BALANCING_ON=2
KSWAPD_DEMOTION_ON=1
OFF_DEMOTION_ON=1
GLOBAL_NUMA_ON=0
NUMA_MIGRATION_STOP_ENABLED=0
NUMA_PINGPONG_STAT_ENABLED=0
NUMA_PROMOTE_SAMPLE_STAT_ENABLED=0
NUMA_LOCAL_FAULT_ON_TIERING=0
```

The wrapper builds a fresh initrd for the current `/Serverless/Migration-friendly/linux`
kernel with:

```text
BUILD_INITRD=1
INITRD_NAME=initramfs-6.18.0modified-unfriendly-stream32-20260518.img
```

## Expected Artifacts

Run root:

```text
/Serverless/iccd/experiments/20260518-migration-unfriendly-stream32/qemu-logs/phase_candidate_microbench/<RUN_ID>/
```

Important files:

```text
guest-run.log
qemu-launch.log
guest-artifacts/<RUN_ID>/summary.jsonl
guest-artifacts/<RUN_ID>/*/cmd.txt
guest-artifacts/<RUN_ID>/*/vmstat.before
guest-artifacts/<RUN_ID>/*/vmstat.after
guest-artifacts/<RUN_ID>/*/cgroup.before
guest-artifacts/<RUN_ID>/*/cgroup.after
```

After the run, summarize off/on throughput, promotion/demotion pages, NUMA hint
faults, and PTE updates. Confirm `lru_gen_enabled=0x0007` in the guest metadata
before interpreting the result.
