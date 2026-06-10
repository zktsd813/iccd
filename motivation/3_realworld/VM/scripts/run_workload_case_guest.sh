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
GRAPH="${GRAPH:-/mnt/data/gapbs/kron_g29.sg}"
WORKDIR="${WORKDIR:-/root/realworld-work}"
CPU_NODE="${CPU_NODE:-0}"
OMP_THREADS="${OMP_THREADS:-32}"
TIMEOUT_SEC="${TIMEOUT_SEC:-21600}"
SAMPLE_INTERVAL_SEC="${SAMPLE_INTERVAL_SEC:-5}"
MGLRU_ENABLED="${MGLRU_ENABLED:-0x0007}"
DEMOTION_ENABLED="${DEMOTION_ENABLED:-true}"
DEMOTION_TARGET="${DEMOTION_TARGET:-0 1}"
NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-}"
NUMA_SCAN_PERIOD_MIN_MS="${NUMA_SCAN_PERIOD_MIN_MS:-}"
LOCAL_FAULT_RATE="${LOCAL_FAULT_RATE:-}"
REMOTE_FAULT_RATE="${REMOTE_FAULT_RATE:-}"
LOCAL_FAULT_SCAN_PERIOD_MS="${LOCAL_FAULT_SCAN_PERIOD_MS:-}"
LOCAL_FAULT_SCAN_SIZE_MB="${LOCAL_FAULT_SCAN_SIZE_MB:-}"
REMOTE_FAULT_SCAN_PERIOD_MS="${REMOTE_FAULT_SCAN_PERIOD_MS:-}"
REMOTE_FAULT_SCAN_SIZE_MB="${REMOTE_FAULT_SCAN_SIZE_MB:-}"
THP_MODE="${THP_MODE:-}"
THP_DEFRAG="${THP_DEFRAG:-${THP_MODE}}"
REALWORLD_SIZE_PROFILE="${REALWORLD_SIZE_PROFILE:-rss60}"
VERIFY_REQUIRED_STATE="${VERIFY_REQUIRED_STATE:-1}"
LOCAL_SIZE_GIB="${LOCAL_SIZE_GIB:-}"
TRACE_BC_TRIAL_PROMOTIONS="${TRACE_BC_TRIAL_PROMOTIONS:-0}"
CONTROLLER_DIR="${CONTROLLER_DIR:-/root/design/fault_bucket_controller}"
CONTROLLER_RUNNER="${CONTROLLER_RUNNER:-${CONTROLLER_DIR}/run_guest.sh}"
CONTROLLER_WINDOW_SEC="${CONTROLLER_WINDOW_SEC:-5}"
CONTROLLER_LOCAL_RATE="${CONTROLLER_LOCAL_RATE:-5}"
CONTROLLER_REMOTE_RATE="${CONTROLLER_REMOTE_RATE:-5}"
CONTROLLER_LOCAL_FAULT_SCAN_PERIOD_MS="${CONTROLLER_LOCAL_FAULT_SCAN_PERIOD_MS:-1000}"
CONTROLLER_LOCAL_FAULT_SCAN_SIZE_MB="${CONTROLLER_LOCAL_FAULT_SCAN_SIZE_MB:-256}"
CONTROLLER_REMOTE_FAULT_SCAN_PERIOD_MS="${CONTROLLER_REMOTE_FAULT_SCAN_PERIOD_MS:-${CONTROLLER_LOCAL_FAULT_SCAN_PERIOD_MS}}"
CONTROLLER_REMOTE_FAULT_SCAN_SIZE_MB="${CONTROLLER_REMOTE_FAULT_SCAN_SIZE_MB:-${CONTROLLER_LOCAL_FAULT_SCAN_SIZE_MB}}"
CONTROLLER_MIN_LOCAL_PAGES="${CONTROLLER_MIN_LOCAL_PAGES:-1024}"
CONTROLLER_MIN_REMOTE_PAGES="${CONTROLLER_MIN_REMOTE_PAGES:-1024}"
CONTROLLER_CONSECUTIVE_EFFECTIVE="${CONTROLLER_CONSECUTIVE_EFFECTIVE:-2}"
CONTROLLER_CONSECUTIVE_NO_IMPROVE="${CONTROLLER_CONSECUTIVE_NO_IMPROVE:-2}"
CONTROLLER_RESTART_REMOTE_SHARE_THRESHOLD="${CONTROLLER_RESTART_REMOTE_SHARE_THRESHOLD:-1.2}"
CONTROLLER_CONSECUTIVE_RESTART="${CONTROLLER_CONSECUTIVE_RESTART:-2}"
CONTROLLER_RESTART_GRACE_WINDOWS="${CONTROLLER_RESTART_GRACE_WINDOWS:-1}"
CONTROLLER_NUMA_BALANCING_ON="${CONTROLLER_NUMA_BALANCING_ON:-2}"
CONTROLLER_NUMA_BALANCING_OFF="${CONTROLLER_NUMA_BALANCING_OFF:-0}"

PR_ITERATIONS="${PR_ITERATIONS:-20}"
PR_TOLERANCE="${PR_TOLERANCE:-1e-4}"
PR_TRIALS="${PR_TRIALS:-8}"
BC_ITERATIONS="${BC_ITERATIONS:-1}"
BC_TRIALS="${BC_TRIALS:-8}"
GAPBS_GRAPH_SCALE="${GAPBS_GRAPH_SCALE:-29}"
GUPS_MEMORY_GB="${GUPS_MEMORY_GB:-64}"
GRAPH500_SCALE="${GRAPH500_SCALE:-28}"
XSBENCH_GRID="${XSBENCH_GRID:-130000}"
XSBENCH_PARTICLES="${XSBENCH_PARTICLES:-90000000}"
SILO_SCALE_FACTOR="${SILO_SCALE_FACTOR:-800000}"
SILO_OPS_PER_WORKER="${SILO_OPS_PER_WORKER:-100000000}"
LIBLINEAR_DATASET="${LIBLINEAR_DATASET:-kdd12}"
LIBLINEAR_SOLVER="${LIBLINEAR_SOLVER:-6}"

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

mount_debugfs() {
  mkdir -p /sys/kernel/debug
  mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug || true
}

policy_numa_value() {
  case "$1" in
    migration_on|tiering_0x2|controller_0x2) printf '2\n' ;;
    tpp|tpp_0x4) printf '4\n' ;;
    migration_off|all_local|all_slow) printf '0\n' ;;
    *) echo "unknown config: $1" >&2; return 2 ;;
  esac
}

policy_demotion_enabled() {
  case "$1" in
    migration_off|all_local|all_slow) printf 'false\n' ;;
    migration_on|tiering_0x2|tpp|tpp_0x4|controller_0x2) printf 'true\n' ;;
    *) echo "unknown config: $1" >&2; return 2 ;;
  esac
}

policy_demotion_target() {
  case "$1" in
    migration_off|all_local|all_slow) printf '%s\n' "${DEMOTION_TARGET_OFF:-0 -1}" ;;
    migration_on|tiering_0x2|tpp|tpp_0x4|controller_0x2) printf '%s\n' "${DEMOTION_TARGET}" ;;
    *) echo "unknown config: $1" >&2; return 2 ;;
  esac
}

placement_args() {
  case "$1" in
    migration_on|tiering_0x2|migration_off|tpp|tpp_0x4|controller_0x2)
      printf '%s\0' numactl "--cpunodebind=${CPU_NODE}"
      ;;
    all_local)
      printf '%s\0' numactl "--cpunodebind=${CPU_NODE}" --membind=0
      ;;
    all_slow)
      printf '%s\0' numactl "--cpunodebind=${CPU_NODE}" --membind=1
      ;;
    *)
      echo "unknown config: $1" >&2
      return 2
      ;;
  esac
}

is_controller_config() {
  case "$1" in
    controller_0x2) return 0 ;;
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

set_workload_cmd() {
  WORKLOAD_CMD=()
  WORKLOAD_COMMAND_KIND="${WORKLOAD}"

  case "${WORKLOAD}" in
    pr|gapbs_pr)
      need_exec_path "${BENCHMARK_DIR}/gapbs/pr" || return $?
      need_file_path "${GRAPH}" || return $?
      WORKLOAD_CMD=("${BENCHMARK_DIR}/gapbs/pr" -f "${GRAPH}" -i "${PR_ITERATIONS}" -t "${PR_TOLERANCE}" -n "${PR_TRIALS}")
      ;;
    bc|gapbs_bc)
      need_exec_path "${BENCHMARK_DIR}/gapbs/bc" || return $?
      need_file_path "${GRAPH}" || return $?
      if [[ "${TRACE_BC_TRIAL_PROMOTIONS}" == "1" ]]; then
        need_exec_path /root/vm32_realworld/scripts/trace_gapbs_trial_promotions.sh || return $?
        WORKLOAD_CMD=(
          env
          "TRIAL_PROMOTION_OUT=${OUTDIR}/trial_promotion.csv"
          "TRIAL_PROMOTION_RAW_OUT=${OUTDIR}/trial_promotion.raw.log"
          /root/vm32_realworld/scripts/trace_gapbs_trial_promotions.sh
          "${BENCHMARK_DIR}/gapbs/bc" -f "${GRAPH}" -i "${BC_ITERATIONS}" -n "${BC_TRIALS}"
        )
      else
        WORKLOAD_CMD=("${BENCHMARK_DIR}/gapbs/bc" -f "${GRAPH}" -i "${BC_ITERATIONS}" -n "${BC_TRIALS}")
      fi
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
      WORKLOAD_CMD=(
        "${BENCHMARK_DIR}/silo/out-perf.masstree/benchmarks/dbtest"
        --verbose
        --bench ycsb
        --num-threads "${SILO_THREADS:-${OMP_THREADS}}"
        --scale-factor "${SILO_SCALE_FACTOR}"
        "--ops-per-worker=${SILO_OPS_PER_WORKER}"
      )
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
  mount_debugfs
  write_if_writable /sys/kernel/mm/lru_gen/enabled "${MGLRU_ENABLED}"
  write_if_writable /sys/kernel/mm/numa/demotion_enabled "$(policy_demotion_enabled "${config}")"
  write_if_writable /sys/kernel/mm/numa/demotion_target "$(policy_demotion_target "${config}")"
  if [[ -n "${NUMA_SCAN_SIZE_MB}" ]]; then
    write_if_writable /sys/kernel/debug/sched/numa_balancing/scan_size_mb "${NUMA_SCAN_SIZE_MB}"
  fi
  if [[ -n "${NUMA_SCAN_PERIOD_MIN_MS}" ]]; then
    write_if_writable /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms "${NUMA_SCAN_PERIOD_MIN_MS}"
  fi
  write_requested_knob /sys/kernel/mm/numa_balancing/local_fault_rate "${LOCAL_FAULT_RATE}"
  write_requested_knob /sys/kernel/mm/numa_balancing/remote_fault_rate "${REMOTE_FAULT_RATE}"
  write_requested_knob /sys/kernel/mm/numa_balancing/local_fault_scan_period_ms "${LOCAL_FAULT_SCAN_PERIOD_MS}"
  write_requested_knob /sys/kernel/mm/numa_balancing/local_fault_scan_size_mb "${LOCAL_FAULT_SCAN_SIZE_MB}"
  write_requested_knob /sys/kernel/mm/numa_balancing/remote_fault_scan_period_ms "${REMOTE_FAULT_SCAN_PERIOD_MS}"
  write_requested_knob /sys/kernel/mm/numa_balancing/remote_fault_scan_size_mb "${REMOTE_FAULT_SCAN_SIZE_MB}"
  if [[ -n "${THP_MODE}" ]]; then
    write_if_writable /sys/kernel/mm/transparent_hugepage/enabled "${THP_MODE}"
  fi
  if [[ -n "${THP_DEFRAG}" ]]; then
    write_if_writable /sys/kernel/mm/transparent_hugepage/defrag "${THP_DEFRAG}"
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
  local actual target expected_demotion
  [[ "${VERIFY_REQUIRED_STATE}" == "1" ]] || return 0

  if [[ ! -r /sys/kernel/mm/lru_gen/enabled ]]; then
    printf 'missing /sys/kernel/mm/lru_gen/enabled\n' >&2
    return 78
  fi
  actual="$(tr -d '[:space:]' < /sys/kernel/mm/lru_gen/enabled)"
  if [[ "${actual}" != "${MGLRU_ENABLED}" ]]; then
    printf 'unexpected MGLRU state: expected=%s actual=%s\n' "${MGLRU_ENABLED}" "${actual}" >&2
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
  need_readable_path /sys/kernel/mm/numa_balancing/fault_latency_histograms || return $?
  need_writable_path /sys/kernel/mm/numa_balancing/local_fault_window || return $?
  need_writable_path /sys/kernel/mm/numa_balancing/local_fault_rate || return $?
  need_writable_path /sys/kernel/mm/numa_balancing/remote_fault_rate || return $?
  need_writable_path /sys/kernel/mm/numa_balancing/local_fault_scan_period_ms || return $?
  need_writable_path /sys/kernel/mm/numa_balancing/local_fault_scan_size_mb || return $?
  need_writable_path /sys/kernel/mm/numa_balancing/remote_fault_scan_period_ms || return $?
  need_writable_path /sys/kernel/mm/numa_balancing/remote_fault_scan_size_mb || return $?
}

record_memory_tiers() {
  local out="$1"
  {
    for tier in /sys/devices/virtual/memory_tiering/memory_tier*; do
      [[ -d "${tier}" ]] || continue
      printf '%s=' "$(basename "${tier}")"
      cat "${tier}/nodelist" 2>/dev/null || printf 'NA\n'
    done
  } > "${out}" 2>/dev/null || true
}

record_node_meminfo() {
  local out="$1"
  {
    for node in /sys/devices/system/node/node[0-9]*; do
      [[ -d "${node}" ]] || continue
      printf -- '--- %s ---\n' "$(basename "${node}")"
      cat "${node}/meminfo" 2>/dev/null || true
    done
  } > "${out}" 2>/dev/null || true
}

snapshot() {
  local tag="$1"
  {
    printf 'tag=%s\n' "${tag}"
    printf 'date_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'uname=%s\n' "$(uname -a)"
    printf 'cmdline=%s\n' "$(cat /proc/cmdline 2>/dev/null || true)"
    printf 'numa_balancing=%s\n' "$(read_file /proc/sys/kernel/numa_balancing)"
    printf 'lru_gen_enabled=%s\n' "$(read_file /sys/kernel/mm/lru_gen/enabled)"
    printf 'demotion_enabled=%s\n' "$(read_file /sys/kernel/mm/numa/demotion_enabled)"
    printf 'demotion_target=%s\n' "$(read_file /sys/kernel/mm/numa/demotion_target | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    printf 'thp_enabled=%s\n' "$(read_file /sys/kernel/mm/transparent_hugepage/enabled | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    printf 'thp_defrag=%s\n' "$(read_file /sys/kernel/mm/transparent_hugepage/defrag | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    printf 'scan_size_mb=%s\n' "$(read_file /sys/kernel/debug/sched/numa_balancing/scan_size_mb)"
    printf 'scan_period_min_ms=%s\n' "$(read_file /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms)"
    printf 'hot_threshold_ms=%s\n' "$(read_file /sys/kernel/debug/sched/numa_balancing/hot_threshold_ms)"
    printf 'local_fault_rate=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/local_fault_rate)"
    printf 'remote_fault_rate=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/remote_fault_rate)"
    printf 'local_fault_scan_size_mb=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/local_fault_scan_size_mb)"
    printf 'local_fault_scan_period_ms=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/local_fault_scan_period_ms)"
    printf 'remote_fault_scan_size_mb=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/remote_fault_scan_size_mb)"
    printf 'remote_fault_scan_period_ms=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/remote_fault_scan_period_ms)"
  } > "${OUTDIR}/${tag}.meta"
  numactl -H > "${OUTDIR}/${tag}.numactl" 2>&1 || true
  cp /proc/vmstat "${OUTDIR}/${tag}.vmstat" 2>/dev/null || true
  cp /proc/zoneinfo "${OUTDIR}/${tag}.zoneinfo" 2>/dev/null || true
  cat /sys/kernel/mm/numa_balancing/local_fault_stats > "${OUTDIR}/${tag}.local_fault_stats" 2>/dev/null || true
  cat /sys/kernel/mm/numa_balancing/remote_fault_stats > "${OUTDIR}/${tag}.remote_fault_stats" 2>/dev/null || true
  cat /sys/kernel/mm/numa_balancing/fault_latency_histograms > "${OUTDIR}/${tag}.fault_latency_histograms" 2>/dev/null || true
  cat /sys/kernel/debug/sched/numa_balancing/promotion_thresholds > "${OUTDIR}/${tag}.promotion_thresholds" 2>/dev/null || true
  record_memory_tiers "${OUTDIR}/${tag}.memory_tiers"
  record_node_meminfo "${OUTDIR}/${tag}.node_meminfo"
}

collect_descendants() {
  local pid="$1" child
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 0
  printf '%s\n' "${pid}"
  while read -r child; do
    [[ -n "${child}" ]] || continue
    collect_descendants "${child}"
  done < <(pgrep -P "${pid}" 2>/dev/null || true)
}

server_pid_files() {
  case "${WORKLOAD}" in
    redis_uniform|redis_ycsb_a)
      printf '%s\n' "${WORKDIR}/redis-${REDIS_PORT:-6380}/redis.pid"
      ;;
    memcached_ycsb_uniform)
      printf '%s\n' "${WORKDIR}/memcached-${MEMCACHED_PORT:-11211}.pid"
      ;;
  esac
}

collect_sample_pids() {
  local root_pid="$1" pidfile pid
  {
    collect_descendants "${root_pid}"
    while read -r pidfile; do
      [[ -n "${pidfile}" && -r "${pidfile}" ]] || continue
      pid="$(cat "${pidfile}" 2>/dev/null || true)"
      [[ "${pid}" =~ ^[0-9]+$ ]] || continue
      collect_descendants "${pid}"
    done < <(server_pid_files)
  } | awk '!seen[$0]++'
}

aggregate_numa_maps() {
  local -a pids=("$@")
  local -a files=()
  local pid
  for pid in "${pids[@]}"; do
    [[ -r "/proc/${pid}/numa_maps" ]] || continue
    files+=("/proc/${pid}/numa_maps")
  done
  if ((${#files[@]} == 0)); then
    printf '0,0'
    return 0
  fi
  awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^N[0-9]+=/) {
          split($i, a, "=")
          pages[a[1]] += a[2]
        }
      }
    }
    END {
      printf "%d,%d", pages["N0"] + 0, pages["N1"] + 0
    }
  ' "${files[@]}" 2>/dev/null || printf '0,0'
}

node_mem_csv_fields() {
  local node="$1"
  local file="/sys/devices/system/node/node${node}/meminfo"
  if [[ ! -r "${file}" ]]; then
    printf '0,0,0'
    return 0
  fi
  awk -v node="${node}" '
    $1 == "Node" && $2 == node && $3 == "MemTotal:" { total = $4 }
    $1 == "Node" && $2 == node && $3 == "MemFree:" { free = $4 }
    END {
      used = total - free
      if (used < 0) used = 0
      printf "%.6f,%.6f,%.6f", total / 1048576, free / 1048576, used / 1048576
    }
  ' "${file}" 2>/dev/null || printf '0,0,0'
}

sample_memory() {
  local root_pid="$1" out="$2"
  local start_s now elapsed pids joined numa n0_pages n1_pages n0_gib n1_gib node0 node1
  start_s="$(date +%s)"
  printf 'timestamp,elapsed_s,pids,N0_pages,N1_pages,N0_GiB,N1_GiB,node0_total_GiB,node0_free_GiB,node0_used_GiB,node1_total_GiB,node1_free_GiB,node1_used_GiB\n' > "${out}"
  while kill -0 "${root_pid}" 2>/dev/null; do
    now="$(date +%s)"
    elapsed=$((now - start_s))
    mapfile -t pids < <(collect_sample_pids "${root_pid}")
    joined="$(IFS=';'; printf '%s' "${pids[*]:-}")"
    numa="$(aggregate_numa_maps "${pids[@]:-}")"
    n0_pages="${numa%%,*}"
    n1_pages="${numa#*,}"
    n0_gib="$(awk -v p="${n0_pages}" 'BEGIN { printf "%.6f", p * 4096 / 1024 / 1024 / 1024 }')"
    n1_gib="$(awk -v p="${n1_pages}" 'BEGIN { printf "%.6f", p * 4096 / 1024 / 1024 / 1024 }')"
    node0="$(node_mem_csv_fields 0)"
    node1="$(node_mem_csv_fields 1)"
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${elapsed}" "${joined}" \
      "${n0_pages}" "${n1_pages}" "${n0_gib}" "${n1_gib}" "${node0}" "${node1}" \
      >> "${out}"
    sleep "${SAMPLE_INTERVAL_SEC}"
  done
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

append_promotion_sample() {
  local out="$1" start_s="$2" tag="${3:-sample}"
  local now elapsed
  now="$(date +%s.%N)"
  elapsed="$(awk -v now="${now}" -v start="${start_s}" 'BEGIN { printf "%.6f", now - start }')"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" \
    "${elapsed}" \
    "${tag}" \
    "$(read_vmstat_value pgpromote_success)" \
    "$(read_vmstat_value pgpromote_candidate)" \
    "$(read_vmstat_value pgpromote_candidate_nrl)" \
    "$(read_vmstat_value pgpromote_candidate_demoted)" \
    "$(read_vmstat_value numa_hint_faults)" \
    "$(read_vmstat_value pgdemote_kswapd)" \
    "$(read_vmstat_value pgdemote_direct)" \
    >> "${out}"
}

sample_promotion() {
  local root_pid="$1" out="$2"
  local start_s
  start_s="$(date +%s.%N)"
  printf '%s\n' "${start_s}" > "${out}.start"
  printf 'timestamp,elapsed_s,tag,pgpromote_success,pgpromote_candidate,pgpromote_candidate_nrl,pgpromote_candidate_demoted,numa_hint_faults,pgdemote_kswapd,pgdemote_direct\n' > "${out}"
  while kill -0 "${root_pid}" 2>/dev/null; do
    append_promotion_sample "${out}" "${start_s}" sample
    sleep "${SAMPLE_INTERVAL_SEC}"
  done
  append_promotion_sample "${out}" "${start_s}" exit
}

drop_caches() {
  sync || true
  write_if_writable /proc/sys/vm/drop_caches 3
  write_if_writable /proc/sys/vm/compact_memory 1
}

write_status() {
  local rc="$1" elapsed="$2" start_utc="$3" end_utc="$4"
  {
    printf 'returncode=%s\n' "${rc}"
    printf 'elapsed_s=%s\n' "${elapsed}"
    printf 'start_utc=%s\n' "${start_utc}"
    printf 'end_utc=%s\n' "${end_utc}"
  } > "${OUTDIR}/status.txt"
}

run_case() {
  local numa_value
  local -a place cmd
  local cmd_display placement_display start_s end_s elapsed_s start_utc end_utc status
  local controller_enabled=0 controller_out="" workload_command_quoted=""

  numa_value="$(policy_numa_value "${CONFIG}")"
  set_common_knobs "${CONFIG}"
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
      "WINDOW_SEC=${CONTROLLER_WINDOW_SEC}"
      "LOCAL_RATE=${CONTROLLER_LOCAL_RATE}"
      "REMOTE_RATE=${CONTROLLER_REMOTE_RATE}"
      "LOCAL_FAULT_SCAN_PERIOD_MS=${CONTROLLER_LOCAL_FAULT_SCAN_PERIOD_MS}"
      "LOCAL_FAULT_SCAN_SIZE_MB=${CONTROLLER_LOCAL_FAULT_SCAN_SIZE_MB}"
      "REMOTE_FAULT_SCAN_PERIOD_MS=${CONTROLLER_REMOTE_FAULT_SCAN_PERIOD_MS}"
      "REMOTE_FAULT_SCAN_SIZE_MB=${CONTROLLER_REMOTE_FAULT_SCAN_SIZE_MB}"
      "MIN_LOCAL_PAGES=${CONTROLLER_MIN_LOCAL_PAGES}"
      "MIN_REMOTE_PAGES=${CONTROLLER_MIN_REMOTE_PAGES}"
      "CONSECUTIVE_EFFECTIVE=${CONTROLLER_CONSECUTIVE_EFFECTIVE}"
      "CONSECUTIVE_NO_IMPROVE=${CONTROLLER_CONSECUTIVE_NO_IMPROVE}"
      "RESTART_REMOTE_SHARE_THRESHOLD=${CONTROLLER_RESTART_REMOTE_SHARE_THRESHOLD}"
      "CONSECUTIVE_RESTART=${CONTROLLER_CONSECUTIVE_RESTART}"
      "RESTART_GRACE_WINDOWS=${CONTROLLER_RESTART_GRACE_WINDOWS}"
      "NUMA_BALANCING_ON=${CONTROLLER_NUMA_BALANCING_ON}"
      "NUMA_BALANCING_OFF=${CONTROLLER_NUMA_BALANCING_OFF}"
      "MGLRU_ENABLED=${MGLRU_ENABLED}"
      "DEMOTION_ENABLED=$(policy_demotion_enabled "${CONFIG}")"
      "DEMOTION_TARGET=$(policy_demotion_target "${CONFIG}")"
      "NUMA_SCAN_SIZE_MB=${NUMA_SCAN_SIZE_MB}"
      "NUMA_SCAN_PERIOD_MIN_MS=${NUMA_SCAN_PERIOD_MIN_MS}"
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
    printf 'local_fault_rate_override=%s\n' "${LOCAL_FAULT_RATE}"
    printf 'remote_fault_rate_override=%s\n' "${REMOTE_FAULT_RATE}"
    printf 'local_fault_scan_period_ms_override=%s\n' "${LOCAL_FAULT_SCAN_PERIOD_MS}"
    printf 'local_fault_scan_size_mb_override=%s\n' "${LOCAL_FAULT_SCAN_SIZE_MB}"
    printf 'remote_fault_scan_period_ms_override=%s\n' "${REMOTE_FAULT_SCAN_PERIOD_MS}"
    printf 'remote_fault_scan_size_mb_override=%s\n' "${REMOTE_FAULT_SCAN_SIZE_MB}"
    printf 'placement=%s\n' "${placement_display}"
    printf 'command=%s\n' "${cmd_display}"
    printf 'controller_enabled=%s\n' "${controller_enabled}"
    if [[ "${controller_enabled}" == "1" ]]; then
      printf 'controller_dir=%s\n' "${CONTROLLER_DIR}"
      printf 'controller_runner=%s\n' "${CONTROLLER_RUNNER}"
      printf 'controller_outdir=%s\n' "${controller_out}"
      printf 'controller_csv=%s\n' "${controller_out}/controller.csv"
      printf 'controller_workload_command=%s\n' "${workload_command_quoted}"
      printf 'controller_window_sec=%s\n' "${CONTROLLER_WINDOW_SEC}"
      printf 'controller_local_rate=%s\n' "${CONTROLLER_LOCAL_RATE}"
      printf 'controller_remote_rate=%s\n' "${CONTROLLER_REMOTE_RATE}"
      printf 'controller_local_fault_scan_period_ms=%s\n' "${CONTROLLER_LOCAL_FAULT_SCAN_PERIOD_MS}"
      printf 'controller_local_fault_scan_size_mb=%s\n' "${CONTROLLER_LOCAL_FAULT_SCAN_SIZE_MB}"
      printf 'controller_remote_fault_scan_period_ms=%s\n' "${CONTROLLER_REMOTE_FAULT_SCAN_PERIOD_MS}"
      printf 'controller_remote_fault_scan_size_mb=%s\n' "${CONTROLLER_REMOTE_FAULT_SCAN_SIZE_MB}"
      printf 'controller_min_local_pages=%s\n' "${CONTROLLER_MIN_LOCAL_PAGES}"
      printf 'controller_min_remote_pages=%s\n' "${CONTROLLER_MIN_REMOTE_PAGES}"
      printf 'controller_consecutive_effective=%s\n' "${CONTROLLER_CONSECUTIVE_EFFECTIVE}"
      printf 'controller_consecutive_no_improve=%s\n' "${CONTROLLER_CONSECUTIVE_NO_IMPROVE}"
      printf 'controller_restart_remote_share_threshold=%s\n' "${CONTROLLER_RESTART_REMOTE_SHARE_THRESHOLD}"
      printf 'controller_consecutive_restart=%s\n' "${CONTROLLER_CONSECUTIVE_RESTART}"
      printf 'controller_restart_grace_windows=%s\n' "${CONTROLLER_RESTART_GRACE_WINDOWS}"
      printf 'controller_numa_balancing_on=%s\n' "${CONTROLLER_NUMA_BALANCING_ON}"
      printf 'controller_numa_balancing_off=%s\n' "${CONTROLLER_NUMA_BALANCING_OFF}"
    fi
    printf 'cpu_node=%s\n' "${CPU_NODE}"
    printf 'omp_threads=%s\n' "${OMP_THREADS}"
    printf 'timeout_sec=%s\n' "${TIMEOUT_SEC}"
    printf 'sample_interval_sec=%s\n' "${SAMPLE_INTERVAL_SEC}"
    printf 'thp_mode=%s\n' "${THP_MODE}"
    printf 'thp_defrag=%s\n' "${THP_DEFRAG}"
    printf 'realworld_size_profile=%s\n' "${REALWORLD_SIZE_PROFILE}"
    printf 'trace_bc_trial_promotions=%s\n' "${TRACE_BC_TRIAL_PROMOTIONS}"
    case "${WORKLOAD}" in
      pr|gapbs_pr|bc|gapbs_bc)
        printf 'gapbs_graph_mode=prebuilt\n'
        printf 'gapbs_graph_scale=%s\n' "${GAPBS_GRAPH_SCALE}"
        printf 'gapbs_graph_path=%s\n' "${GRAPH}"
        printf 'graph=%s\n' "${GRAPH}"
        printf 'graph_build_included=0\n'
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
  set +e
  (
    export OMP_NUM_THREADS="${OMP_THREADS}"
    export OMP_PROC_BIND=true
    export OMP_PLACES=cores
    export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-4}"
    export BENCHMARK_DIR TOOLS_DIR WORKDIR REALWORLD_SIZE_PROFILE
    /usr/bin/time -v -o "${OUTDIR}/time.txt" \
      timeout "${TIMEOUT_SEC}" "${cmd[@]}" \
      > "${OUTDIR}/workload.stdout.log" 2> "${OUTDIR}/workload.stderr.log" &
    child=$!
    sample_memory "${child}" "${OUTDIR}/memory_samples.csv" &
    sampler=$!
    sample_promotion "${child}" "${OUTDIR}/promotion_samples.csv" &
    promotion_sampler=$!
    wait "${child}"
    child_status=$?
    if [[ -r "${OUTDIR}/promotion_samples.csv.start" ]]; then
      append_promotion_sample \
        "${OUTDIR}/promotion_samples.csv" \
        "$(cat "${OUTDIR}/promotion_samples.csv.start")" \
        final
    fi
    kill "${sampler}" 2>/dev/null || true
    kill "${promotion_sampler}" 2>/dev/null || true
    wait "${sampler}" 2>/dev/null || true
    wait "${promotion_sampler}" 2>/dev/null || true
    exit "${child_status}"
  )
  status=$?
  set -e
  end_s="$(date +%s)"
  end_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  elapsed_s=$((end_s - start_s))

  printf '%s\n' "${status}" > "${OUTDIR}/exit.status"
  write_status "${status}" "${elapsed_s}" "${start_utc}" "${end_utc}"
  snapshot after
  log "finished config=${CONFIG} workload=${WORKLOAD} status=${status} elapsed_s=${elapsed_s}"
  return "${status}"
}

run_case
