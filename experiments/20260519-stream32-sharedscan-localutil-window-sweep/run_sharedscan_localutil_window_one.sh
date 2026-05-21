#!/usr/bin/env bash
set -euo pipefail

WINDOW_SEC="${WINDOW_SEC:?set WINDOW_SEC to 5, 10, or 20}"
EXP_NAME="${EXP_NAME:-20260519-stream32-sharedscan-localutil-window-sweep}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-sharedscan-localutil-window${WINDOW_SEC}s-300s}"
OUTDIR="/Serverless/iccd/experiments/${EXP_NAME}/qemu-logs/phase_candidate_microbench"

cd /Serverless/Migration-friendly

env \
  RUN_ID="${RUN_ID}" \
  OUTDIR="${OUTDIR}" \
  KERNEL_IMAGE="/Serverless/Migration-friendly/linux/arch/x86/boot/bzImage" \
  BUILD_INITRD=1 \
  INITRD_NAME="initramfs-6.18.0modified-stream32-sharedscan-localutil-20260519.img" \
  MEMORY=96G \
  CPUS=32 \
  HOST_CPUS=0-31 \
  NUMA_NODE0_CPUS=0-31 \
  NUMA_NODE0_MEM=32G \
  NUMA_NODE1_MEM=64G \
  NUMA_NODE0_HOST_NODES=0 \
  NUMA_NODE1_HOST_NODES=2 \
  NUMA_MEM_POLICY=bind \
  NUMA_PREALLOC=1 \
  LOCAL_NODE=0 \
  REMOTE_NODE=1 \
  CPUSET_CPUS=0-31 \
  CPUSET_MEMS=0,1 \
  CAPACITY_PAGES=4194304 \
  THREADS=32 \
  ARENA_SIZE=32G \
  CANDIDATES=stream_read_32g_split16_4kstride_sharedscan \
  POLICIES=adaptive_localutil \
  REPS=1 \
  TIMEOUT_SEC=360 \
  MBENCH_FORCE_DURATION_MS=300000 \
  SAMPLE_MS=1000 \
  LIVE_SAMPLE_SEC=5 \
  OPS_PER_PASS=65536 \
  PAUSE_NS=100000 \
  NUMA_SCAN_SIZE_MB=256 \
  NUMA_FAST_SCAN=0 \
  HOT_THRESHOLD_MS=0 \
  NODE_BALANCING_ON=2 \
  KSWAPD_DEMOTION_ON=1 \
  OFF_DEMOTION_ON=1 \
  GLOBAL_NUMA_ON=0 \
  PREFAULT_PHASE_GATE=1 \
  PREFAULT_SETTLE_RECLAIMD=0 \
  NUMA_MIGRATION_STOP_ENABLED=0 \
  NUMA_PINGPONG_STAT_ENABLED=0 \
  NUMA_PROMOTE_SAMPLE_STAT_ENABLED=0 \
  NUMA_LOCAL_FAULT_ON_TIERING=10 \
  NUMA_LOCAL_FAULT_REFAULT_HIT_MS=2000 \
  LOCAL_UTIL_ADAPT_WINDOW_SEC="${WINDOW_SEC}" \
  LOCAL_UTIL_ADAPT_THRESHOLD_PCT=80 \
  LOCAL_UTIL_ADAPT_CONSECUTIVE=3 \
  LOCAL_UTIL_ADAPT_MIN_PTE_UPDATES=1000 \
  /Serverless/Migration-friendly/scripts/kernel/run_qemu_phase_candidate_microbench.sh
