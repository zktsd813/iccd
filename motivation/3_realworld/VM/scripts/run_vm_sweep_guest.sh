#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

OUTROOT="${OUTROOT:-/root/vm32_realworld-$(date -u +%Y%m%dT%H%M%SZ)}"
LOCAL_SIZE_GIB="${LOCAL_SIZE_GIB:-}"
CONFIGS="${CONFIGS:-migration_off tiering_0x2 tpp_0x4}"
WORKLOADS="${WORKLOADS:-pr bc gups graph500 btree redis_uniform redis_ycsb_a faster_uniform faster_ycsb_a}"
CASE_RUNNER="${CASE_RUNNER:-${SCRIPT_DIR}/run_workload_case_guest.sh}"
RESUME="${RESUME:-1}"

mkdir -p "${OUTROOT}"

log() {
  printf '[vm32-guest] %s\n' "$*" | tee -a "${OUTROOT}/orchestrator.log" >&2
}

die() {
  printf '[vm32-guest] error: %s\n' "$*" >&2
  exit 2
}

expand_configs() {
  local item
  for item in "$@"; do
    case "${item}" in
      all|default)
        printf '%s\n' migration_off tiering_0x2 tpp_0x4
        ;;
      migration_off|tiering_0x2|migration_on|tpp_0x4|tpp|all_local|all_slow|controller_0x2)
        printf '%s\n' "${item}"
        ;;
      controller)
        printf '%s\n' controller_0x2
        ;;
      *)
        die "unknown config '${item}'"
        ;;
    esac
  done | awk '!seen[$0]++'
}

expand_workloads() {
  local item
  for item in "$@"; do
    case "${item}" in
      all|default)
        printf '%s\n' \
          pr bc gups graph500 btree \
          redis_uniform redis_ycsb_a faster_uniform faster_ycsb_a
        ;;
      *)
        printf '%s\n' "${item}"
        ;;
    esac
  done | awk '!seen[$0]++'
}

snapshot_environment() {
  local dir="$1"
  mkdir -p "${dir}"
  {
    printf 'date_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'uname=%s\n' "$(uname -a)"
    printf 'cmdline=%s\n' "$(cat /proc/cmdline 2>/dev/null || true)"
    printf 'outroot=%s\n' "${OUTROOT}"
    printf 'local_size_gib=%s\n' "${LOCAL_SIZE_GIB}"
    printf 'configs=%s\n' "${CONFIGS}"
    printf 'workloads=%s\n' "${WORKLOADS}"
    printf 'case_runner=%s\n' "${CASE_RUNNER}"
    printf 'timeout_sec=%s\n' "${TIMEOUT_SEC:-}"
    printf 'sample_interval_sec=%s\n' "${SAMPLE_INTERVAL_SEC:-}"
    printf 'omp_threads=%s\n' "${OMP_THREADS:-}"
    printf 'mglru_enabled=%s\n' "${MGLRU_ENABLED:-}"
    printf 'numa_scan_size_mb=%s\n' "${NUMA_SCAN_SIZE_MB:-}"
    printf 'numa_scan_period_min_ms=%s\n' "${NUMA_SCAN_PERIOD_MIN_MS:-}"
    printf 'local_fault_rate=%s\n' "${LOCAL_FAULT_RATE:-}"
    printf 'remote_fault_rate=%s\n' "${REMOTE_FAULT_RATE:-}"
    printf 'local_fault_scan_period_ms=%s\n' "${LOCAL_FAULT_SCAN_PERIOD_MS:-}"
    printf 'local_fault_scan_size_mb=%s\n' "${LOCAL_FAULT_SCAN_SIZE_MB:-}"
    printf 'remote_fault_scan_period_ms=%s\n' "${REMOTE_FAULT_SCAN_PERIOD_MS:-}"
    printf 'remote_fault_scan_size_mb=%s\n' "${REMOTE_FAULT_SCAN_SIZE_MB:-}"
    printf 'thp_mode=%s\n' "${THP_MODE:-}"
    printf 'thp_defrag=%s\n' "${THP_DEFRAG:-}"
    printf 'realworld_size_profile=%s\n' "${REALWORLD_SIZE_PROFILE:-}"
    printf 'verify_required_state=%s\n' "${VERIFY_REQUIRED_STATE:-}"
    printf 'trace_bc_trial_promotions=%s\n' "${TRACE_BC_TRIAL_PROMOTIONS:-}"
    printf 'controller_window_sec=%s\n' "${CONTROLLER_WINDOW_SEC:-}"
    printf 'controller_local_rate=%s\n' "${CONTROLLER_LOCAL_RATE:-}"
    printf 'controller_remote_rate=%s\n' "${CONTROLLER_REMOTE_RATE:-}"
    printf 'controller_local_fault_scan_period_ms=%s\n' "${CONTROLLER_LOCAL_FAULT_SCAN_PERIOD_MS:-}"
    printf 'controller_local_fault_scan_size_mb=%s\n' "${CONTROLLER_LOCAL_FAULT_SCAN_SIZE_MB:-}"
    printf 'controller_remote_fault_scan_period_ms=%s\n' "${CONTROLLER_REMOTE_FAULT_SCAN_PERIOD_MS:-}"
    printf 'controller_remote_fault_scan_size_mb=%s\n' "${CONTROLLER_REMOTE_FAULT_SCAN_SIZE_MB:-}"
    printf 'controller_min_local_pages=%s\n' "${CONTROLLER_MIN_LOCAL_PAGES:-}"
    printf 'controller_min_remote_pages=%s\n' "${CONTROLLER_MIN_REMOTE_PAGES:-}"
    printf 'controller_consecutive_effective=%s\n' "${CONTROLLER_CONSECUTIVE_EFFECTIVE:-}"
    printf 'controller_consecutive_no_improve=%s\n' "${CONTROLLER_CONSECUTIVE_NO_IMPROVE:-}"
    printf 'controller_restart_remote_share_threshold=%s\n' "${CONTROLLER_RESTART_REMOTE_SHARE_THRESHOLD:-}"
    printf 'controller_consecutive_restart=%s\n' "${CONTROLLER_CONSECUTIVE_RESTART:-}"
    printf 'controller_restart_grace_windows=%s\n' "${CONTROLLER_RESTART_GRACE_WINDOWS:-}"
    printf 'controller_numa_balancing_on=%s\n' "${CONTROLLER_NUMA_BALANCING_ON:-}"
    printf 'controller_numa_balancing_off=%s\n' "${CONTROLLER_NUMA_BALANCING_OFF:-}"
    printf 'graph=%s\n' "${GRAPH:-}"
    printf 'gapbs_graph_scale=%s\n' "${GAPBS_GRAPH_SCALE:-}"
    printf 'pr_trials=%s\n' "${PR_TRIALS:-}"
    printf 'bc_trials=%s\n' "${BC_TRIALS:-}"
    printf 'silo_scale_factor=%s\n' "${SILO_SCALE_FACTOR:-}"
    printf 'silo_ops_per_worker=%s\n' "${SILO_OPS_PER_WORKER:-}"
    printf 'liblinear_dataset=%s\n' "${LIBLINEAR_DATASET:-}"
  } > "${dir}/environment.meta"
  numactl -H > "${dir}/environment.numactl" 2>&1 || true
  {
    for tier in /sys/devices/virtual/memory_tiering/memory_tier*; do
      [[ -d "${tier}" ]] || continue
      printf '%s=' "$(basename "${tier}")"
      cat "${tier}/nodelist" 2>/dev/null || printf 'NA\n'
    done
  } > "${dir}/environment.memory_tiers" 2>/dev/null || true
}

run_one() {
  local config="$1" workload="$2" outdir="${OUTROOT}/${config}/${workload}"

  mkdir -p "${outdir}"
  if [[ "${RESUME}" == "1" && -f "${outdir}/status.txt" ]] && grep -q '^returncode=0$' "${outdir}/status.txt"; then
    log "skip existing successful config=${config} workload=${workload}"
    return 0
  fi

  log "start config=${config} workload=${workload}"
  set +e
  "${CASE_RUNNER}" --config "${config}" --workload "${workload}" --outdir "${outdir}"
  local rc=$?
  set -e
  log "done config=${config} workload=${workload} rc=${rc}"
  return "${rc}"
}

main() {
  [[ -x "${CASE_RUNNER}" ]] || die "case runner is not executable: ${CASE_RUNNER}"

  local -a config_list=()
  local -a workload_list=()
  mapfile -t config_list < <(expand_configs ${CONFIGS})
  mapfile -t workload_list < <(expand_workloads ${WORKLOADS})
  local progress_base="${PROGRESS_BASE:-0}"
  local progress_total="${PROGRESS_TOTAL:-$((${#config_list[@]} * ${#workload_list[@]}))}"

  snapshot_environment "${OUTROOT}"
  {
    printf 'local_size_gib: %s\n' "${LOCAL_SIZE_GIB}"
    printf 'configs:'
    printf ' %s' "${config_list[@]}"
    printf '\nworkloads:'
    printf ' %s' "${workload_list[@]}"
    printf '\n'
  } > "${OUTROOT}/matrix.txt"

  local failed=0 config workload progress_idx=0 progress_current rc
  for config in "${config_list[@]}"; do
    snapshot_environment "${OUTROOT}/${config}"
    for workload in "${workload_list[@]}"; do
      progress_idx=$((progress_idx + 1))
      progress_current=$((progress_base + progress_idx))
      log "progress start ${progress_current}/${progress_total} config=${config} workload=${workload}"
      set +e
      run_one "${config}" "${workload}"
      rc=$?
      set -e
      log "progress done ${progress_current}/${progress_total} config=${config} workload=${workload} rc=${rc}"
      if [[ "${rc}" != "0" ]]; then
        failed=1
      fi
    done
  done

  return "${failed}"
}

main "$@"
