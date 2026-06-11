#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"
REPO_ROOT="${REPO_ROOT:-/Serverless/iccd-git}"

HOST_BOOT_SCRIPT="${HOST_BOOT_SCRIPT:-${SCRIPT_DIR}/host_boot_target.sh}"
STATE_ROOT="${STATE_ROOT:-/var/lib/iccd/eval1-host-native-migration-sweep}"
LOG_ROOT="${LOG_ROOT:-/var/log/iccd/eval1-host-native-migration-sweep}"
RESULTS_ROOT="${RESULTS_ROOT:-${SCRIPT_DIR}/results}"
STATE_FILE="${STATE_FILE:-${STATE_ROOT}/state.env}"
LOCK_FILE="${LOCK_FILE:-${STATE_ROOT}/runner.lock}"

LOCAL_NODE="${LOCAL_NODE:-0}"
REMOTE_NODE="${REMOTE_NODE:-2}"
CPU_NODE="${CPU_NODE:-0}"
TARGET_TOLERANCE_GIB="${TARGET_TOLERANCE_GIB:-1}"
TARGETS="${TARGETS:-16 32}"
MIGRATION_MODES="${MIGRATION_MODES:-off on}"
WORKLOADS="${WORKLOADS:-pr bc gups btree silo liblinear}"

GAPBS_GRAPH_SCALE="${GAPBS_GRAPH_SCALE:-29}"
GAPBS_GRAPH="${GAPBS_GRAPH:-/Serverless/benchmark/gapbs/benchmark/graphs/kron_g${GAPBS_GRAPH_SCALE}.sg}"
PR_BIN="${PR_BIN:-/Serverless/benchmark/gapbs/pr}"
BC_BIN="${BC_BIN:-/Serverless/benchmark/gapbs/bc}"
GUPS_BIN="${GUPS_BIN:-/Serverless/benchmark/vmitosis-workloads/bin/bench_gups_mt}"
BTREE_BIN="${BTREE_BIN:-/Serverless/benchmark/vmitosis-workloads/bin/bench_btree_mt}"
SILO_BIN="${SILO_BIN:-/Serverless/benchmark/silo/out-perf.masstree/benchmarks/dbtest}"
LIBLINEAR_TRAIN_BIN="${LIBLINEAR_TRAIN_BIN:-/Serverless/benchmark/liblinear-multicore-2.47/train}"
LIBLINEAR_DATASET="${LIBLINEAR_DATASET:-/Serverless/benchmark/liblinear-multicore-2.47/datasets/kdd12}"
NUMACTL_BIN="${NUMACTL_BIN:-/usr/bin/numactl}"
TIME_BIN="${TIME_BIN:-/usr/bin/time}"
IPMI_BIN="${IPMI_BIN:-/usr/bin/ipmitool}"

OMP_THREADS="${OMP_THREADS:-32}"
PR_ITERATIONS="${PR_ITERATIONS:-1000}"
PR_TOLERANCE="${PR_TOLERANCE:-1e-4}"
PR_TRIALS="${PR_TRIALS:-20}"
BC_ITERATIONS="${BC_ITERATIONS:-1}"
BC_TRIALS="${BC_TRIALS:-16}"
SILO_THREADS="${SILO_THREADS:-32}"
SILO_SCALE_FACTOR="${SILO_SCALE_FACTOR:-800000}"
SILO_OPS_PER_WORKER="${SILO_OPS_PER_WORKER:-100000000}"
LIBLINEAR_SOLVER="${LIBLINEAR_SOLVER:-6}"
LIBLINEAR_THREADS="${LIBLINEAR_THREADS:-32}"
POST_WORKLOAD_SLEEP_SEC="${POST_WORKLOAD_SLEEP_SEC:-5}"
RESUME_WAIT_SEC="${RESUME_WAIT_SEC:-20}"
VERIFY_RETRIES="${VERIFY_RETRIES:-3}"
RAPL_PACKAGE_DOMAIN="${RAPL_PACKAGE_DOMAIN:-package-0}"
RAPL_DRAM_DOMAIN="${RAPL_DRAM_DOMAIN:-dram}"
IPMI_POWER_SAMPLING="${IPMI_POWER_SAMPLING:-1}"
IPMI_POWER_INTERVAL_SEC="${IPMI_POWER_INTERVAL_SEC:-1}"

RUN_ID="${RUN_ID:-}"
TARGET_INDEX="${TARGET_INDEX:-0}"
MIGRATION_INDEX="${MIGRATION_INDEX:-0}"
WORKLOAD_INDEX="${WORKLOAD_INDEX:-0}"
IPMI_POWER_PID=""

usage() {
  cat <<'EOF'
Usage:
  run_host_native_migration_sweep.sh start
  run_host_native_migration_sweep.sh resume
  run_host_native_migration_sweep.sh status
  run_host_native_migration_sweep.sh remove-hook

Runs host-native eval_1 workloads for memory targets 16G and 32G, with
migration off/on, minimizing reboots by finishing every workload for a target
before switching memory target.
EOF
}

log() {
  mkdir -p "${LOG_ROOT}" 2>/dev/null || true
  printf '[host-native-sweep] %s\n' "$*" >&2
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${LOG_ROOT}/runner.log" 2>/dev/null || true
}

die() {
  log "error: $*"
  exit 2
}

require_root() {
  [[ "${EUID}" == "0" ]] || die "run as root"
}

split_words() {
  local value="$1"
  # shellcheck disable=SC2206
  SPLIT_WORDS=(${value})
}

save_state() {
  mkdir -p "${STATE_ROOT}" "${LOG_ROOT}" "${RESULTS_ROOT}"
  {
    printf 'RUN_ID=%q\n' "${RUN_ID}"
    printf 'TARGET_INDEX=%q\n' "${TARGET_INDEX}"
    printf 'MIGRATION_INDEX=%q\n' "${MIGRATION_INDEX}"
    printf 'WORKLOAD_INDEX=%q\n' "${WORKLOAD_INDEX}"
    printf 'TARGETS=%q\n' "${TARGETS}"
    printf 'MIGRATION_MODES=%q\n' "${MIGRATION_MODES}"
    printf 'WORKLOADS=%q\n' "${WORKLOADS}"
    printf 'RESULTS_ROOT=%q\n' "${RESULTS_ROOT}"
    printf 'GAPBS_GRAPH=%q\n' "${GAPBS_GRAPH}"
    printf 'GAPBS_GRAPH_SCALE=%q\n' "${GAPBS_GRAPH_SCALE}"
    printf 'SILO_BIN=%q\n' "${SILO_BIN}"
    printf 'SILO_THREADS=%q\n' "${SILO_THREADS}"
    printf 'SILO_SCALE_FACTOR=%q\n' "${SILO_SCALE_FACTOR}"
    printf 'SILO_OPS_PER_WORKER=%q\n' "${SILO_OPS_PER_WORKER}"
    printf 'LIBLINEAR_TRAIN_BIN=%q\n' "${LIBLINEAR_TRAIN_BIN}"
    printf 'LIBLINEAR_DATASET=%q\n' "${LIBLINEAR_DATASET}"
    printf 'LIBLINEAR_SOLVER=%q\n' "${LIBLINEAR_SOLVER}"
    printf 'LIBLINEAR_THREADS=%q\n' "${LIBLINEAR_THREADS}"
    printf 'updated_utc=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${STATE_FILE}"
}

load_state() {
  [[ -r "${STATE_FILE}" ]] || die "state not found; run start first"
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
}

run_dir() {
  printf '%s/%s\n' "${RESULTS_ROOT}" "${RUN_ID}"
}

summary_path() {
  printf '%s/summary.tsv\n' "$(run_dir)"
}

install_reboot_hook() {
  require_root
  mkdir -p "${STATE_ROOT}" "${LOG_ROOT}"
  local marker_begin="# ICCD_EVAL1_HOST_NATIVE_SWEEP_BEGIN"
  local marker_end="# ICCD_EVAL1_HOST_NATIVE_SWEEP_END"
  local cmd="cd ${REPO_ROOT@Q} && sleep ${RESUME_WAIT_SEC@Q} && exec ${SCRIPT_PATH@Q} resume >> ${LOG_ROOT@Q}/reboot-resume.log 2>&1"
  local tmp
  tmp="$(mktemp)"
  {
    crontab -l 2>/dev/null | awk -v begin="${marker_begin}" -v end="${marker_end}" '
      $0 == begin {skip=1; next}
      $0 == end {skip=0; next}
      !skip {print}
    '
    printf '%s\n' "${marker_begin}"
    printf '@reboot /bin/bash -lc %q\n' "${cmd}"
    printf '%s\n' "${marker_end}"
  } > "${tmp}"
  crontab "${tmp}"
  rm -f "${tmp}"
  log "installed @reboot sweep resume hook"
}

remove_reboot_hook() {
  [[ "${EUID}" == "0" ]] || return 0
  local marker_begin="# ICCD_EVAL1_HOST_NATIVE_SWEEP_BEGIN"
  local marker_end="# ICCD_EVAL1_HOST_NATIVE_SWEEP_END"
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | awk -v begin="${marker_begin}" -v end="${marker_end}" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' > "${tmp}"
  crontab "${tmp}" || true
  rm -f "${tmp}"
  log "removed @reboot sweep resume hook"
}

drop_caches() {
  sync || true
  if [[ -w /proc/sys/vm/drop_caches ]]; then
    printf '3\n' > /proc/sys/vm/drop_caches
  fi
}

node_memfree_mib() {
  local node="$1"
  awk -v node="${node}" '
    $1 == "Node" && $2 == node && $3 == "MemFree:" {
      print int($4 / 1024); found = 1
    }
    END { if (!found) exit 1 }
  ' "/sys/devices/system/node/node${node}/meminfo"
}

target_ok() {
  local target="$1"
  local free_mib lower upper
  free_mib="$(node_memfree_mib "${LOCAL_NODE}")"
  lower=$(((target - TARGET_TOLERANCE_GIB) * 1024))
  upper=$(((target + TARGET_TOLERANCE_GIB) * 1024))
  (( free_mib >= lower && free_mib <= upper ))
}

wait_for_converge_if_running() {
  local waited=0
  while pgrep -af 'host_boot_target.sh converge' >/dev/null 2>&1; do
    log "host boot convergence is still running; wait ${RESUME_WAIT_SEC}s"
    sleep "${RESUME_WAIT_SEC}"
    waited=$((waited + RESUME_WAIT_SEC))
    if (( waited > 7200 )); then
      die "host boot convergence did not finish within 7200s"
    fi
  done
}

verify_target_or_reboot() {
  local target="$1"
  local outdir="$2"
  local attempt verify_log
  mkdir -p "${outdir}"

  wait_for_converge_if_running
  for attempt in $(seq 1 "${VERIFY_RETRIES}"); do
    drop_caches
    verify_log="${outdir}/verify.target${target}g.attempt${attempt}.txt"
    if DROP_CACHES_BEFORE_VERIFY=1 TARGET_TOLERANCE_GIB="${TARGET_TOLERANCE_GIB}" \
        "${HOST_BOOT_SCRIPT}" verify --target-gib "${target}" > "${verify_log}" 2>&1; then
      cp /proc/cmdline "${outdir}/proc.cmdline.txt" 2>/dev/null || true
      return 0
    fi
    log "target ${target}G not ready before workload; attempt=${attempt}; see ${verify_log}"
    sleep 5
  done

  log "target ${target}G is not in window; starting convergence and reboot"
  save_state
  MAX_REBOOTS=4 "${HOST_BOOT_SCRIPT}" converge --target-gib "${target}" --apply --reboot
  exit 0
}

set_migration_mode() {
  local mode="$1"
  case "${mode}" in
    on)
      printf '2\n' > /proc/sys/kernel/numa_balancing
      ;;
    off)
      printf '0\n' > /proc/sys/kernel/numa_balancing
      ;;
    *)
      die "unknown migration mode: ${mode}"
      ;;
  esac
}

snapshot_common() {
  local outdir="$1" phase="$2"
  mkdir -p "${outdir}"
  cat /proc/sys/kernel/numa_balancing > "${outdir}/numa_balancing.${phase}.txt" 2>/dev/null || true
  cat /sys/kernel/mm/numa/demotion_enabled > "${outdir}/demotion_enabled.${phase}.txt" 2>/dev/null || true
  cat /sys/kernel/mm/numa/demotion_target > "${outdir}/demotion_target.${phase}.txt" 2>/dev/null || true
  cat "/sys/devices/system/node/node${LOCAL_NODE}/meminfo" > "${outdir}/node${LOCAL_NODE}.meminfo.${phase}.txt" 2>/dev/null || true
  cat "/sys/devices/system/node/node${REMOTE_NODE}/meminfo" > "${outdir}/node${REMOTE_NODE}.meminfo.${phase}.txt" 2>/dev/null || true
  cat /proc/vmstat > "${outdir}/vmstat.${phase}.txt" 2>/dev/null || true
  free -h > "${outdir}/free.${phase}.txt" 2>/dev/null || true
}

rapl_domain_path() {
  local domain="$1" d name
  for d in /sys/class/powercap/intel-rapl:*; do
    [[ -r "${d}/name" ]] || continue
    name="$(cat "${d}/name" 2>/dev/null || true)"
    if [[ "${name}" == "${domain}" ]]; then
      printf '%s\n' "${d}"
      return 0
    fi
  done
  return 1
}

rapl_read_value() {
  local domain="$1" file="$2" path
  path="$(rapl_domain_path "${domain}")" || return 1
  [[ -r "${path}/${file}" ]] || return 1
  cat "${path}/${file}"
}

rapl_delta_uj() {
  local start="$1" end="$2" max="$3"
  [[ "${start}" =~ ^[0-9]+$ && "${end}" =~ ^[0-9]+$ ]] || return 1
  if (( end >= start )); then
    printf '%s\n' $((end - start))
  elif [[ "${max}" =~ ^[0-9]+$ && "${max}" -gt 0 ]]; then
    printf '%s\n' $((end + max - start))
  else
    return 1
  fi
}

uj_to_j() {
  awk -v uj="${1:-}" 'BEGIN { if (uj ~ /^[0-9]+$/) printf "%.6f", uj / 1000000; }'
}

j_to_avg_w() {
  awk -v joules="${1:-}" -v elapsed="${2:-0}" \
    'BEGIN { if (joules != "" && elapsed > 0) printf "%.6f", joules / elapsed; }'
}

write_rapl_snapshot() {
  local outdir="$1" phase="$2" domain path energy max
  local file="${outdir}/rapl.${phase}.tsv"
  printf 'domain\tpath\tenergy_uj\tmax_energy_range_uj\n' > "${file}"
  for domain in "${RAPL_PACKAGE_DOMAIN}" "${RAPL_DRAM_DOMAIN}"; do
    path="$(rapl_domain_path "${domain}" 2>/dev/null || true)"
    [[ -n "${path}" ]] || continue
    energy="$(cat "${path}/energy_uj" 2>/dev/null || true)"
    max="$(cat "${path}/max_energy_range_uj" 2>/dev/null || true)"
    printf '%s\t%s\t%s\t%s\n' "${domain}" "${path}" "${energy}" "${max}" >> "${file}"
  done
}

start_ipmi_power_sampler() {
  local outdir="$1" csv="${outdir}/ipmi_power.csv"
  IPMI_POWER_PID=""
  [[ "${IPMI_POWER_SAMPLING}" == "1" ]] || return 0
  [[ -x "${IPMI_BIN}" ]] || return 0
  (
    printf 'epoch,power_w\n'
    while :; do
      now="$(date +%s)"
      power="$("${IPMI_BIN}" dcmi power reading 2>/dev/null | awk -F: '
        /Instantaneous power reading/ {
          gsub(/ Watts/, "", $2)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
          print $2
          exit
        }'
      )"
      if [[ "${power}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        printf '%s,%s\n' "${now}" "${power}"
      fi
      sleep "${IPMI_POWER_INTERVAL_SEC}"
    done
  ) > "${csv}" 2> "${outdir}/ipmi_power.stderr.txt" &
  IPMI_POWER_PID="$!"
}

stop_ipmi_power_sampler() {
  if [[ -n "${IPMI_POWER_PID}" ]] && kill -0 "${IPMI_POWER_PID}" 2>/dev/null; then
    kill "${IPMI_POWER_PID}" 2>/dev/null || true
    wait "${IPMI_POWER_PID}" 2>/dev/null || true
  fi
  IPMI_POWER_PID=""
}

summarize_ipmi_power() {
  local csv="$1" elapsed="$2"
  awk -F, -v elapsed="${elapsed}" '
    NR > 1 && $2 ~ /^[0-9.]+$/ {
      sum += $2
      n += 1
      if (n == 1 || $2 < min) min = $2
      if (n == 1 || $2 > max) max = $2
    }
    END {
      if (n > 0) {
        avg = sum / n
        printf "ipmi_samples=%d\nipmi_avg_w=%.6f\nipmi_min_w=%.6f\nipmi_max_w=%.6f\nipmi_energy_est_j=%.6f\n", n, avg, min, max, avg * elapsed
      } else {
        printf "ipmi_samples=0\nipmi_avg_w=\nipmi_min_w=\nipmi_max_w=\nipmi_energy_est_j=\n"
      }
    }
  ' "${csv}" 2>/dev/null || printf 'ipmi_samples=0\nipmi_avg_w=\nipmi_min_w=\nipmi_max_w=\nipmi_energy_est_j=\n'
}

workload_command() {
  local workload="$1"
  local outdir="${2:-}"
  WORKLOAD_CMD=()
  case "${workload}" in
    pr)
      [[ -r "${GAPBS_GRAPH}" ]] || die "missing GAPBS graph: ${GAPBS_GRAPH}"
      WORKLOAD_CMD=("${PR_BIN}" -f "${GAPBS_GRAPH}" -i "${PR_ITERATIONS}" -t "${PR_TOLERANCE}" -n "${PR_TRIALS}")
      ;;
    bc)
      [[ -r "${GAPBS_GRAPH}" ]] || die "missing GAPBS graph: ${GAPBS_GRAPH}"
      WORKLOAD_CMD=("${BC_BIN}" -f "${GAPBS_GRAPH}" -i "${BC_ITERATIONS}" -n "${BC_TRIALS}")
      ;;
    gups)
      WORKLOAD_CMD=("${GUPS_BIN}")
      ;;
    btree)
      WORKLOAD_CMD=("${BTREE_BIN}")
      ;;
    silo)
      [[ -x "${SILO_BIN}" ]] || die "missing executable Silo dbtest: ${SILO_BIN}"
      WORKLOAD_CMD=("${SILO_BIN}" --verbose --bench ycsb --num-threads "${SILO_THREADS}" \
        --scale-factor "${SILO_SCALE_FACTOR}" --ops-per-worker="${SILO_OPS_PER_WORKER}")
      ;;
    liblinear)
      [[ -x "${LIBLINEAR_TRAIN_BIN}" ]] || die "missing executable Liblinear train: ${LIBLINEAR_TRAIN_BIN}"
      [[ -r "${LIBLINEAR_DATASET}" ]] || die "missing Liblinear dataset: ${LIBLINEAR_DATASET}"
      [[ -n "${outdir}" ]] || die "internal error: liblinear requires an output directory"
      local dataset_name
      dataset_name="$(basename -- "${LIBLINEAR_DATASET}")"
      WORKLOAD_CMD=("${LIBLINEAR_TRAIN_BIN}" -s "${LIBLINEAR_SOLVER}" -m "${LIBLINEAR_THREADS}" \
        "${LIBLINEAR_DATASET}" "${outdir}/${dataset_name}.model")
      ;;
    *)
      die "unknown workload: ${workload}"
      ;;
  esac
}

run_one_workload() {
  local target="$1" migration="$2" workload="$3"
  local outdir start end rc elapsed free_before free_after
  local rapl_pkg_start="" rapl_pkg_end="" rapl_pkg_max="" rapl_pkg_delta="" rapl_pkg_j="" rapl_pkg_w=""
  local rapl_dram_start="" rapl_dram_end="" rapl_dram_max="" rapl_dram_delta="" rapl_dram_j="" rapl_dram_w=""
  local ipmi_samples="" ipmi_avg_w="" ipmi_min_w="" ipmi_max_w="" ipmi_energy_est_j=""
  outdir="$(run_dir)/target${target}g/migration_${migration}/${workload}"
  mkdir -p "${outdir}"

  verify_target_or_reboot "${target}" "${outdir}"
  set_migration_mode "${migration}"
  drop_caches
  if ! target_ok "${target}"; then
    log "target ${target}G drifted after setting migration=${migration}; starting convergence and reboot"
    save_state
    MAX_REBOOTS=4 "${HOST_BOOT_SCRIPT}" converge --target-gib "${target}" --apply --reboot
    exit 0
  fi
  free_before="$(node_memfree_mib "${LOCAL_NODE}" 2>/dev/null || printf 0)"
  snapshot_common "${outdir}" "before"
  write_rapl_snapshot "${outdir}" "before"
  workload_command "${workload}" "${outdir}"

  {
    printf 'target_gib=%s\n' "${target}"
    printf 'migration=%s\n' "${migration}"
    printf 'workload=%s\n' "${workload}"
    printf 'gapbs_graph=%s\n' "${GAPBS_GRAPH}"
    printf 'gapbs_graph_scale=%s\n' "${GAPBS_GRAPH_SCALE}"
    printf 'command='
    printf '%q ' "${TIME_BIN}" -v "${NUMACTL_BIN}" --cpunodebind="${CPU_NODE}" --localalloc \
      env OMP_NUM_THREADS="${OMP_THREADS}" OMP_PROC_BIND=true OMP_PLACES=cores "${WORKLOAD_CMD[@]}"
    printf '\n'
  } > "${outdir}/command.env"

  log "run target=${target}G migration=${migration} workload=${workload}"
  rapl_pkg_start="$(rapl_read_value "${RAPL_PACKAGE_DOMAIN}" energy_uj 2>/dev/null || true)"
  rapl_pkg_max="$(rapl_read_value "${RAPL_PACKAGE_DOMAIN}" max_energy_range_uj 2>/dev/null || true)"
  rapl_dram_start="$(rapl_read_value "${RAPL_DRAM_DOMAIN}" energy_uj 2>/dev/null || true)"
  rapl_dram_max="$(rapl_read_value "${RAPL_DRAM_DOMAIN}" max_energy_range_uj 2>/dev/null || true)"
  start_ipmi_power_sampler "${outdir}"
  start="$(date +%s)"
  set +e
  "${TIME_BIN}" -v \
    "${NUMACTL_BIN}" --cpunodebind="${CPU_NODE}" --localalloc \
    env OMP_NUM_THREADS="${OMP_THREADS}" OMP_PROC_BIND=true OMP_PLACES=cores \
    "${WORKLOAD_CMD[@]}" > "${outdir}/workload.stdout.txt" 2>&1
  rc=$?
  set -e
  end="$(date +%s)"
  stop_ipmi_power_sampler
  rapl_pkg_end="$(rapl_read_value "${RAPL_PACKAGE_DOMAIN}" energy_uj 2>/dev/null || true)"
  rapl_dram_end="$(rapl_read_value "${RAPL_DRAM_DOMAIN}" energy_uj 2>/dev/null || true)"
  elapsed=$((end - start))
  rapl_pkg_delta="$(rapl_delta_uj "${rapl_pkg_start}" "${rapl_pkg_end}" "${rapl_pkg_max}" 2>/dev/null || true)"
  rapl_dram_delta="$(rapl_delta_uj "${rapl_dram_start}" "${rapl_dram_end}" "${rapl_dram_max}" 2>/dev/null || true)"
  rapl_pkg_j="$(uj_to_j "${rapl_pkg_delta}")"
  rapl_dram_j="$(uj_to_j "${rapl_dram_delta}")"
  rapl_pkg_w="$(j_to_avg_w "${rapl_pkg_j}" "${elapsed}")"
  rapl_dram_w="$(j_to_avg_w "${rapl_dram_j}" "${elapsed}")"
  eval "$(summarize_ipmi_power "${outdir}/ipmi_power.csv" "${elapsed}")"
  printf '%s\n' "${rc}" > "${outdir}/workload.rc"
  printf '%s\n' "${elapsed}" > "${outdir}/elapsed_sec"
  {
    printf 'rapl_package_domain=%s\n' "${RAPL_PACKAGE_DOMAIN}"
    printf 'rapl_package_start_uj=%s\n' "${rapl_pkg_start}"
    printf 'rapl_package_end_uj=%s\n' "${rapl_pkg_end}"
    printf 'rapl_package_delta_uj=%s\n' "${rapl_pkg_delta}"
    printf 'rapl_package_j=%s\n' "${rapl_pkg_j}"
    printf 'rapl_package_avg_w=%s\n' "${rapl_pkg_w}"
    printf 'rapl_dram_domain=%s\n' "${RAPL_DRAM_DOMAIN}"
    printf 'rapl_dram_start_uj=%s\n' "${rapl_dram_start}"
    printf 'rapl_dram_end_uj=%s\n' "${rapl_dram_end}"
    printf 'rapl_dram_delta_uj=%s\n' "${rapl_dram_delta}"
    printf 'rapl_dram_j=%s\n' "${rapl_dram_j}"
    printf 'rapl_dram_avg_w=%s\n' "${rapl_dram_w}"
    printf 'ipmi_samples=%s\n' "${ipmi_samples}"
    printf 'ipmi_avg_w=%s\n' "${ipmi_avg_w}"
    printf 'ipmi_min_w=%s\n' "${ipmi_min_w}"
    printf 'ipmi_max_w=%s\n' "${ipmi_max_w}"
    printf 'ipmi_energy_est_j=%s\n' "${ipmi_energy_est_j}"
  } > "${outdir}/energy.env"

  sleep "${POST_WORKLOAD_SLEEP_SEC}"
  drop_caches
  free_after="$(node_memfree_mib "${LOCAL_NODE}" 2>/dev/null || printf 0)"
  snapshot_common "${outdir}" "after"
  write_rapl_snapshot "${outdir}" "after"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${RUN_ID}" "${target}" "${migration}" "${workload}" "${rc}" "${elapsed}" "${free_before}" "${free_after}" \
    "${rapl_pkg_j}" "${rapl_pkg_w}" "${rapl_dram_j}" "${rapl_dram_w}" \
    "${ipmi_avg_w}" "${ipmi_energy_est_j}" "${ipmi_samples}" \
    >> "$(summary_path)"
  log "done target=${target}G migration=${migration} workload=${workload} rc=${rc} elapsed=${elapsed}s"
}

advance_indices() {
  local target_count migration_count workload_count
  split_words "${TARGETS}"; target_count="${#SPLIT_WORDS[@]}"
  split_words "${MIGRATION_MODES}"; migration_count="${#SPLIT_WORDS[@]}"
  split_words "${WORKLOADS}"; workload_count="${#SPLIT_WORDS[@]}"

  WORKLOAD_INDEX=$((WORKLOAD_INDEX + 1))
  if (( WORKLOAD_INDEX >= workload_count )); then
    WORKLOAD_INDEX=0
    MIGRATION_INDEX=$((MIGRATION_INDEX + 1))
  fi
  if (( MIGRATION_INDEX >= migration_count )); then
    MIGRATION_INDEX=0
    TARGET_INDEX=$((TARGET_INDEX + 1))
  fi
  save_state

  if (( TARGET_INDEX < target_count && WORKLOAD_INDEX == 0 && MIGRATION_INDEX == 0 )); then
    split_words "${TARGETS}"
    local next_target="${SPLIT_WORDS[${TARGET_INDEX}]}"
    if ! target_ok "${next_target}"; then
      log "switching to next target=${next_target}G; starting convergence and reboot"
      MAX_REBOOTS=4 "${HOST_BOOT_SCRIPT}" converge --target-gib "${next_target}" --apply --reboot
      exit 0
    fi
  fi
}

resume_run() {
  require_root
  mkdir -p "${STATE_ROOT}" "${LOG_ROOT}" "${RESULTS_ROOT}"
  exec 9>"${LOCK_FILE}"
  if ! flock -n 9; then
    log "another sweep runner is active"
    exit 0
  fi

  load_state
  split_words "${TARGETS}"; local -a targets=("${SPLIT_WORDS[@]}")
  split_words "${MIGRATION_MODES}"; local -a migrations=("${SPLIT_WORDS[@]}")
  split_words "${WORKLOADS}"; local -a workloads=("${SPLIT_WORDS[@]}")
  local target_count="${#targets[@]}"
  local migration_count="${#migrations[@]}"
  local workload_count="${#workloads[@]}"

  while (( TARGET_INDEX < target_count )); do
    local target="${targets[${TARGET_INDEX}]}"
    local migration="${migrations[${MIGRATION_INDEX}]}"
    local workload="${workloads[${WORKLOAD_INDEX}]}"
    run_one_workload "${target}" "${migration}" "${workload}"
    advance_indices
    split_words "${TARGETS}"; targets=("${SPLIT_WORDS[@]}"); target_count="${#targets[@]}"
    split_words "${MIGRATION_MODES}"; migrations=("${SPLIT_WORDS[@]}"); migration_count="${#migrations[@]}"
    split_words "${WORKLOADS}"; workloads=("${SPLIT_WORDS[@]}"); workload_count="${#workloads[@]}"
  done

  remove_reboot_hook
  log "sweep completed; results=$(run_dir)"
}

start_run() {
  require_root
  RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
  TARGET_INDEX=0
  MIGRATION_INDEX=0
  WORKLOAD_INDEX=0
  mkdir -p "$(run_dir)"
  printf 'run_id\ttarget_gib\tmigration\tworkload\trc\telapsed_sec\tnode0_free_mib_before\tnode0_free_mib_after\trapl_package_j\trapl_package_avg_w\trapl_dram_j\trapl_dram_avg_w\tipmi_avg_w\tipmi_energy_est_j\tipmi_samples\n' \
    > "$(summary_path)"
  {
    printf 'run_id=%s\n' "${RUN_ID}"
    printf 'targets=%s\n' "${TARGETS}"
    printf 'migration_modes=%s\n' "${MIGRATION_MODES}"
    printf 'workloads=%s\n' "${WORKLOADS}"
    printf 'gapbs_graph=%s\n' "${GAPBS_GRAPH}"
    printf 'pr_args=-f %s -i %s -t %s -n %s\n' "${GAPBS_GRAPH}" "${PR_ITERATIONS}" "${PR_TOLERANCE}" "${PR_TRIALS}"
    printf 'bc_args=-f %s -i %s -n %s\n' "${GAPBS_GRAPH}" "${BC_ITERATIONS}" "${BC_TRIALS}"
    printf 'gups_bin=%s\n' "${GUPS_BIN}"
    printf 'btree_bin=%s\n' "${BTREE_BIN}"
    printf 'silo_bin=%s\n' "${SILO_BIN}"
    printf 'silo_args=--verbose --bench ycsb --num-threads %s --scale-factor %s --ops-per-worker=%s\n' \
      "${SILO_THREADS}" "${SILO_SCALE_FACTOR}" "${SILO_OPS_PER_WORKER}"
    printf 'liblinear_train_bin=%s\n' "${LIBLINEAR_TRAIN_BIN}"
    printf 'liblinear_dataset=%s\n' "${LIBLINEAR_DATASET}"
    printf 'liblinear_args=-s %s -m %s %s <outdir>/kdd12.model\n' \
      "${LIBLINEAR_SOLVER}" "${LIBLINEAR_THREADS}" "${LIBLINEAR_DATASET}"
    printf 'post_workload_sleep_sec=%s\n' "${POST_WORKLOAD_SLEEP_SEC}"
    printf 'rapl_package_domain=%s\n' "${RAPL_PACKAGE_DOMAIN}"
    printf 'rapl_dram_domain=%s\n' "${RAPL_DRAM_DOMAIN}"
    printf 'ipmi_power_sampling=%s\n' "${IPMI_POWER_SAMPLING}"
    printf 'ipmi_power_interval_sec=%s\n' "${IPMI_POWER_INTERVAL_SEC}"
  } > "$(run_dir)/run_meta.env"
  save_state
  install_reboot_hook
  resume_run
}

cmd_status() {
  if [[ -r "${STATE_FILE}" ]]; then
    cat "${STATE_FILE}"
  else
    printf 'state_absent=%s\n' "${STATE_FILE}"
  fi
  if [[ -n "${RUN_ID:-}" ]]; then
    printf 'results=%s\n' "$(run_dir)"
  fi
}

main() {
  local cmd="${1:-}"
  case "${cmd}" in
    start) start_run ;;
    resume) resume_run ;;
    status) cmd_status ;;
    remove-hook) remove_reboot_hook ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
