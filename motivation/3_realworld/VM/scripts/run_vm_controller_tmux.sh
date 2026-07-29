#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

export RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-vm32-ours-local16-32-48}"
export SESSION="${SESSION:-vm32-ours-${RUN_ID}}"
export LOCAL_SIZES_GIB="${LOCAL_SIZES_GIB:-16 32 48}"
export CONFIGS="ours"
export WORKLOADS="${WORKLOADS:-pr bc gups btree graph500 silo}"
export WINDOW_SEC="${WINDOW_SEC:-1}"
export CYCLE_WINDOW_MIN_SEC="${CYCLE_WINDOW_MIN_SEC:-5}"
export CYCLE_WINDOW_MAX_SEC="${CYCLE_WINDOW_MAX_SEC:-20}"
export LOCAL_RATE="${LOCAL_RATE:-1}"
export LOCAL_FAULT_SCAN_PERIOD_MS="${LOCAL_FAULT_SCAN_PERIOD_MS:-1000}"
export LOCAL_FAULT_SCAN_SIZE_MB="${LOCAL_FAULT_SCAN_SIZE_MB:-64}"
export CONTROLLER_POLICY="window-cdf-gap"
export START_CDF_GAP_PPM="${START_CDF_GAP_PPM:-200000}"
export WINDOW_CONSECUTIVE="1"
export STOP_CAPACITY_RATIO_THRESHOLD="${STOP_CAPACITY_RATIO_THRESHOLD:-0.9}"

exec "${SCRIPT_DIR}/run_vm_sweep_tmux.sh"
