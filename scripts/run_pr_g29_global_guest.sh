#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ICCD_DEFAULTS="${ICCD_DEFAULTS:-${SCRIPT_DIR}/iccd_experiment_defaults.sh}"
if [[ -r "${ICCD_DEFAULTS}" ]]; then
  # shellcheck source=scripts/iccd_experiment_defaults.sh
  source "${ICCD_DEFAULTS}"
fi

OUTROOT="${OUTROOT:-/root/pr-g29-global-$(date -u +%Y%m%dT%H%M%SZ)}"
RUNS="${RUNS:-migration_off migration_on}"
PR_BIN="${PR_BIN:-/root/pr}"
GRAPH_SCALE="${GRAPH_SCALE:-29}"
PR_ITERATIONS="${PR_ITERATIONS:-20}"
PR_TOLERANCE="${PR_TOLERANCE:-1e-4}"
PR_TRIALS="${PR_TRIALS:-1}"
OMP_THREADS="${OMP_THREADS:-32}"
TIMEOUT_SEC="${TIMEOUT_SEC:-21600}"
CPU_NODE="${CPU_NODE:-${ICCD_WORKLOAD_CPU_NODE:-${ICCD_PR_CPU_NODE:-0}}}"
MGLRU_ENABLED="${MGLRU_ENABLED:-${ICCD_MGLRU_ENABLED:-0x0007}}"
DEMOTION_ENABLED="${DEMOTION_ENABLED:-${ICCD_DEMOTION_ENABLED:-true}}"
DEMOTION_TARGET="${DEMOTION_TARGET:-${ICCD_DEMOTION_TARGET:-0 1}}"
NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-${ICCD_NUMA_SCAN_SIZE_MB:-256}}"
NUMA_SCAN_PERIOD_MIN_MS="${NUMA_SCAN_PERIOD_MIN_MS:-${ICCD_NUMA_SCAN_PERIOD_MIN_MS:-1000}}"
LOCAL_FAULT_SCAN_SIZE_MB="${LOCAL_FAULT_SCAN_SIZE_MB:-${ICCD_LOCAL_FAULT_SCAN_SIZE_MB:-64}}"
LOCAL_FAULT_SCAN_PERIOD_MS="${LOCAL_FAULT_SCAN_PERIOD_MS:-${ICCD_LOCAL_FAULT_SCAN_PERIOD_MS:-1000}}"
DROP_GUEST_CACHES="${DROP_GUEST_CACHES:-${ICCD_DROP_GUEST_CACHES:-1}}"

mkdir -p "${OUTROOT}"

log() {
  printf '[pr-g29] %s\n' "$*" >&2
}

write_if_writable() {
  local path="$1" value="$2"
  if [[ -w "${path}" ]]; then
    printf '%s\n' "${value}" > "${path}"
  fi
}

read_file() {
  local path="$1"
  if [[ -r "${path}" ]]; then
    cat "${path}"
  else
    printf 'NA\n'
  fi
}

set_common_knobs() {
  write_if_writable /sys/kernel/mm/lru_gen/enabled "${MGLRU_ENABLED}"
  write_if_writable /sys/kernel/mm/numa/demotion_enabled "${DEMOTION_ENABLED}"
  write_if_writable /sys/kernel/mm/numa/demotion_target "${DEMOTION_TARGET}"
  write_if_writable /sys/kernel/mm/numa_balancing/numa_scan_size_mb "${NUMA_SCAN_SIZE_MB}"
  write_if_writable /sys/kernel/mm/numa_balancing/numa_scan_period_min_ms "${NUMA_SCAN_PERIOD_MIN_MS}"
  write_if_writable /sys/kernel/mm/numa_balancing/local_fault_scan_size_mb "${LOCAL_FAULT_SCAN_SIZE_MB}"
  write_if_writable /sys/kernel/mm/numa_balancing/local_fault_scan_period_ms "${LOCAL_FAULT_SCAN_PERIOD_MS}"
}

policy_numa_value() {
  case "$1" in
    migration_on) printf '2\n' ;;
    migration_off|all_fast|all_slow) printf '0\n' ;;
    *) log "unknown run '${1}'"; exit 2 ;;
  esac
}

placement_args() {
  case "$1" in
    migration_on|migration_off)
      if declare -F iccd_workload_placement_args >/dev/null; then
        iccd_workload_placement_args "${CPU_NODE}"
      else
        printf '%s\0' numactl "--cpunodebind=${CPU_NODE}"
      fi
      ;;
    all_fast)
      printf '%s\0' numactl "--cpunodebind=${CPU_NODE}" --membind=0
      ;;
    all_slow)
      printf '%s\0' numactl "--cpunodebind=${CPU_NODE}" --membind=1
      ;;
    *)
      log "unknown run '${1}'"; exit 2 ;;
  esac
}

snapshot() {
  local dir="$1" tag="$2"
  {
    printf 'tag=%s\n' "${tag}"
    printf 'date_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'uname=%s\n' "$(uname -a)"
    printf 'cmdline=%s\n' "$(cat /proc/cmdline)"
    printf 'numa_balancing=%s\n' "$(read_file /proc/sys/kernel/numa_balancing)"
    printf 'lru_gen_enabled=%s\n' "$(read_file /sys/kernel/mm/lru_gen/enabled)"
    printf 'demotion_enabled=%s\n' "$(read_file /sys/kernel/mm/numa/demotion_enabled)"
    printf 'demotion_target<<EOF\n%s\nEOF\n' "$(read_file /sys/kernel/mm/numa/demotion_target)"
    printf 'scan_size_mb=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/numa_scan_size_mb)"
    printf 'scan_period_min_ms=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/numa_scan_period_min_ms)"
    printf 'local_fault_scan_size_mb=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/local_fault_scan_size_mb)"
    printf 'local_fault_scan_period_ms=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/local_fault_scan_period_ms)"
  } > "${dir}/${tag}.meta"
  cp /proc/vmstat "${dir}/${tag}.vmstat" 2>/dev/null || true
}

run_one() {
  local run="$1" dir="${OUTROOT}/${run}" numa_value
  local -a place cmd

  mkdir -p "${dir}"
  numa_value="$(policy_numa_value "${run}")"
  set_common_knobs
  write_if_writable /proc/sys/kernel/numa_balancing "${numa_value}"

  if [[ "${DROP_GUEST_CACHES}" == "1" ]]; then
    sync || true
    write_if_writable /proc/sys/vm/drop_caches 3
  fi

  snapshot "${dir}" before
  mapfile -d '' -t place < <(placement_args "${run}")
  cmd=("${place[@]}" "${PR_BIN}" -g "${GRAPH_SCALE}" -i "${PR_ITERATIONS}" -t "${PR_TOLERANCE}" -n "${PR_TRIALS}")

  {
    printf 'run=%s\n' "${run}"
    printf 'numa_balancing=%s\n' "${numa_value}"
    printf 'placement='
    printf '%q ' "${place[@]}"
    printf '\n'
    printf 'workload_cpu_node=%s\n' "${CPU_NODE}"
    printf 'workload_placement=numactl --cpunodebind=%s\n' "${CPU_NODE}"
    printf 'command='
    printf '%q ' "${cmd[@]}"
    printf '\n'
    printf 'omp_threads=%s\n' "${OMP_THREADS}"
    printf 'timeout_sec=%s\n' "${TIMEOUT_SEC}"
    printf 'drop_guest_caches=%s\n' "${DROP_GUEST_CACHES}"
  } > "${dir}/run.config"

  log "starting ${run}: ${cmd[*]}"
  set +e
  (
    export OMP_NUM_THREADS="${OMP_THREADS}"
    export OMP_PROC_BIND=true
    export OMP_PLACES=cores
    export MALLOC_ARENA_MAX=4
    /usr/bin/time -v -o "${dir}/time.txt" \
      timeout "${TIMEOUT_SEC}" "${cmd[@]}" \
      > "${dir}/pr.out" 2> "${dir}/pr.err"
  )
  status=$?
  set -e
  printf '%s\n' "${status}" > "${dir}/exit.status"
  snapshot "${dir}" after
  log "finished ${run} status=${status}"
  return "${status}"
}

main() {
  [[ -x "${PR_BIN}" ]] || { log "PR binary not executable: ${PR_BIN}"; exit 1; }
  printf '%s\n' "${RUNS}" > "${OUTROOT}/runs.list"
  snapshot "${OUTROOT}" environment

  local run failed=0
  for run in ${RUNS}; do
    if ! run_one "${run}"; then
      failed=1
      log "run failed: ${run}"
    fi
  done
  exit "${failed}"
}

main "$@"
