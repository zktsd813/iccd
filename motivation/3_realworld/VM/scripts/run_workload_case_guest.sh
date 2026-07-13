#!/usr/bin/env bash
set -euo pipefail

CONFIG=""
WORKLOAD=""
OUTDIR=""

while (($# > 0)); do
  case "$1" in
    --config)
      CONFIG="${2:?missing --config value}"
      shift 2
      ;;
    --workload)
      WORKLOAD="${2:?missing --workload value}"
      shift 2
      ;;
    --outdir)
      OUTDIR="${2:?missing --outdir value}"
      shift 2
      ;;
    -h|--help)
      cat <<'EOF'
Usage:
  run_workload_case_guest.sh --config CONFIG --workload WORKLOAD --outdir DIR

Runs one workload under one global-NUMA config without cgroup or memcg controls.
EOF
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

[[ -n "${CONFIG}" ]] || { echo "missing --config" >&2; exit 2; }
[[ -n "${WORKLOAD}" ]] || { echo "missing --workload" >&2; exit 2; }
[[ -n "${OUTDIR}" ]] || { echo "missing --outdir" >&2; exit 2; }

BENCHMARK_DIR="${BENCHMARK_DIR:-/root/benchmark}"
TOOLS_DIR="${TOOLS_DIR:-/root/tools}"
REALWORLD_CASE_RUNNER="${REALWORLD_CASE_RUNNER:-/root/scripts/run_workload_case_guest.sh}"
GRAPH="${GRAPH:-}"
WORKDIR="${WORKDIR:-/root/realworld-work}"
CPU_NODE="${CPU_NODE:-0}"
OMP_THREADS="${OMP_THREADS:-32}"
TIMEOUT_SEC="${TIMEOUT_SEC:-21600}"
TIMEOUT_KILL_AFTER_SEC="${TIMEOUT_KILL_AFTER_SEC:-60}"
MGLRU_ENABLED="${MGLRU_ENABLED:-0x0007}"
DEMOTION_ENABLED="${DEMOTION_ENABLED:-true}"
DEMOTION_TARGET="${DEMOTION_TARGET:-0 1}"
NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-256}"
NUMA_SCAN_PERIOD_MIN_MS="${NUMA_SCAN_PERIOD_MIN_MS:-1000}"
NUMA_SCAN_PERIOD_MAX_MS="${NUMA_SCAN_PERIOD_MAX_MS:-}"
NUMA_SCAN_DELAY_MS="${NUMA_SCAN_DELAY_MS:-}"
LOCAL_FAULT_SCAN_PERIOD_MS="${LOCAL_FAULT_SCAN_PERIOD_MS:-1000}"
LOCAL_FAULT_SCAN_SIZE_MB="${LOCAL_FAULT_SCAN_SIZE_MB:-64}"
THP_MODE="${THP_MODE:-}"
THP_DEFRAG="${THP_DEFRAG:-${THP_MODE}}"
REALWORLD_SIZE_PROFILE="${REALWORLD_SIZE_PROFILE:-rss60}"
VERIFY_REQUIRED_STATE="${VERIFY_REQUIRED_STATE:-1}"
LOCAL_SIZE_GIB="${LOCAL_SIZE_GIB:-}"
CONTROLLER_DIR="${CONTROLLER_DIR:-/root/design/fault_bucket_controller}"
CONTROLLER_RUNNER="${CONTROLLER_RUNNER:-${CONTROLLER_DIR}/run_guest.sh}"
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
CONTROLLER_POLICY="capacity_rank_latency_local_remote_restart_v3"
LOCAL_NODE="${LOCAL_NODE:-0}"
REMOTE_NODE="${REMOTE_NODE:-1}"
MIGRATION_ENABLED_PATH="${MIGRATION_ENABLED_PATH:-/sys/kernel/mm/numa_balancing/migration_enabled}"

PR_ITERATIONS="${PR_ITERATIONS:-20}"
PR_TOLERANCE="${PR_TOLERANCE:-1e-4}"
PR_TRIALS="${PR_TRIALS:-8}"
BC_ITERATIONS="${BC_ITERATIONS:-1}"
BC_TRIALS="${BC_TRIALS:-8}"
GAPBS_GRAPH_SCALE="${GAPBS_GRAPH_SCALE:-29}"
DROP_GUEST_CACHES="${DROP_GUEST_CACHES:-1}"
COMPACT_GUEST_MEMORY="${COMPACT_GUEST_MEMORY:-1}"
DISABLE_SWAP="${DISABLE_SWAP:-1}"
GUPS_MEMORY_GB="${GUPS_MEMORY_GB:-64}"
GRAPH500_SCALE="${GRAPH500_SCALE:-28}"
XSBENCH_GRID="${XSBENCH_GRID:-130000}"
XSBENCH_PARTICLES="${XSBENCH_PARTICLES:-90000000}"
SILO_SCALE_FACTOR="${SILO_SCALE_FACTOR:-800000}"
SILO_OPS_PER_WORKER="${SILO_OPS_PER_WORKER:-100000000}"
SILO_ZIPF_THETA="${SILO_ZIPF_THETA:-}"
SILO_ZIPF_REVERSE="${SILO_ZIPF_REVERSE:-1}"
SILO_WORKLOAD_MIX="${SILO_WORKLOAD_MIX:-}"
LIBLINEAR_DATASET="${LIBLINEAR_DATASET:-kdd12}"
LIBLINEAR_SOLVER="${LIBLINEAR_SOLVER:-6}"
LIBLINEAR_THREADS="${LIBLINEAR_THREADS:-${OMP_THREADS}}"

mkdir -p "${OUTDIR}" "${WORKDIR}"

log() {
  printf '[vm32-case] %s\n' "$*" | tee -a "${OUTDIR}/runner.log" >&2
}

read_file() {
  local path="$1"
  if [[ -r "${path}" ]]; then
    cat "${path}"
  else
    printf 'NA\n'
  fi
}

write_if_writable() {
  local path="$1" value="$2"
  if [[ -w "${path}" ]]; then
    (printf '%s\n' "${value}" > "${path}") 2>/dev/null || true
  fi
}

write_requested_knob() {
  local path="$1" value="$2"
  [[ -n "${value}" ]] || return 0
  need_writable_path "${path}" || return $?
  printf '%s\n' "${value}" > "${path}"
}

policy_numa_value() {
  case "$1" in
    on|ours) printf '2\n' ;;
    tpp) printf '4\n' ;;
    off) printf '0\n' ;;
    *) echo "unknown config: $1" >&2; return 2 ;;
  esac
}

policy_demotion_enabled() {
  case "$1" in
    off) printf 'false\n' ;;
    on|tpp|ours) printf 'true\n' ;;
    *) echo "unknown config: $1" >&2; return 2 ;;
  esac
}

policy_demotion_target() {
  case "$1" in
    off) printf '%s\n' "${DEMOTION_TARGET_OFF:-0 -1}" ;;
    on|tpp|ours) printf '%s\n' "${DEMOTION_TARGET}" ;;
    *) echo "unknown config: $1" >&2; return 2 ;;
  esac
}

policy_migration_enabled() {
  case "$1" in
    off) printf '0\n' ;;
    on|tpp|ours) printf '1\n' ;;
    *) echo "unknown config: $1" >&2; return 2 ;;
  esac
}

placement_args() {
  case "$1" in
    off|on|tpp|ours)
      printf '%s\0' numactl "--cpunodebind=${CPU_NODE}"
      ;;
    *)
      echo "unknown config: $1" >&2
      return 2
      ;;
  esac
}

is_controller_config() {
  case "$1" in
    ours) return 0 ;;
    *) return 1 ;;
  esac
}

need_exec_path() {
  local path="$1"
  [[ -x "${path}" ]] || {
    printf 'missing executable: %s\n' "${path}" >&2
    return 77
  }
}

need_file_path() {
  local path="$1"
  [[ -f "${path}" ]] || {
    printf 'missing file: %s\n' "${path}" >&2
    return 77
  }
}

need_readable_path() {
  local path="$1"
  [[ -r "${path}" ]] || {
    printf 'missing readable path: %s\n' "${path}" >&2
    return 77
  }
}

need_writable_path() {
  local path="$1"
  [[ -w "${path}" ]] || {
    printf 'missing writable path: %s\n' "${path}" >&2
    return 77
  }
}

WORKLOAD_CMD=()
WORKLOAD_COMMAND_KIND=""

gapbs_graph_args() {
  printf '%s\0' -g "${GAPBS_GRAPH_SCALE}"
}

set_workload_cmd() {
  WORKLOAD_CMD=()
  WORKLOAD_COMMAND_KIND="${WORKLOAD}"
  local -a graph_args

  case "${WORKLOAD}" in
    pr|gapbs_pr)
      need_exec_path "${BENCHMARK_DIR}/gapbs/pr" || return $?
      mapfile -d '' -t graph_args < <(gapbs_graph_args)
      WORKLOAD_CMD=("${BENCHMARK_DIR}/gapbs/pr" "${graph_args[@]}" -i "${PR_ITERATIONS}" -t "${PR_TOLERANCE}" -n "${PR_TRIALS}")
      ;;
    bc|gapbs_bc)
      need_exec_path "${BENCHMARK_DIR}/gapbs/bc" || return $?
      mapfile -d '' -t graph_args < <(gapbs_graph_args)
      WORKLOAD_CMD=("${BENCHMARK_DIR}/gapbs/bc" "${graph_args[@]}" -i "${BC_ITERATIONS}" -n "${BC_TRIALS}")
      ;;
    gups|gups_64g)
      need_exec_path "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_gups_mt" || return $?
      WORKLOAD_CMD=("${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_gups_mt" "${GUPS_MEMORY_GB}")
      ;;
    graph500|graph500_s28)
      need_exec_path "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_graph500_mt" || return $?
      WORKLOAD_CMD=("${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_graph500_mt" -s "${GRAPH500_SCALE}")
      ;;
    btree|btree_lookup)
      need_exec_path "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_btree_mt" || return $?
      WORKLOAD_CMD=("${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_btree_mt")
      ;;
    silo)
      need_exec_path "${BENCHMARK_DIR}/silo/out-perf.masstree/benchmarks/dbtest" || return $?
      local -a silo_bench_opts=()
      local silo_bench_opts_text=""
      if [[ -n "${SILO_WORKLOAD_MIX}" ]]; then
        silo_bench_opts+=("--workload-mix=${SILO_WORKLOAD_MIX}")
      fi
      if [[ -n "${SILO_ZIPF_THETA}" ]]; then
        silo_bench_opts+=("--zipf-theta=${SILO_ZIPF_THETA}")
      fi
      case "${SILO_ZIPF_REVERSE}" in
        1|true|TRUE|yes|YES|on|ON)
          silo_bench_opts+=("--zipf-reverse")
          ;;
      esac
      WORKLOAD_CMD=(
        "${BENCHMARK_DIR}/silo/out-perf.masstree/benchmarks/dbtest"
        --verbose
        --bench ycsb
        --num-threads "${SILO_THREADS:-${OMP_THREADS}}"
        --scale-factor "${SILO_SCALE_FACTOR}"
        "--ops-per-worker=${SILO_OPS_PER_WORKER}"
      )
      if ((${#silo_bench_opts[@]} > 0)); then
        printf -v silo_bench_opts_text '%s ' "${silo_bench_opts[@]}"
        WORKLOAD_CMD+=("--bench-opts=${silo_bench_opts_text% }")
      fi
      ;;
    liblinear)
      need_exec_path "${BENCHMARK_DIR}/liblinear-multicore-2.47/train" || return $?
      need_file_path "${BENCHMARK_DIR}/liblinear-multicore-2.47/datasets/${LIBLINEAR_DATASET}" || return $?
      WORKLOAD_CMD=(
        "${BENCHMARK_DIR}/liblinear-multicore-2.47/train"
        -s "${LIBLINEAR_SOLVER}"
        -m "${LIBLINEAR_THREADS:-${OMP_THREADS}}"
        "${BENCHMARK_DIR}/liblinear-multicore-2.47/datasets/${LIBLINEAR_DATASET}"
        "${WORKDIR}/liblinear/${CONFIG}-${LIBLINEAR_DATASET}.model"
      )
      mkdir -p "${WORKDIR}/liblinear"
      ;;
    xsbench|xsbench_grid130k_p90m)
      need_exec_path "${BENCHMARK_DIR}/XSBench/openmp-threading/XSBench" || return $?
      WORKLOAD_CMD=("${BENCHMARK_DIR}/XSBench/openmp-threading/XSBench" -t "${OMP_THREADS}" -g "${XSBENCH_GRID}" -p "${XSBENCH_PARTICLES}")
      ;;
    redis_uniform|redis_ycsb_a|rocksdb_ycsb_uniform|memcached_ycsb_uniform|faster_uniform|faster_ycsb_a|dlrm_synth)
      need_exec_path "${REALWORLD_CASE_RUNNER}" || return $?
      WORKLOAD_CMD=("${REALWORLD_CASE_RUNNER}" "${WORKLOAD}")
      WORKLOAD_COMMAND_KIND="realworld_case_runner"
      ;;
    *)
      printf 'unknown workload: %s\n' "${WORKLOAD}" >&2
      return 2
      ;;
  esac
}

set_common_knobs() {
  local config="$1"
  write_if_writable /sys/kernel/mm/lru_gen/enabled "${MGLRU_ENABLED}"
  write_if_writable /sys/kernel/mm/numa/demotion_enabled "$(policy_demotion_enabled "${config}")"
  write_if_writable /sys/kernel/mm/numa/demotion_target "$(policy_demotion_target "${config}")"
  if [[ -n "${NUMA_SCAN_SIZE_MB}" ]]; then
    write_if_writable /sys/kernel/mm/numa_balancing/numa_scan_size_mb "${NUMA_SCAN_SIZE_MB}"
  fi
  if [[ -n "${NUMA_SCAN_PERIOD_MIN_MS}" ]]; then
    write_if_writable /sys/kernel/mm/numa_balancing/numa_scan_period_min_ms "${NUMA_SCAN_PERIOD_MIN_MS}"
  fi
  if [[ -n "${NUMA_SCAN_PERIOD_MAX_MS}" ]]; then
    write_if_writable /sys/kernel/mm/numa_balancing/numa_scan_period_max_ms "${NUMA_SCAN_PERIOD_MAX_MS}"
  fi
  if [[ -n "${NUMA_SCAN_DELAY_MS}" ]]; then
    write_if_writable /sys/kernel/mm/numa_balancing/numa_scan_delay_ms "${NUMA_SCAN_DELAY_MS}"
  fi
  write_requested_knob /sys/kernel/mm/numa_balancing/local_fault_rate 0
  write_requested_knob /sys/kernel/mm/numa_balancing/local_fault_scan_period_ms "${LOCAL_FAULT_SCAN_PERIOD_MS}"
  write_requested_knob /sys/kernel/mm/numa_balancing/local_fault_scan_size_mb "${LOCAL_FAULT_SCAN_SIZE_MB}"
  write_if_writable "${MIGRATION_ENABLED_PATH}" "$(policy_migration_enabled "${config}")"
  if [[ -n "${THP_MODE}" ]]; then
    write_if_writable /sys/kernel/mm/transparent_hugepage/enabled "${THP_MODE}"
  fi
  if [[ -n "${THP_DEFRAG}" ]]; then
    write_if_writable /sys/kernel/mm/transparent_hugepage/defrag "${THP_DEFRAG}"
  fi
}

disable_swap_if_requested() {
  if [[ "${DISABLE_SWAP}" != "1" ]]; then
    return 0
  fi
  if swapon --noheadings --show=NAME 2>/dev/null | grep -q .; then
    log "disable swap before workload"
    swapoff -a || log "warning: swapoff -a failed"
  fi
}

nodelist_has_node() {
  local list="$1" want="$2" part start end
  list="${list//,/ }"
  for part in ${list}; do
    if [[ "${part}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      if ((want >= start && want <= end)); then
        return 0
      fi
    elif [[ "${part}" == "${want}" ]]; then
      return 0
    fi
  done
  return 1
}

verify_memory_tier_split() {
  local tier list has0 has1 saw0=0 saw1=0
  for tier in /sys/devices/virtual/memory_tiering/memory_tier*; do
    [[ -d "${tier}" ]] || continue
    list="$(cat "${tier}/nodelist" 2>/dev/null || true)"
    has0=0
    has1=0
    if nodelist_has_node "${list}" 0; then
      has0=1
      saw0=1
    fi
    if nodelist_has_node "${list}" 1; then
      has1=1
      saw1=1
    fi
    if [[ "${has0}" == "1" && "${has1}" == "1" ]]; then
      printf 'node0 and node1 are in the same memory tier: %s=%s\n' "$(basename "${tier}")" "${list}" >&2
      return 78
    fi
  done
  if [[ "${saw0}" != "1" || "${saw1}" != "1" ]]; then
    printf 'memory tier split is incomplete: saw_node0=%s saw_node1=%s\n' "${saw0}" "${saw1}" >&2
    return 78
  fi
}

verify_required_state() {
  local actual target expected_demotion expected_migration expected_numa
  [[ "${VERIFY_REQUIRED_STATE}" == "1" ]] || return 0

  expected_numa="$(policy_numa_value "${CONFIG}")"
  actual="$(tr -d '[:space:]' < /proc/sys/kernel/numa_balancing)"
  if [[ "${actual}" != "${expected_numa}" ]]; then
    printf 'unexpected numa_balancing: expected=%s actual=%s\n' "${expected_numa}" "${actual}" >&2
    return 78
  fi

  expected_migration="$(policy_migration_enabled "${CONFIG}")"
  actual="$(tr -d '[:space:]' < "${MIGRATION_ENABLED_PATH}")"
  if [[ "${actual}" != "${expected_migration}" ]]; then
    printf 'unexpected migration_enabled: expected=%s actual=%s\n' "${expected_migration}" "${actual}" >&2
    return 78
  fi

  if [[ ! -r /sys/kernel/mm/lru_gen/enabled ]]; then
    printf 'missing /sys/kernel/mm/lru_gen/enabled\n' >&2
    return 78
  fi
  actual="$(tr -d '[:space:]' < /sys/kernel/mm/lru_gen/enabled)"
  if [[ "${actual}" != "${MGLRU_ENABLED}" ]]; then
    printf 'unexpected MGLRU state: expected=%s actual=%s\n' "${MGLRU_ENABLED}" "${actual}" >&2
    return 78
  fi

  actual="$(tr -d '[:space:]' < /sys/kernel/mm/numa_balancing/numa_scan_size_mb)"
  if [[ "${actual}" != "${NUMA_SCAN_SIZE_MB}" ]]; then
    printf 'unexpected NUMA scan size: expected=%s actual=%s\n' "${NUMA_SCAN_SIZE_MB}" "${actual}" >&2
    return 78
  fi

  actual="$(tr -d '[:space:]' < /sys/kernel/mm/numa_balancing/local_fault_scan_size_mb)"
  if [[ "${actual}" != "${LOCAL_FAULT_SCAN_SIZE_MB}" ]]; then
    printf 'unexpected local fault scan size: expected=%s actual=%s\n' "${LOCAL_FAULT_SCAN_SIZE_MB}" "${actual}" >&2
    return 78
  fi

  actual="$(tr -d '[:space:]' < /sys/kernel/mm/numa_balancing/local_fault_rate)"
  if [[ "${actual}" != "0" ]]; then
    printf 'unexpected baseline local fault rate: expected=0 actual=%s\n' "${actual}" >&2
    return 78
  fi

  expected_demotion="$(policy_demotion_enabled "${CONFIG}")"
  if [[ -r /sys/kernel/mm/numa/demotion_enabled ]]; then
    actual="$(tr -d '[:space:]' < /sys/kernel/mm/numa/demotion_enabled)"
    if [[ "${actual}" != "${expected_demotion}" ]]; then
      printf 'unexpected demotion_enabled: expected=%s actual=%s\n' "${expected_demotion}" "${actual}" >&2
      return 78
    fi
  fi

  if [[ "${expected_demotion}" == "true" ]]; then
    if [[ ! -r /sys/kernel/mm/numa/demotion_target ]]; then
      printf 'missing /sys/kernel/mm/numa/demotion_target\n' >&2
      return 78
    fi
    target="$(cat /sys/kernel/mm/numa/demotion_target 2>/dev/null | tr '\n' ' ')"
    if [[ "${target}" != *"0 1"* ]]; then
      printf 'unexpected demotion_target: expected to contain "0 1", actual=%s\n' "${target}" >&2
      return 78
    fi
  fi

  if [[ -n "${THP_MODE}" ]]; then
    if [[ ! -r /sys/kernel/mm/transparent_hugepage/enabled ]]; then
      printf 'missing /sys/kernel/mm/transparent_hugepage/enabled\n' >&2
      return 78
    fi
    actual="$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true)"
    if [[ "${actual}" != *"[${THP_MODE}]"* ]]; then
      printf 'unexpected THP enabled state: expected=%s actual=%s\n' "${THP_MODE}" "${actual}" >&2
      return 78
    fi
  fi

  if [[ -n "${THP_DEFRAG}" && -r /sys/kernel/mm/transparent_hugepage/defrag ]]; then
    actual="$(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true)"
    if [[ "${actual}" != *"[${THP_DEFRAG}]"* ]]; then
      printf 'unexpected THP defrag state: expected=%s actual=%s\n' "${THP_DEFRAG}" "${actual}" >&2
      return 78
    fi
  fi

  verify_memory_tier_split
}

require_controller_environment() {
  need_exec_path "${CONTROLLER_RUNNER}" || return $?
  need_readable_path /sys/kernel/mm/numa_balancing/fault_latency_quantiles || return $?
  need_readable_path /sys/kernel/mm/numa_balancing/remote_scan_cycles || return $?
  need_writable_path /sys/kernel/mm/numa_balancing/local_fault_window || return $?
  need_writable_path /sys/kernel/mm/numa_balancing/local_fault_rate || return $?
  need_writable_path /sys/kernel/mm/numa_balancing/local_fault_scan_period_ms || return $?
  need_writable_path /sys/kernel/mm/numa_balancing/local_fault_scan_size_mb || return $?
  need_writable_path "${MIGRATION_ENABLED_PATH}" || return $?
}

snapshot() {
  local tag="$1"
  {
    printf 'numa_balancing=%s\n' "$(read_file /proc/sys/kernel/numa_balancing)"
    printf 'migration_enabled=%s\n' "$(read_file "${MIGRATION_ENABLED_PATH}")"
    printf 'lru_gen_enabled=%s\n' "$(read_file /sys/kernel/mm/lru_gen/enabled)"
    printf 'demotion_enabled=%s\n' "$(read_file /sys/kernel/mm/numa/demotion_enabled)"
    printf 'demotion_target=%s\n' "$(read_file /sys/kernel/mm/numa/demotion_target | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    printf 'thp_enabled=%s\n' "$(read_file /sys/kernel/mm/transparent_hugepage/enabled | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    printf 'thp_defrag=%s\n' "$(read_file /sys/kernel/mm/transparent_hugepage/defrag | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    printf 'scan_size_mb=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/numa_scan_size_mb)"
    printf 'scan_period_min_ms=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/numa_scan_period_min_ms)"
    printf 'scan_period_max_ms=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/numa_scan_period_max_ms)"
    printf 'scan_delay_ms=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/numa_scan_delay_ms)"
    printf 'local_fault_rate=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/local_fault_rate)"
    printf 'local_fault_scan_size_mb=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/local_fault_scan_size_mb)"
    printf 'local_fault_scan_period_ms=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/local_fault_scan_period_ms)"
  } > "${OUTDIR}/${tag}.meta"
  cp /proc/vmstat "${OUTDIR}/${tag}.vmstat" 2>/dev/null || true
}

read_vmstat_value() {
  local key="$1"
  awk -v key="${key}" '
    $1 == key {
      print $2
      found = 1
      exit
    }
    END {
      if (!found) {
        print 0
      }
    }
  ' /proc/vmstat 2>/dev/null || printf '0\n'
}

drop_caches() {
  if [[ "${DROP_GUEST_CACHES}" == "1" ]]; then
    sync || true
    write_if_writable /proc/sys/vm/drop_caches 3
  fi
  if [[ "${COMPACT_GUEST_MEMORY}" == "1" ]]; then
    write_if_writable /proc/sys/vm/compact_memory 1
  fi
}

write_status() {
  local rc="$1" elapsed="$2" start_utc="$3" end_utc="$4"
  local timed_out="${5:-0}" oom_before="${6:-}" oom_after="${7:-}" oom_delta="${8:-}" oom_confirmed="${9:-0}"
  {
    printf 'returncode=%s\n' "${rc}"
    printf 'elapsed_s=%s\n' "${elapsed}"
    printf 'start_utc=%s\n' "${start_utc}"
    printf 'end_utc=%s\n' "${end_utc}"
    printf 'timeout_sec=%s\n' "${TIMEOUT_SEC}"
    printf 'timeout_kill_after_sec=%s\n' "${TIMEOUT_KILL_AFTER_SEC}"
    printf 'timed_out=%s\n' "${timed_out}"
    printf 'oom_kill_before=%s\n' "${oom_before}"
    printf 'oom_kill_after=%s\n' "${oom_after}"
    printf 'oom_kill_delta=%s\n' "${oom_delta}"
    printf 'oom_confirmed=%s\n' "${oom_confirmed}"
  } > "${OUTDIR}/status.txt"
}

run_case() {
  local numa_value
  local -a place cmd
  local cmd_display placement_display start_s end_s elapsed_s start_utc end_utc status
  local timed_out=0 oom_kill_before=0 oom_kill_after=0 oom_kill_delta=0 oom_confirmed=0
  local controller_enabled=0 controller_out="" workload_command_quoted=""

  numa_value="$(policy_numa_value "${CONFIG}")"
  set_common_knobs "${CONFIG}"
  disable_swap_if_requested
  write_if_writable /proc/sys/kernel/numa_balancing "${numa_value}"
  set +e
  verify_required_state
  status=$?
  set -e
  drop_caches

  snapshot before

  if [[ "${status}" != "0" ]]; then
    printf 'required runtime state validation failed\n' > "${OUTDIR}/failure.reason"
    printf '%s\n' "${status}" > "${OUTDIR}/exit.status"
    write_status "${status}" 0 "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    snapshot after
    return "${status}"
  fi

  set +e
  set_workload_cmd
  status=$?
  set -e
  if [[ "${status}" != "0" ]]; then
    printf '%s\n' "${status}" > "${OUTDIR}/exit.status"
    write_status "${status}" 0 "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    snapshot after
    return "${status}"
  fi
  if is_controller_config "${CONFIG}"; then
    controller_enabled=1
    set +e
    require_controller_environment
    status=$?
    set -e
    if [[ "${status}" != "0" ]]; then
      printf '%s\n' "${status}" > "${OUTDIR}/exit.status"
      write_status "${status}" 0 "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      snapshot after
      return "${status}"
    fi
    printf -v workload_command_quoted '%q ' "${WORKLOAD_CMD[@]}"
    controller_out="${OUTDIR}/controller"
    cmd=(
      env
      "OUTDIR=${controller_out}"
      "RUN_NAME=${CONFIG}-${WORKLOAD}"
      "WORKLOAD_COMMAND=${workload_command_quoted}"
      "CPU_NODE=${CPU_NODE}"
      "OMP_THREADS=${OMP_THREADS}"
      "WINDOW_SEC=${WINDOW_SEC}"
      "CYCLE_WINDOW_MIN_SEC=${CYCLE_WINDOW_MIN_SEC}"
      "CYCLE_WINDOW_MAX_SEC=${CYCLE_WINDOW_MAX_SEC}"
      "LOCAL_RATE=${LOCAL_RATE}"
      "LOCAL_FAULT_SCAN_PERIOD_MS=${LOCAL_FAULT_SCAN_PERIOD_MS}"
      "LOCAL_FAULT_SCAN_SIZE_MB=${LOCAL_FAULT_SCAN_SIZE_MB}"
      "MIN_LOCAL_PAGES=${MIN_LOCAL_PAGES}"
      "MIN_REMOTE_PAGES=${MIN_REMOTE_PAGES}"
      "START_CONSECUTIVE=${START_CONSECUTIVE}"
      "START_CAPACITY_MARGIN_PCT=${START_CAPACITY_MARGIN_PCT}"
      "STOP_CAPACITY_RATIO_THRESHOLD=${STOP_CAPACITY_RATIO_THRESHOLD}"
      "P75_STAGNATION_REQUIRED_DECREASE_PCT=${P75_STAGNATION_REQUIRED_DECREASE_PCT}"
      "P75_STAGNATION_REQUIRED_WINDOWS=${P75_STAGNATION_REQUIRED_WINDOWS}"
      "P75_STAGNATION_RESTART_DEGRADATION_PCT=${P75_STAGNATION_RESTART_DEGRADATION_PCT}"
      "P75_STAGNATION_RESTART_REQUIRED_WINDOWS=${P75_STAGNATION_RESTART_REQUIRED_WINDOWS}"
      "REMOTE_RESTART_IMPROVEMENT_PCT=${REMOTE_RESTART_IMPROVEMENT_PCT}"
      "LOCAL_NODE=${LOCAL_NODE}"
      "REMOTE_NODE=${REMOTE_NODE}"
      "MIGRATION_ENABLED_PATH=${MIGRATION_ENABLED_PATH}"
      "MGLRU_ENABLED=${MGLRU_ENABLED}"
      "DEMOTION_ENABLED=$(policy_demotion_enabled "${CONFIG}")"
      "DEMOTION_TARGET=$(policy_demotion_target "${CONFIG}")"
      "NUMA_SCAN_SIZE_MB=${NUMA_SCAN_SIZE_MB}"
      "NUMA_SCAN_PERIOD_MIN_MS=${NUMA_SCAN_PERIOD_MIN_MS}"
      "NUMA_SCAN_PERIOD_MAX_MS=${NUMA_SCAN_PERIOD_MAX_MS}"
      "NUMA_SCAN_DELAY_MS=${NUMA_SCAN_DELAY_MS}"
      "THP_MODE=${THP_MODE}"
      "THP_DEFRAG=${THP_DEFRAG}"
      "${CONTROLLER_RUNNER}"
    )
    placement_display="controller_inner_numactl --cpunodebind=${CPU_NODE}"
  else
    mapfile -d '' -t place < <(placement_args "${CONFIG}")
    cmd=("${place[@]}" "${WORKLOAD_CMD[@]}")
    printf -v placement_display '%q ' "${place[@]}"
  fi
  printf -v cmd_display '%q ' "${cmd[@]}"

  {
    printf 'config=%s\n' "${CONFIG}"
    printf 'workload=%s\n' "${WORKLOAD}"
    printf 'local_size_gib=%s\n' "${LOCAL_SIZE_GIB}"
    printf 'workload_command_kind=%s\n' "${WORKLOAD_COMMAND_KIND}"
    printf 'numa_balancing=%s\n' "${numa_value}"
    printf 'demotion_enabled=%s\n' "$(policy_demotion_enabled "${CONFIG}")"
    printf 'demotion_target=%s\n' "$(policy_demotion_target "${CONFIG}")"
    printf 'numa_scan_size_mb=%s\n' "${NUMA_SCAN_SIZE_MB}"
    printf 'numa_scan_period_min_ms=%s\n' "${NUMA_SCAN_PERIOD_MIN_MS}"
    printf 'numa_scan_period_max_ms=%s\n' "${NUMA_SCAN_PERIOD_MAX_MS}"
    printf 'numa_scan_delay_ms=%s\n' "${NUMA_SCAN_DELAY_MS}"
    printf 'local_fault_scan_period_ms_override=%s\n' "${LOCAL_FAULT_SCAN_PERIOD_MS}"
    printf 'local_fault_scan_size_mb_override=%s\n' "${LOCAL_FAULT_SCAN_SIZE_MB}"
    printf 'migration_enabled=%s\n' "$(read_file "${MIGRATION_ENABLED_PATH}")"
    printf 'disable_swap=%s\n' "${DISABLE_SWAP}"
    printf 'placement=%s\n' "${placement_display}"
    printf 'command=%s\n' "${cmd_display}"
    printf 'controller_enabled=%s\n' "${controller_enabled}"
    if [[ "${controller_enabled}" == "1" ]]; then
      printf 'controller_dir=%s\n' "${CONTROLLER_DIR}"
      printf 'controller_runner=%s\n' "${CONTROLLER_RUNNER}"
      printf 'controller_outdir=%s\n' "${controller_out}"
      printf 'controller_csv=%s\n' "${controller_out}/controller.csv"
      printf 'controller_workload_command=%s\n' "${workload_command_quoted}"
      printf 'controller_policy=%s\n' "${CONTROLLER_POLICY}"
      printf 'controller_csv_schema=%s\n' "${CONTROLLER_POLICY}"
      printf 'controller_window_sec=%s\n' "${WINDOW_SEC}"
      printf 'controller_cycle_window_min_sec=%s\n' "${CYCLE_WINDOW_MIN_SEC}"
      printf 'controller_cycle_window_max_sec=%s\n' "${CYCLE_WINDOW_MAX_SEC}"
      printf 'controller_local_rate=%s\n' "${LOCAL_RATE}"
      printf 'controller_local_fault_scan_period_ms=%s\n' "${LOCAL_FAULT_SCAN_PERIOD_MS}"
      printf 'controller_local_fault_scan_size_mb=%s\n' "${LOCAL_FAULT_SCAN_SIZE_MB}"
      printf 'controller_min_local_pages=%s\n' "${MIN_LOCAL_PAGES}"
      printf 'controller_min_remote_pages=%s\n' "${MIN_REMOTE_PAGES}"
      printf 'controller_start_consecutive=%s\n' "${START_CONSECUTIVE}"
      printf 'controller_start_capacity_margin_pct=%s\n' "${START_CAPACITY_MARGIN_PCT}"
      printf 'controller_stop_capacity_ratio_threshold=%s\n' "${STOP_CAPACITY_RATIO_THRESHOLD}"
      printf 'controller_p75_stagnation_required_decrease_pct=%s\n' "${P75_STAGNATION_REQUIRED_DECREASE_PCT}"
      printf 'controller_p75_stagnation_required_windows=%s\n' "${P75_STAGNATION_REQUIRED_WINDOWS}"
      printf 'controller_p75_stagnation_restart_degradation_pct=%s\n' "${P75_STAGNATION_RESTART_DEGRADATION_PCT}"
      printf 'controller_p75_stagnation_restart_required_windows=%s\n' "${P75_STAGNATION_RESTART_REQUIRED_WINDOWS}"
      printf 'controller_remote_restart_improvement_pct=%s\n' "${REMOTE_RESTART_IMPROVEMENT_PCT}"
      printf 'controller_local_node=%s\n' "${LOCAL_NODE}"
      printf 'controller_remote_node=%s\n' "${REMOTE_NODE}"
      printf 'controller_migration_enabled_path=%s\n' "${MIGRATION_ENABLED_PATH}"
    fi
    printf 'cpu_node=%s\n' "${CPU_NODE}"
    printf 'omp_threads=%s\n' "${OMP_THREADS}"
    printf 'timeout_sec=%s\n' "${TIMEOUT_SEC}"
    printf 'timeout_kill_after_sec=%s\n' "${TIMEOUT_KILL_AFTER_SEC}"
    printf 'drop_guest_caches=%s\n' "${DROP_GUEST_CACHES}"
    printf 'compact_guest_memory=%s\n' "${COMPACT_GUEST_MEMORY}"
    printf 'thp_mode=%s\n' "${THP_MODE}"
    printf 'thp_defrag=%s\n' "${THP_DEFRAG}"
    printf 'realworld_size_profile=%s\n' "${REALWORLD_SIZE_PROFILE}"
    case "${WORKLOAD}" in
      pr|gapbs_pr|bc|gapbs_bc)
        printf 'gapbs_graph_mode=generated\n'
        printf 'gapbs_graph_scale=%s\n' "${GAPBS_GRAPH_SCALE}"
        printf 'gapbs_graph_path=generated:g%s\n' "${GAPBS_GRAPH_SCALE}"
        printf 'graph=generated:g%s\n' "${GAPBS_GRAPH_SCALE}"
        printf 'graph_build_included=1\n'
        printf 'pr_trials=%s\n' "${PR_TRIALS}"
        printf 'bc_trials=%s\n' "${BC_TRIALS}"
        printf 'pr_iterations=%s\n' "${PR_ITERATIONS}"
        printf 'bc_iterations=%s\n' "${BC_ITERATIONS}"
        printf 'pr_tolerance=%s\n' "${PR_TOLERANCE}"
        ;;
      silo)
        printf 'silo_scale_factor=%s\n' "${SILO_SCALE_FACTOR}"
        printf 'silo_ops_per_worker=%s\n' "${SILO_OPS_PER_WORKER}"
        printf 'silo_threads=%s\n' "${SILO_THREADS:-${OMP_THREADS}}"
        printf 'silo_zipf_theta=%s\n' "${SILO_ZIPF_THETA}"
        printf 'silo_zipf_reverse=%s\n' "${SILO_ZIPF_REVERSE}"
        printf 'silo_workload_mix=%s\n' "${SILO_WORKLOAD_MIX}"
        ;;
      liblinear)
        printf 'liblinear_dataset=%s\n' "${LIBLINEAR_DATASET}"
        printf 'liblinear_solver=%s\n' "${LIBLINEAR_SOLVER}"
        printf 'liblinear_threads=%s\n' "${LIBLINEAR_THREADS:-${OMP_THREADS}}"
        ;;
      *)
        printf 'graph=%s\n' "${GRAPH}"
        ;;
    esac
  } > "${OUTDIR}/run.config"

  log "starting config=${CONFIG} workload=${WORKLOAD}: ${cmd_display}"
  start_s="$(date +%s)"
  start_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n' "${start_s}" > "${OUTDIR}/workload.start.epoch"
  printf '%s\n' "${start_utc}" > "${OUTDIR}/workload.start.utc"
  oom_kill_before="$(read_vmstat_value oom_kill)"
  set +e
  (
    export OMP_NUM_THREADS="${OMP_THREADS}"
    export OMP_PROC_BIND=true
    export OMP_PLACES=cores
    export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-4}"
    export BENCHMARK_DIR TOOLS_DIR WORKDIR REALWORLD_SIZE_PROFILE
    /usr/bin/time -v -o "${OUTDIR}/time.txt" \
      timeout --signal=TERM --kill-after="${TIMEOUT_KILL_AFTER_SEC}s" "${TIMEOUT_SEC}" "${cmd[@]}" \
      > "${OUTDIR}/workload.stdout.log" 2> "${OUTDIR}/workload.stderr.log"
  )
  status=$?
  set -e
  end_s="$(date +%s)"
  end_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  elapsed_s=$((end_s - start_s))
  oom_kill_after="$(read_vmstat_value oom_kill)"
  oom_kill_delta=$((oom_kill_after - oom_kill_before))
  ((oom_kill_delta < 0)) && oom_kill_delta=0
  [[ "${status}" == "124" ]] && timed_out=1
  ((oom_kill_delta > 0)) && oom_confirmed=1
  dmesg --ctime > "${OUTDIR}/dmesg.after.log" 2>&1 || true

  printf '%s\n' "${status}" > "${OUTDIR}/exit.status"
  write_status "${status}" "${elapsed_s}" "${start_utc}" "${end_utc}" \
    "${timed_out}" "${oom_kill_before}" "${oom_kill_after}" "${oom_kill_delta}" "${oom_confirmed}"
  snapshot after
  log "finished config=${CONFIG} workload=${WORKLOAD} status=${status} elapsed_s=${elapsed_s}"
  return "${status}"
}

run_case
