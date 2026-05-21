#!/usr/bin/env bash
set -euo pipefail

PR_BIN="${MBENCH:-/root/pr}"
OUTDIR="${OUTDIR:-/tmp/pr_g28_local16_period_sweep}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
CGROOT="${CGROOT:-/sys/fs/cgroup}"
CG_PREFIX="${CG_PREFIX:-prg28p}"

LOCAL_NODE="${LOCAL_NODE:-0}"
REMOTE_NODE="${REMOTE_NODE:-1}"
CPUSET_CPUS="${CPUSET_CPUS:-0-31}"
CPUSET_MEMS="${CPUSET_MEMS:-${LOCAL_NODE},${REMOTE_NODE}}"
CAPACITY_PAGES="${CAPACITY_PAGES:-4194304}" # 16 GiB / 4 KiB

PR_SCALE="${PR_SCALE:-28}"
PR_MAX_ITERS="${PR_MAX_ITERS:-20}"
PR_TOL="${PR_TOL:-1e-4}"
PR_TRIALS="${PR_TRIALS:-10}"
GAPBS_PREBUILD_GRAPH="${GAPBS_PREBUILD_GRAPH:-1}"
GAPBS_GRAPH_FILE="${GAPBS_GRAPH_FILE:-/root/gapbs_graphs/kron_g${PR_SCALE}.sg}"
GAPBS_CONVERTER="${GAPBS_CONVERTER:-/root/converter}"
OMP_THREADS="${OMP_THREADS:-${THREADS:-32}}"
TIMEOUT_SEC="${TIMEOUT_SEC:-3600}"
POLICIES="${POLICIES:-on}"
SCAN_PERIODS="${SCAN_PERIODS:-250,500,1000}"

GLOBAL_NUMA_ON="${GLOBAL_NUMA_ON:-0}"
NODE_BALANCING_ON="${NODE_BALANCING_ON:-2}"
KSWAPD_DEMOTION_ON="${KSWAPD_DEMOTION_ON:-1}"
OFF_DEMOTION_ON="${OFF_DEMOTION_ON:-1}"
NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-256}"
NUMA_SCAN_PERIOD_MIN_MS="${NUMA_SCAN_PERIOD_MIN_MS:-1000}"
NUMA_FAST_SCAN="${NUMA_FAST_SCAN:-1}"
HOT_THRESHOLD_MS="${HOT_THRESHOLD_MS:-0}"
MGLRU_ENABLED_VALUE="${MGLRU_ENABLED_VALUE:-0x0007}"

LIVE_SAMPLE_SEC="${LIVE_SAMPLE_SEC:-5}"
LOCAL_UTIL_ADAPT_WINDOW_SEC="${LOCAL_UTIL_ADAPT_WINDOW_SEC:-10}"
LOCAL_UTIL_ADAPT_THRESHOLD_PCT="${LOCAL_UTIL_ADAPT_THRESHOLD_PCT:-80}"
LOCAL_UTIL_ADAPT_CONSECUTIVE="${LOCAL_UTIL_ADAPT_CONSECUTIVE:-3}"
LOCAL_UTIL_ADAPT_MIN_PTE_UPDATES="${LOCAL_UTIL_ADAPT_MIN_PTE_UPDATES:-1000}"
NUMA_LOCAL_FAULT_ON_TIERING="${NUMA_LOCAL_FAULT_ON_TIERING:-10}"
NUMA_LOCAL_FAULT_REFAULT_HIT_MS="${NUMA_LOCAL_FAULT_REFAULT_HIT_MS:-2000}"

RUN_ROOT="${OUTDIR}/${RUN_ID}"
mkdir -p "${RUN_ROOT}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi
if [[ ! -x "${PR_BIN}" ]]; then
  echo "PR binary not executable: ${PR_BIN}" >&2
  exit 1
fi

log() {
  printf '[pr-g28-guest] %s\n' "$*"
}

prepare_gapbs_graph() {
  GAPBS_INPUT_OPT="-g"
  GAPBS_INPUT_VALUE="${PR_SCALE}"
  GAPBS_INPUT_DESC="-g${PR_SCALE}"

  if [[ "${GAPBS_PREBUILD_GRAPH}" != "1" ]]; then
    log "graph cache disabled; using ${GAPBS_INPUT_DESC}"
    return 0
  fi

  mkdir -p "$(dirname "${GAPBS_GRAPH_FILE}")"
  if [[ -s "${GAPBS_GRAPH_FILE}" ]]; then
    log "using cached graph ${GAPBS_GRAPH_FILE}"
  else
    if [[ ! -x "${GAPBS_CONVERTER}" ]]; then
      echo "GAPBS converter not executable: ${GAPBS_CONVERTER}" >&2
      exit 1
    fi
    local tmp="${GAPBS_GRAPH_FILE}.tmp.$$"
    log "building cached graph ${GAPBS_GRAPH_FILE} from -g${PR_SCALE}"
    rm -f "${tmp}"
    env OMP_NUM_THREADS="${OMP_THREADS}" OMP_PROC_BIND=true OMP_PLACES=cores \
      "${GAPBS_CONVERTER}" -g"${PR_SCALE}" -b "${tmp}" \
      > "${RUN_ROOT}/graph_build.stdout.log" 2> "${RUN_ROOT}/graph_build.stderr.log"
    mv "${tmp}" "${GAPBS_GRAPH_FILE}"
  fi

  GAPBS_INPUT_OPT="-f"
  GAPBS_INPUT_VALUE="${GAPBS_GRAPH_FILE}"
  GAPBS_INPUT_DESC="-f ${GAPBS_GRAPH_FILE}"
}

read_optional() {
  local path="$1"
  [[ -f "${path}" ]] && cat "${path}" || true
}

write_optional() {
  local path="$1"
  local value="$2"
  if [[ -w "${path}" ]]; then
    echo "${value}" > "${path}" || true
  fi
}

pick_knob_file() {
  local cg="$1"
  local name="$2"
  local candidate
  for candidate in "${cg}/${name}" "${cg}/memory.${name}"; do
    if [[ -f "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

write_knob() {
  local cg="$1"
  local name="$2"
  local value="$3"
  local knob
  knob="$(pick_knob_file "${cg}" "${name}")"
  echo "${value}" > "${knob}"
}

write_knob_optional() {
  write_knob "$@" 2>/dev/null || true
}

read_knob() {
  local cg="$1"
  local name="$2"
  local knob
  knob="$(pick_knob_file "${cg}" "${name}")" || return 1
  cat "${knob}"
}

enable_controllers() {
  local ctrl
  if [[ ! -f "${CGROOT}/cgroup.controllers" ]]; then
    return 0
  fi
  for ctrl in cpuset memory; do
    if grep -qw "${ctrl}" "${CGROOT}/cgroup.controllers" &&
       ! grep -qw "${ctrl}" "${CGROOT}/cgroup.subtree_control"; then
      echo "+${ctrl}" > "${CGROOT}/cgroup.subtree_control" || true
    fi
  done
}

reset_cgroup_dir() {
  local cg="$1"
  local pid
  if [[ ! -d "${cg}" ]]; then
    return 0
  fi
  if [[ -f "${cg}/cgroup.procs" && -f "${CGROOT}/cgroup.procs" ]]; then
    while IFS= read -r pid; do
      [[ -n "${pid}" ]] || continue
      echo "${pid}" > "${CGROOT}/cgroup.procs" 2>/dev/null || true
    done < "${cg}/cgroup.procs"
  fi
  rmdir "${cg}" 2>/dev/null || true
}

snapshot_vmstat() {
  local out="$1"
  python3 > "${out}" <<'PY'
keys = {
    "numa_hint_faults", "numa_pte_updates", "numa_hint_faults_local",
    "numa_pages_migrated", "pgdemote_direct", "pgdemote_kswapd",
    "pgmigrate_fail", "pgmigrate_success", "pgpromote_candidate",
    "pgpromote_candidate_nrl", "pgpromote_success", "pgscan_direct",
    "pgscan_kswapd", "pgsteal_direct", "pgsteal_kswapd",
}
with open("/proc/vmstat", "r", encoding="utf-8") as f:
    for raw in f:
        parts = raw.split()
        if len(parts) == 2 and parts[0] in keys:
            print(f"{parts[0]} {parts[1]}")
PY
}

snapshot_cgroup_stats() {
  local cg="$1"
  local out="$2"
  python3 - "$cg" > "${out}" <<'PY'
import os
import sys

cg = sys.argv[1]

def pick(name):
    for path in (os.path.join(cg, name), os.path.join(cg, f"memory.{name}")):
        if os.path.isfile(path):
            return path
    return None

def parse_flat(path):
    data = {}
    if not path:
        return data
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            parts = raw.strip().split()
            if len(parts) == 2:
                try:
                    data[parts[0]] = int(parts[1])
                except ValueError:
                    data[parts[0]] = parts[1]
    return data

for prefix, path in (
    ("MEMSTAT", pick("stat")),
    ("RECLAIMD", pick("reclaimd_state")),
    ("MIGRATE", pick("numa_migrate_state")),
):
    data = parse_flat(path)
    for key in sorted(data):
        print(f"{prefix}.{key} {data[key]}")
PY
}

write_diff() {
  local before="$1"
  local after="$2"
  local out="$3"
  python3 - "$before" "$after" > "${out}" <<'PY'
import sys

def load(path):
    data = {}
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            parts = raw.strip().split(None, 1)
            if len(parts) == 2:
                try:
                    data[parts[0]] = int(parts[1])
                except ValueError:
                    pass
    return data

before = load(sys.argv[1])
after = load(sys.argv[2])
for key in sorted(set(before) | set(after)):
    print(f"{key} {after.get(key, 0) - before.get(key, 0)}")
PY
}

snapshot_live_sample() {
  local cg="$1"
  local out="$2"
  local start_ms="$3"
  local sample_index="$4"
  python3 - "$cg" "$start_ms" "$sample_index" >> "${out}" <<'PY'
import os
import sys
import time

cg = sys.argv[1]
start_ms = int(sys.argv[2])
sample = int(sys.argv[3])
now_ms = int(time.time() * 1000)

def pick(name):
    for path in (os.path.join(cg, name), os.path.join(cg, f"memory.{name}")):
        if os.path.isfile(path):
            return path
    return None

def flat(path):
    data = {}
    if not path:
        return data
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            parts = raw.strip().split()
            if len(parts) == 2:
                try:
                    data[parts[0]] = int(parts[1])
                except ValueError:
                    pass
    return data

def numa(path):
    data = {}
    if not path:
        return data
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            parts = raw.strip().split()
            if not parts:
                continue
            key = parts[0]
            for item in parts[1:]:
                if "=" not in item:
                    continue
                node, value = item.split("=", 1)
                try:
                    data[f"{key}_{node.lower()}"] = int(value)
                except ValueError:
                    pass
    return data

def vmstat():
    keys = {
        "numa_hint_faults", "numa_pte_updates", "numa_hint_faults_local",
        "numa_pages_migrated", "pgdemote_direct", "pgdemote_kswapd",
        "pgmigrate_fail", "pgmigrate_success", "pgpromote_candidate",
        "pgpromote_candidate_nrl", "pgpromote_success",
    }
    data = {}
    with open("/proc/vmstat", "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            parts = raw.split()
            if len(parts) == 2 and parts[0] in keys:
                try:
                    data[parts[0]] = int(parts[1])
                except ValueError:
                    pass
    return data

def read_text(path):
    try:
        return open(path, "r", encoding="utf-8", errors="replace").read().strip()
    except Exception:
        return ""

stat = flat(pick("stat"))
migrate = flat(pick("numa_migrate_state"))
reclaimd = flat(pick("reclaimd_state"))
numa_stat = numa(pick("numa_stat"))
vm = vmstat()
node_bal = read_text(pick("node_balancing"))

fields = [
    sample, now_ms - start_ms, node_bal,
    stat.get("numa_hint_faults", 0), stat.get("numa_pte_updates", 0),
    stat.get("pgpromote_success", 0), stat.get("pgdemote_direct", 0),
    stat.get("pgdemote_kswapd", 0),
    migrate.get("numa_migrate_success_total", 0),
    migrate.get("numa_migrate_success_promotion", 0),
    migrate.get("numa_local_fault_on_tiering", 0),
    migrate.get("numa_local_fault_pte_updates", 0),
    migrate.get("numa_local_fault_refault", 0),
    migrate.get("numa_local_fault_refault_hit", 0),
    migrate.get("numa_local_fault_lost", 0),
    reclaimd.get("node0_capacity", 0),
    reclaimd.get("node0_usage_lru", 0),
    reclaimd.get("node0_usage_exact", 0),
    reclaimd.get("node0_over_high", 0),
    numa_stat.get("anon_n0", 0), numa_stat.get("anon_n1", 0),
    vm.get("numa_hint_faults", 0), vm.get("numa_pte_updates", 0),
    vm.get("numa_pages_migrated", 0), vm.get("pgpromote_success", 0),
    vm.get("pgdemote_direct", 0), vm.get("pgdemote_kswapd", 0),
]
print(",".join(str(x) for x in fields))
PY
}

start_live_sampler() {
  local cg="$1"
  local out="$2"
  local stop_file="$3"
  local interval="$4"
  printf '%s\n' "sample,elapsed_ms,node_balancing,cg_numa_hint_faults,cg_numa_pte_updates,cg_pgpromote_success,cg_pgdemote_direct,cg_pgdemote_kswapd,cg_migrate_total,cg_migrate_promotion,cg_local_fault_on_tiering,cg_local_fault_pte_updates,cg_local_fault_refault,cg_local_fault_refault_hit,cg_local_fault_lost,reclaimd_node0_capacity,reclaimd_node0_usage_lru,reclaimd_node0_usage_exact,reclaimd_node0_over_high,anon_n0,anon_n1,vm_numa_hint_faults,vm_numa_pte_updates,vm_numa_pages_migrated,vm_pgpromote_success,vm_pgdemote_direct,vm_pgdemote_kswapd" > "${out}"
  (
    local start_ms sample
    start_ms="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"
    sample=0
    while [[ ! -e "${stop_file}" ]]; do
      snapshot_live_sample "${cg}" "${out}" "${start_ms}" "${sample}" || true
      sample=$((sample + 1))
      sleep "${interval}" || break
    done
    snapshot_live_sample "${cg}" "${out}" "${start_ms}" "${sample}" || true
  ) >/dev/null 2>>"${out}.sampler.err" &
  echo $!
}

read_migrate_key() {
  local cg="$1"
  local key="$2"
  local file
  file="$(pick_knob_file "${cg}" "numa_migrate_state")" || {
    echo 0
    return
  }
  awk -v key="${key}" '$1 == key { print $2; found = 1 } END { if (!found) print 0 }' "${file}"
}

run_local_util_controller() {
  local cg="$1"
  local stop_file="$2"
  local window_sec="${LOCAL_UTIL_ADAPT_WINDOW_SEC}"
  local threshold_pct="${LOCAL_UTIL_ADAPT_THRESHOLD_PCT}"
  local consecutive_target="${LOCAL_UTIL_ADAPT_CONSECUTIVE}"
  local min_pte="${LOCAL_UTIL_ADAPT_MIN_PTE_UPDATES}"
  local last_pte last_hit last_refault last_lost
  local cur_pte cur_hit cur_refault cur_lost
  local delta_pte delta_hit delta_refault delta_lost
  local util_bp util_whole util_frac consecutive elapsed window
  local started_ms now_ms node_balancing

  last_pte="$(read_migrate_key "${cg}" "numa_local_fault_pte_updates")"
  last_hit="$(read_migrate_key "${cg}" "numa_local_fault_refault_hit")"
  last_refault="$(read_migrate_key "${cg}" "numa_local_fault_refault")"
  last_lost="$(read_migrate_key "${cg}" "numa_local_fault_lost")"
  started_ms="$(date +%s%3N)"
  consecutive=0
  window=0

  printf 'event,timestamp,elapsed_ms,window,window_sec,threshold_pct,min_pte_updates,pte_delta,hit_delta,refault_delta,lost_delta,util_pct,consecutive,node_balancing\n'
  printf 'start,%s,0,0,%s,%s,%s,0,0,0,0,0.00,0,%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${window_sec}" "${threshold_pct}" "${min_pte}" \
    "$(read_knob "${cg}" "node_balancing" 2>/dev/null | tr -d '\n')"

  while [[ ! -f "${stop_file}" ]]; do
    sleep "${window_sec}" || break
    [[ ! -f "${stop_file}" ]] || break
    window=$((window + 1))
    cur_pte="$(read_migrate_key "${cg}" "numa_local_fault_pte_updates")"
    cur_hit="$(read_migrate_key "${cg}" "numa_local_fault_refault_hit")"
    cur_refault="$(read_migrate_key "${cg}" "numa_local_fault_refault")"
    cur_lost="$(read_migrate_key "${cg}" "numa_local_fault_lost")"
    delta_pte=$((cur_pte - last_pte))
    delta_hit=$((cur_hit - last_hit))
    delta_refault=$((cur_refault - last_refault))
    delta_lost=$((cur_lost - last_lost))
    last_pte="${cur_pte}"
    last_hit="${cur_hit}"
    last_refault="${cur_refault}"
    last_lost="${cur_lost}"
    if (( delta_pte > 0 )); then
      util_bp=$((delta_hit * 10000 / delta_pte))
    else
      util_bp=0
    fi
    if (( delta_pte >= min_pte && util_bp >= threshold_pct * 100 )); then
      consecutive=$((consecutive + 1))
    else
      consecutive=0
    fi
    util_whole=$((util_bp / 100))
    util_frac=$((util_bp % 100))
    now_ms="$(date +%s%3N)"
    elapsed=$((now_ms - started_ms))
    node_balancing="$(read_knob "${cg}" "node_balancing" 2>/dev/null | tr -d '\n')"
    printf 'sample,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s.%02d,%s,%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${elapsed}" "${window}" \
      "${window_sec}" "${threshold_pct}" "${min_pte}" "${delta_pte}" \
      "${delta_hit}" "${delta_refault}" "${delta_lost}" "${util_whole}" \
      "${util_frac}" "${consecutive}" "${node_balancing}"
    if (( consecutive >= consecutive_target )); then
      write_knob "${cg}" "node_balancing" 0
      node_balancing="$(read_knob "${cg}" "node_balancing" 2>/dev/null | tr -d '\n')"
      now_ms="$(date +%s%3N)"
      elapsed=$((now_ms - started_ms))
      printf 'off,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s.%02d,%s,%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${elapsed}" "${window}" \
        "${window_sec}" "${threshold_pct}" "${min_pte}" "${delta_pte}" \
        "${delta_hit}" "${delta_refault}" "${delta_lost}" "${util_whole}" \
        "${util_frac}" "${consecutive}" "${node_balancing}"
      break
    fi
  done
}

configure_globals() {
  mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
  write_optional /proc/sys/kernel/numa_balancing "${GLOBAL_NUMA_ON}"
  write_optional /sys/kernel/mm/numa/demotion_enabled 1
  write_optional /sys/kernel/mm/numa/demotion_target "${LOCAL_NODE} ${REMOTE_NODE}"
  write_optional /sys/kernel/debug/sched/numa_balancing/scan_size_mb "${NUMA_SCAN_SIZE_MB}"
  write_optional /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms "${NUMA_SCAN_PERIOD_MIN_MS}"
  if [[ -f /sys/kernel/mm/lru_gen/enabled ]]; then
    echo "${MGLRU_ENABLED_VALUE}" > /sys/kernel/mm/lru_gen/enabled || true
  fi
}

setup_cgroup() {
  local cg="$1"
  local policy="$2"
  reset_cgroup_dir "${cg}"
  mkdir -p "${cg}"
  [[ -f "${cg}/cpuset.mems" ]] && echo "${CPUSET_MEMS}" > "${cg}/cpuset.mems"
  [[ -f "${cg}/cpuset.cpus" ]] && echo "${CPUSET_CPUS}" > "${cg}/cpuset.cpus"

  write_knob "${cg}" "node_capacity" "${LOCAL_NODE} ${CAPACITY_PAGES}"
  write_knob_optional "${cg}" "numa_balancing_fast_scan" "${NUMA_FAST_SCAN}"
  write_knob_optional "${cg}" "numa_balancing_hot_threshold_ms" "${HOT_THRESHOLD_MS}"
  write_knob_optional "${cg}" "numa_migration_stop_enabled" 0
  write_knob_optional "${cg}" "numa_pingpong_stat_enabled" 0
  write_knob_optional "${cg}" "numa_promote_sample_stat_enabled" 0
  write_knob_optional "${cg}" "numa_local_fault_refault_hit_ms" "${NUMA_LOCAL_FAULT_REFAULT_HIT_MS}"
  write_knob_optional "${cg}" "node_force_lru_evict" "${LOCAL_NODE} 1"

  case "${policy}" in
    off)
      write_knob "${cg}" "node_balancing" 0
      if [[ "${OFF_DEMOTION_ON}" == "1" ]]; then
        write_knob "${cg}" "kswapd_demotion_enabled" "${KSWAPD_DEMOTION_ON}"
      else
        write_knob "${cg}" "kswapd_demotion_enabled" 0
      fi
      write_knob_optional "${cg}" "numa_local_fault_on_tiering" 0
      ;;
    on)
      write_knob "${cg}" "node_balancing" "${NODE_BALANCING_ON}"
      write_knob "${cg}" "kswapd_demotion_enabled" "${KSWAPD_DEMOTION_ON}"
      write_knob_optional "${cg}" "numa_local_fault_on_tiering" 0
      ;;
    ours)
      write_knob "${cg}" "node_balancing" "${NODE_BALANCING_ON}"
      write_knob "${cg}" "kswapd_demotion_enabled" "${KSWAPD_DEMOTION_ON}"
      write_knob "${cg}" "numa_local_fault_on_tiering" "${NUMA_LOCAL_FAULT_ON_TIERING}"
      ;;
    *)
      echo "unknown policy: ${policy}" >&2
      return 1
      ;;
  esac
}

run_policy() {
  local policy="$1"
  local label="${2:-${policy}}"
  local cg="${CGROOT}/${CG_PREFIX}_${label}_${RUN_ID}"
  local dir="${RUN_ROOT}/${label}"
  local stop_file sampler_pid controller_pid start_s end_s rc

  mkdir -p "${dir}"
  log "policy=${policy} setup cgroup=${cg}"
  setup_cgroup "${cg}" "${policy}"

  {
    echo "policy=${policy}"
    echo "label=${label}"
    echo "command=${PR_BIN} ${GAPBS_INPUT_DESC} -i${PR_MAX_ITERS} -t${PR_TOL} -n${PR_TRIALS}"
    echo "graph_file=${GAPBS_GRAPH_FILE}"
    echo "prebuild_graph=${GAPBS_PREBUILD_GRAPH}"
    echo "capacity_pages=${CAPACITY_PAGES}"
    echo "scan_size_mb=${NUMA_SCAN_SIZE_MB}"
    echo "scan_period_min_ms=${NUMA_SCAN_PERIOD_MIN_MS}"
    echo "fast_scan=${NUMA_FAST_SCAN}"
    echo "global_numa_balancing=$(read_optional /proc/sys/kernel/numa_balancing | tr -d '\n')"
    echo "mglru=$(read_optional /sys/kernel/mm/lru_gen/enabled | tr -d '\n')"
    echo "node_balancing=$(read_knob "${cg}" node_balancing | tr -d '\n')"
    echo "kswapd_demotion_enabled=$(read_knob "${cg}" kswapd_demotion_enabled | tr -d '\n')"
    echo "local_fault_on_tiering=$(read_knob "${cg}" numa_local_fault_on_tiering 2>/dev/null | tr -d '\n' || echo 0)"
  } > "${dir}/run_config.txt"

  snapshot_vmstat "${dir}/vmstat.before"
  snapshot_cgroup_stats "${cg}" "${dir}/cgroup.before"
  stop_file="${dir}/stop-sampling"
  rm -f "${stop_file}"
  sampler_pid="$(start_live_sampler "${cg}" "${dir}/samples.csv" "${stop_file}" "${LIVE_SAMPLE_SEC}")"

  controller_pid=""
  if [[ "${policy}" == "ours" ]]; then
    run_local_util_controller "${cg}" "${stop_file}" > "${dir}/controller.csv" &
    controller_pid="$!"
  fi

  start_s="$(date +%s)"
  set +e
  timeout "${TIMEOUT_SEC}" bash -c \
    "echo \$\$ > '${cg}/cgroup.procs'; exec env OMP_NUM_THREADS='${OMP_THREADS}' OMP_PROC_BIND=true OMP_PLACES=cores '${PR_BIN}' '${GAPBS_INPUT_OPT}' '${GAPBS_INPUT_VALUE}' -i'${PR_MAX_ITERS}' -t'${PR_TOL}' -n'${PR_TRIALS}'" \
    > "${dir}/stdout.log" 2> "${dir}/stderr.log"
  rc=$?
  set -e
  end_s="$(date +%s)"

  touch "${stop_file}"
  wait "${sampler_pid}" 2>/dev/null || true
  if [[ -n "${controller_pid}" ]]; then
    wait "${controller_pid}" 2>/dev/null || true
  fi

  snapshot_vmstat "${dir}/vmstat.after"
  snapshot_cgroup_stats "${cg}" "${dir}/cgroup.after"
  write_diff "${dir}/vmstat.before" "${dir}/vmstat.after" "${dir}/vmstat.diff"
  write_diff "${dir}/cgroup.before" "${dir}/cgroup.after" "${dir}/cgroup.diff"
  {
    echo "returncode=${rc}"
    echo "elapsed_s=$((end_s - start_s))"
  } > "${dir}/status.txt"
  reset_cgroup_dir "${cg}"
  log "policy=${policy} done rc=${rc} elapsed_s=$((end_s - start_s))"
  return 0
}

ORIG_NUMA_BALANCING="$(read_optional /proc/sys/kernel/numa_balancing || true)"
ORIG_DEMOTION_ENABLED="$(read_optional /sys/kernel/mm/numa/demotion_enabled || true)"
ORIG_DEMOTION_TARGET="$(read_optional /sys/kernel/mm/numa/demotion_target || true)"
trap 'write_optional /proc/sys/kernel/numa_balancing "${ORIG_NUMA_BALANCING:-0}"; write_optional /sys/kernel/mm/numa/demotion_enabled "${ORIG_DEMOTION_ENABLED:-0}"; write_optional /sys/kernel/mm/numa/demotion_target "${ORIG_DEMOTION_TARGET%%$'\''\n'\''*}"' EXIT

configure_globals
enable_controllers

log "uname=$(uname -a)"
log "PR=$(${PR_BIN} -h 2>&1 | head -1 || true)"
prepare_gapbs_graph

IFS=',' read -ra POLICY_LIST <<< "${POLICIES}"
IFS=',' read -ra PERIOD_LIST <<< "${SCAN_PERIODS}"
for raw_period in "${PERIOD_LIST[@]}"; do
  period="$(echo "${raw_period}" | xargs)"
  [[ -n "${period}" ]] || continue
  NUMA_SCAN_PERIOD_MIN_MS="${period}"
  configure_globals
  for raw_policy in "${POLICY_LIST[@]}"; do
    policy="$(echo "${raw_policy}" | xargs)"
    [[ -n "${policy}" ]] || continue
    run_policy "${policy}" "p${period}"
  done
done

log "artifacts ${RUN_ROOT}"
