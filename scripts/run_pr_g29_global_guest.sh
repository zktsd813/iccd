#!/usr/bin/env bash
set -euo pipefail

OUTROOT="${OUTROOT:-/root/pr-g29-global-$(date -u +%Y%m%dT%H%M%SZ)}"
RUNS="${RUNS:-migration_off migration_on}"
PR_BIN="${PR_BIN:-/root/pr}"
GRAPH_SCALE="${GRAPH_SCALE:-29}"
PR_ITERATIONS="${PR_ITERATIONS:-20}"
PR_TOLERANCE="${PR_TOLERANCE:-1e-4}"
PR_TRIALS="${PR_TRIALS:-1}"
OMP_THREADS="${OMP_THREADS:-32}"
TIMEOUT_SEC="${TIMEOUT_SEC:-21600}"
SAMPLE_INTERVAL_SEC="${SAMPLE_INTERVAL_SEC:-5}"
CPU_NODE="${CPU_NODE:-0}"
MGLRU_ENABLED="${MGLRU_ENABLED:-0x0007}"
DEMOTION_ENABLED="${DEMOTION_ENABLED:-true}"
DEMOTION_TARGET="${DEMOTION_TARGET:-0 1}"
NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-4096}"
NUMA_SCAN_PERIOD_MIN_MS="${NUMA_SCAN_PERIOD_MIN_MS:-1000}"
LOCAL_FAULT_SCAN_SIZE_MB="${LOCAL_FAULT_SCAN_SIZE_MB:-${NUMA_SCAN_SIZE_MB}}"
LOCAL_FAULT_SCAN_PERIOD_MS="${LOCAL_FAULT_SCAN_PERIOD_MS:-1000}"

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

mount_debugfs() {
  mkdir -p /sys/kernel/debug
  mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug || true
}

set_common_knobs() {
  mount_debugfs
  write_if_writable /sys/kernel/mm/lru_gen/enabled "${MGLRU_ENABLED}"
  write_if_writable /sys/kernel/mm/numa/demotion_enabled "${DEMOTION_ENABLED}"
  write_if_writable /sys/kernel/mm/numa/demotion_target "${DEMOTION_TARGET}"
  write_if_writable /sys/kernel/debug/sched/numa_balancing/scan_size_mb "${NUMA_SCAN_SIZE_MB}"
  write_if_writable /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms "${NUMA_SCAN_PERIOD_MIN_MS}"
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
      printf '%s\0' numactl "--cpunodebind=${CPU_NODE}" --localalloc
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
    printf 'scan_size_mb=%s\n' "$(read_file /sys/kernel/debug/sched/numa_balancing/scan_size_mb)"
    printf 'scan_period_min_ms=%s\n' "$(read_file /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms)"
    printf 'local_fault_scan_size_mb=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/local_fault_scan_size_mb)"
    printf 'local_fault_scan_period_ms=%s\n' "$(read_file /sys/kernel/mm/numa_balancing/local_fault_scan_period_ms)"
    printf 'meminfo_node0<<EOF\n'; sed -n '1,20p' /sys/devices/system/node/node0/meminfo 2>/dev/null || true; printf 'EOF\n'
    printf 'meminfo_node1<<EOF\n'; sed -n '1,20p' /sys/devices/system/node/node1/meminfo 2>/dev/null || true; printf 'EOF\n'
  } > "${dir}/${tag}.meta"
  numactl -H > "${dir}/${tag}.numactl" 2>&1 || true
  cp /proc/vmstat "${dir}/${tag}.vmstat" 2>/dev/null || true
  cp /proc/zoneinfo "${dir}/${tag}.zoneinfo" 2>/dev/null || true
  cat /sys/kernel/mm/numa_balancing/local_fault_stats > "${dir}/${tag}.local_fault_stats" 2>/dev/null || true
}

numa_maps_summary() {
  local pid="$1"
  awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^N[0-9]+=/) {
          split($i, a, "=");
          pages[a[1]] += a[2];
        }
      }
    }
    END {
      for (node in pages) {
        printf "%s_pages=%d %s_gib=%.6f\n", node, pages[node], node, pages[node] * 4096 / 1024 / 1024 / 1024;
      }
    }
  ' "/proc/${pid}/numa_maps" 2>/dev/null || true
}

sample_process() {
  local pid="$1" out="$2"
  local target child
  while kill -0 "${pid}" 2>/dev/null; do
    target="${pid}"
    while child="$(pgrep -P "${target}" | head -n 1)" && [[ -n "${child}" ]]; do
      target="${child}"
    done
    {
      printf -- '--- %s root_pid=%s target_pid=%s ---\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${pid}" "${target}"
      awk '/Name|VmRSS|VmHWM|Threads/ {print}' "/proc/${target}/status" 2>/dev/null || true
      numa_maps_summary "${target}"
      awk '/^(numa_|pgpromote_|pgdemote_|pgmigrate_|compact_|pgscan_|pgsteal_)/ {print}' /proc/vmstat 2>/dev/null || true
      cat /sys/kernel/mm/numa_balancing/local_fault_stats 2>/dev/null || true
    } >> "${out}"
    sleep "${SAMPLE_INTERVAL_SEC}"
  done
}

run_one() {
  local run="$1" dir="${OUTROOT}/${run}" numa_value
  local -a place cmd

  mkdir -p "${dir}"
  numa_value="$(policy_numa_value "${run}")"
  set_common_knobs
  write_if_writable /proc/sys/kernel/numa_balancing "${numa_value}"

  sync || true
  write_if_writable /proc/sys/vm/drop_caches 3

  snapshot "${dir}" before
  mapfile -d '' -t place < <(placement_args "${run}")
  cmd=("${place[@]}" "${PR_BIN}" -g "${GRAPH_SCALE}" -i "${PR_ITERATIONS}" -t "${PR_TOLERANCE}" -n "${PR_TRIALS}")

  {
    printf 'run=%s\n' "${run}"
    printf 'numa_balancing=%s\n' "${numa_value}"
    printf 'placement='
    printf '%q ' "${place[@]}"
    printf '\n'
    printf 'command='
    printf '%q ' "${cmd[@]}"
    printf '\n'
    printf 'omp_threads=%s\n' "${OMP_THREADS}"
    printf 'timeout_sec=%s\n' "${TIMEOUT_SEC}"
  } > "${dir}/run.config"

  log "starting ${run}: ${cmd[*]}"
  set +e
  (
    export OMP_NUM_THREADS="${OMP_THREADS}"
    export OMP_PROC_BIND=true
    export OMP_PLACES=cores
    export MALLOC_ARENA_MAX=4
    /usr/bin/time -v -o "${dir}/time.txt" timeout "${TIMEOUT_SEC}" "${cmd[@]}" > "${dir}/pr.out" 2> "${dir}/pr.err" &
    child=$!
    sample_process "${child}" "${dir}/samples.log" &
    sampler=$!
    wait "${child}"
    status=$?
    kill "${sampler}" 2>/dev/null || true
    wait "${sampler}" 2>/dev/null || true
    exit "${status}"
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
