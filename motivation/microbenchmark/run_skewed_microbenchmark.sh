#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%d-%H%M%S)}"

export EXP_NAME="${EXP_NAME:-${RUN_ID}-skew-hotset16-local24-controller}"
export EXP_ROOT="${EXP_ROOT:-${SCRIPT_DIR}/results/${EXP_NAME}}"
export FIGURE_PREFIX="${FIGURE_PREFIX:-skew_hotset16_local24_2x_}"
export VM_NAME="${VM_NAME:-iccd-skew-hotset16-local24}"
export SSH_PORT="${SSH_PORT:-10118}"
export FAST_MEM="${FAST_MEM:-24G}"
export SLOW_MEM="${SLOW_MEM:-64G}"

export WINDOW_SEC="${WINDOW_SEC:-5}"
export LOCAL_RATE="${LOCAL_RATE:-5}"
export REMOTE_RATE="${REMOTE_RATE:-5}"
export NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-256}"
export NUMA_SCAN_PERIOD_MIN_MS="${NUMA_SCAN_PERIOD_MIN_MS:-1000}"
export USE_KERNEL_DEFAULT_NUMA_SCAN="${USE_KERNEL_DEFAULT_NUMA_SCAN:-0}"

export WORKLOAD_COMMAND="${WORKLOAD_COMMAND:-/root/mbench --mode skewed-hotset --arena-size 32G --window-size 16G --move-policy fixed --placement window-split:0,1 --window-split-local 8G --hotset-pages 4194304 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode xorshift --threads 32 --sample-ms 1000 --csv --target-ops 87372828500}"

exec "${SCRIPT_DIR}/run_controller_microbenchmark_host.sh" "$@"
