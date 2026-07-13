#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

OUTROOT="${OUTROOT:-/root/vm32_realworld-$(date -u +%Y%m%dT%H%M%SZ)}"
LOCAL_SIZE_GIB="${LOCAL_SIZE_GIB:-}"
CONFIGS="${CONFIGS:-off on tpp ours}"
WORKLOADS="${WORKLOADS:-pr bc gups btree graph500 silo}"
CASE_RUNNER="${CASE_RUNNER:-${SCRIPT_DIR}/run_workload_case_guest.sh}"
RESUME="${RESUME:-1}"

NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-256}"
LOCAL_FAULT_SCAN_PERIOD_MS="${LOCAL_FAULT_SCAN_PERIOD_MS:-1000}"
LOCAL_FAULT_SCAN_SIZE_MB="${LOCAL_FAULT_SCAN_SIZE_MB:-64}"

WINDOW_SEC="${WINDOW_SEC:-1}"
CYCLE_WINDOW_MIN_SEC="${CYCLE_WINDOW_MIN_SEC:-5}"
CYCLE_WINDOW_MAX_SEC="${CYCLE_WINDOW_MAX_SEC:-20}"
LOCAL_RATE="${LOCAL_RATE:-5}"
MIN_LOCAL_PAGES="${MIN_LOCAL_PAGES:-1024}"
MIN_REMOTE_PAGES="${MIN_REMOTE_PAGES:-1024}"
START_CONSECUTIVE="${START_CONSECUTIVE:-2}"
START_CAPACITY_MARGIN_PCT="${START_CAPACITY_MARGIN_PCT:-10}"
STOP_CAPACITY_RATIO_THRESHOLD="${STOP_CAPACITY_RATIO_THRESHOLD:-0.9}"
P75_STAGNATION_REQUIRED_DECREASE_PCT="${P75_STAGNATION_REQUIRED_DECREASE_PCT:-10}"
P75_STAGNATION_REQUIRED_WINDOWS="${P75_STAGNATION_REQUIRED_WINDOWS:-3}"
P75_STAGNATION_RESTART_DEGRADATION_PCT="${P75_STAGNATION_RESTART_DEGRADATION_PCT:-10}"
P75_STAGNATION_RESTART_REQUIRED_WINDOWS="${P75_STAGNATION_RESTART_REQUIRED_WINDOWS:-3}"
REMOTE_RESTART_IMPROVEMENT_PCT="${REMOTE_RESTART_IMPROVEMENT_PCT:-10}"
LOCAL_NODE="${LOCAL_NODE:-0}"
REMOTE_NODE="${REMOTE_NODE:-1}"
MIGRATION_ENABLED_PATH="${MIGRATION_ENABLED_PATH:-/sys/kernel/mm/numa_balancing/migration_enabled}"

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
        printf '%s\n' off on tpp ours
        ;;
      off|on|tpp|ours)
        printf '%s\n' "${item}"
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
          pr bc gups btree graph500 silo
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
    printf 'timeout_kill_after_sec=%s\n' "${TIMEOUT_KILL_AFTER_SEC:-60}"
    printf 'omp_threads=%s\n' "${OMP_THREADS:-}"
    printf 'mglru_enabled=%s\n' "${MGLRU_ENABLED:-}"
    printf 'numa_scan_size_mb=%s\n' "${NUMA_SCAN_SIZE_MB}"
    printf 'numa_scan_period_min_ms=%s\n' "${NUMA_SCAN_PERIOD_MIN_MS:-}"
    printf 'numa_scan_period_max_ms=%s\n' "${NUMA_SCAN_PERIOD_MAX_MS:-}"
    printf 'numa_scan_delay_ms=%s\n' "${NUMA_SCAN_DELAY_MS:-}"
    printf 'local_fault_scan_period_ms=%s\n' "${LOCAL_FAULT_SCAN_PERIOD_MS}"
    printf 'local_fault_scan_size_mb=%s\n' "${LOCAL_FAULT_SCAN_SIZE_MB}"
    printf 'thp_mode=%s\n' "${THP_MODE:-}"
    printf 'thp_defrag=%s\n' "${THP_DEFRAG:-}"
    printf 'realworld_size_profile=%s\n' "${REALWORLD_SIZE_PROFILE:-}"
    printf 'verify_required_state=%s\n' "${VERIFY_REQUIRED_STATE:-}"
    printf 'disable_swap=%s\n' "${DISABLE_SWAP:-}"
    printf 'window_sec=%s\n' "${WINDOW_SEC}"
    printf 'cycle_window_min_sec=%s\n' "${CYCLE_WINDOW_MIN_SEC}"
    printf 'cycle_window_max_sec=%s\n' "${CYCLE_WINDOW_MAX_SEC}"
    printf 'local_rate=%s\n' "${LOCAL_RATE}"
    printf 'min_local_pages=%s\n' "${MIN_LOCAL_PAGES}"
    printf 'min_remote_pages=%s\n' "${MIN_REMOTE_PAGES}"
    printf 'start_consecutive=%s\n' "${START_CONSECUTIVE}"
    printf 'start_capacity_margin_pct=%s\n' "${START_CAPACITY_MARGIN_PCT}"
    printf 'stop_capacity_ratio_threshold=%s\n' "${STOP_CAPACITY_RATIO_THRESHOLD}"
    printf 'p75_stagnation_required_decrease_pct=%s\n' "${P75_STAGNATION_REQUIRED_DECREASE_PCT}"
    printf 'p75_stagnation_required_windows=%s\n' "${P75_STAGNATION_REQUIRED_WINDOWS}"
    printf 'p75_stagnation_restart_degradation_pct=%s\n' "${P75_STAGNATION_RESTART_DEGRADATION_PCT}"
    printf 'p75_stagnation_restart_required_windows=%s\n' "${P75_STAGNATION_RESTART_REQUIRED_WINDOWS}"
    printf 'remote_restart_improvement_pct=%s\n' "${REMOTE_RESTART_IMPROVEMENT_PCT}"
    printf 'local_node=%s\n' "${LOCAL_NODE}"
    printf 'remote_node=%s\n' "${REMOTE_NODE}"
    printf 'migration_enabled_path=%s\n' "${MIGRATION_ENABLED_PATH}"
    printf 'gapbs_graph_mode=generated\n'
    printf 'gapbs_graph_scale=%s\n' "${GAPBS_GRAPH_SCALE:-}"
    printf 'gapbs_graph_path=generated:g%s\n' "${GAPBS_GRAPH_SCALE:-}"
    printf 'graph_build_included=1\n'
    printf 'pr_trials=%s\n' "${PR_TRIALS:-}"
    printf 'bc_trials=%s\n' "${BC_TRIALS:-}"
    printf 'silo_scale_factor=%s\n' "${SILO_SCALE_FACTOR:-}"
    printf 'silo_ops_per_worker=%s\n' "${SILO_OPS_PER_WORKER:-}"
    printf 'silo_zipf_theta=%s\n' "${SILO_ZIPF_THETA:-}"
    printf 'silo_zipf_reverse=%s\n' "${SILO_ZIPF_REVERSE:-}"
    printf 'silo_workload_mix=%s\n' "${SILO_WORKLOAD_MIX:-}"
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
  local expanded_configs expanded_workloads
  expanded_configs="$(expand_configs ${CONFIGS})"
  expanded_workloads="$(expand_workloads ${WORKLOADS})"
  mapfile -t config_list <<< "${expanded_configs}"
  mapfile -t workload_list <<< "${expanded_workloads}"
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
