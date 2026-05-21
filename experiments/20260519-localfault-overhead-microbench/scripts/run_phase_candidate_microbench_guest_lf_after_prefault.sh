#!/usr/bin/env bash
set -euo pipefail

# Guest-side runner. Run as root inside the QEMU VM.
# It compares short timeout-bounded mbench candidate patterns under
# migration-off and migration-on memcg policies, while always collecting
# cgroup/vmstat before/after counters.

MBENCH="${MBENCH:-/root/mbench}"
OUTDIR="${OUTDIR:-/tmp/phase_candidate_microbench}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
CGROOT="${CGROOT:-/sys/fs/cgroup}"
CG_PREFIX="${CG_PREFIX:-phasecand}"

LOCAL_NODE="${LOCAL_NODE:-0}"
REMOTE_NODE="${REMOTE_NODE:-1}"
CPUSET_CPUS="${CPUSET_CPUS:-0-31}"
CPUSET_MEMS="${CPUSET_MEMS:-${LOCAL_NODE},${REMOTE_NODE}}"
CAPACITY_PAGES="${CAPACITY_PAGES:-4194304}" # 16 GiB / 4 KiB
THREADS="${THREADS:-32}"

ARENA_SIZE="${ARENA_SIZE:-64G}"
SAMPLE_MS="${SAMPLE_MS:-1000}"
OPS_PER_PASS="${OPS_PER_PASS:-65536}"
PAUSE_NS="${PAUSE_NS:-100000}"
TIMEOUT_SEC="${TIMEOUT_SEC:-900}"
REPS="${REPS:-1}"
POLICIES="${POLICIES:-on}"
CANDIDATES="${CANDIDATES:-phase_mulshift4g_sparse64}"

NODE_BALANCING_ON="${NODE_BALANCING_ON:-2}"
KSWAPD_DEMOTION_ON="${KSWAPD_DEMOTION_ON:-1}"
OFF_DEMOTION_ON="${OFF_DEMOTION_ON:-0}"
GLOBAL_NUMA_ON="${GLOBAL_NUMA_ON:-2}"
NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-4096}"
NUMA_SCAN_PERIOD_MIN_MS="${NUMA_SCAN_PERIOD_MIN_MS:-}"
NUMA_FAST_SCAN="${NUMA_FAST_SCAN:-0}"
HOT_THRESHOLD_MS="${HOT_THRESHOLD_MS:-0}"
MGLRU_ENABLED_VALUE="${MGLRU_ENABLED_VALUE:-0x0007}"
REMOTE_FIRSTTOUCH_SEC="${REMOTE_FIRSTTOUCH_SEC:-8}"
PHASE_MS="${PHASE_MS:-60000}"
PHASE_REPEAT="${PHASE_REPEAT:-3}"
LIVE_SAMPLE_SEC="${LIVE_SAMPLE_SEC:-1}"
PHASE_CONTROLLER_DELAY_SEC="${PHASE_CONTROLLER_DELAY_SEC:-0}"
PHASE_SPARSE_OFF_DELAY_SEC="${PHASE_SPARSE_OFF_DELAY_SEC:-20}"
CANDIDATE_PHASE_FIRST_KIND="${CANDIDATE_PHASE_FIRST_KIND:-friendly}"
MBENCH_FORCE_DURATION_MS="${MBENCH_FORCE_DURATION_MS:-}"
PREFAULT_PHASE_GATE="${PREFAULT_PHASE_GATE:-0}"
PREFAULT_READY_TIMEOUT_SEC="${PREFAULT_READY_TIMEOUT_SEC:-240}"
PREFAULT_SETTLE_RECLAIMD="${PREFAULT_SETTLE_RECLAIMD:-1}"
PREFAULT_SETTLE_TIMEOUT_SEC="${PREFAULT_SETTLE_TIMEOUT_SEC:-120}"
PREFAULT_SETTLE_QUIET_SEC="${PREFAULT_SETTLE_QUIET_SEC:-1}"
PERF_STAT="${PERF_STAT:-0}"
PERF_EVENTS="${PERF_EVENTS:-cycles,instructions,cache-references,cache-misses,dTLB-load-misses,LLC-load-misses,branches,branch-misses}"
PHASE_STAT_SUMMARIZER="${PHASE_STAT_SUMMARIZER:-/root/summarize_phase_stat_probe.py}"
NUMA_MIGRATION_STOP_ENABLED="${NUMA_MIGRATION_STOP_ENABLED:-0}"
NUMA_PINGPONG_STAT_ENABLED="${NUMA_PINGPONG_STAT_ENABLED:-0}"
NUMA_PROMOTE_SAMPLE_STAT_ENABLED="${NUMA_PROMOTE_SAMPLE_STAT_ENABLED:-1}"
NUMA_PROMOTE_SAMPLE_RATE="${NUMA_PROMOTE_SAMPLE_RATE:-10}"
NUMA_LOCAL_FAULT_ON_TIERING="${NUMA_LOCAL_FAULT_ON_TIERING:-0}"
NUMA_LOCAL_FAULT_DEFER_UNTIL_AFTER_PREFAULT="${NUMA_LOCAL_FAULT_DEFER_UNTIL_AFTER_PREFAULT:-1}"
NUMA_LOCAL_FAULT_REFAULT_HIT_MS="${NUMA_LOCAL_FAULT_REFAULT_HIT_MS:-1000}"
LOCAL_UTIL_ADAPT_WINDOW_SEC="${LOCAL_UTIL_ADAPT_WINDOW_SEC:-10}"
LOCAL_UTIL_ADAPT_THRESHOLD_PCT="${LOCAL_UTIL_ADAPT_THRESHOLD_PCT:-80}"
LOCAL_UTIL_ADAPT_CONSECUTIVE="${LOCAL_UTIL_ADAPT_CONSECUTIVE:-3}"
LOCAL_UTIL_ADAPT_MIN_PTE_UPDATES="${LOCAL_UTIL_ADAPT_MIN_PTE_UPDATES:-1000}"
LOCAL_UTIL_ADAPT_USE_WINDOW_BUCKETS="${LOCAL_UTIL_ADAPT_USE_WINDOW_BUCKETS:-1}"
LOCAL_UTIL_ADAPT_EVAL_LAG="${LOCAL_UTIL_ADAPT_EVAL_LAG:-1}"

log() {
  printf '[phase-candidate-guest] %s\n' "$*"
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

if [[ ! -x "${MBENCH}" ]]; then
  echo "mbench binary not executable: ${MBENCH}" >&2
  exit 1
fi

RUN_ROOT="${OUTDIR}/${RUN_ID}"
mkdir -p "${RUN_ROOT}"

ORIG_NUMA_BALANCING=""
ORIG_DEMOTION_ENABLED=""
ORIG_DEMOTION_TARGET=""
ORIG_NUMA_SCAN_SIZE_MB=""
ORIG_NUMA_SCAN_PERIOD_MIN_MS=""

read_optional() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    cat "${path}"
  fi
}

write_optional() {
  local path="$1"
  local value="$2"
  if [[ -w "${path}" ]]; then
    echo "${value}" > "${path}" || true
  fi
}

save_original_globals() {
  ORIG_NUMA_BALANCING="$(read_optional /proc/sys/kernel/numa_balancing || true)"
  ORIG_DEMOTION_ENABLED="$(read_optional /sys/kernel/mm/numa/demotion_enabled || true)"
  ORIG_DEMOTION_TARGET="$(read_optional /sys/kernel/mm/numa/demotion_target || true)"
  mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
  ORIG_NUMA_SCAN_SIZE_MB="$(read_optional /sys/kernel/debug/sched/numa_balancing/scan_size_mb || true)"
  ORIG_NUMA_SCAN_PERIOD_MIN_MS="$(read_optional /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms || true)"
}

restore_globals() {
  if [[ -n "${ORIG_NUMA_BALANCING}" ]]; then
    write_optional /proc/sys/kernel/numa_balancing "${ORIG_NUMA_BALANCING}"
  fi
  if [[ -n "${ORIG_DEMOTION_ENABLED}" ]]; then
    write_optional /sys/kernel/mm/numa/demotion_enabled "${ORIG_DEMOTION_ENABLED}"
  fi
  if [[ -n "${ORIG_DEMOTION_TARGET}" ]]; then
    write_optional /sys/kernel/mm/numa/demotion_target "${ORIG_DEMOTION_TARGET%%$'\n'*}"
  fi
  if [[ -n "${ORIG_NUMA_SCAN_SIZE_MB}" ]]; then
    write_optional /sys/kernel/debug/sched/numa_balancing/scan_size_mb "${ORIG_NUMA_SCAN_SIZE_MB}"
  fi
  if [[ -n "${ORIG_NUMA_SCAN_PERIOD_MIN_MS}" ]]; then
    write_optional /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms "${ORIG_NUMA_SCAN_PERIOD_MIN_MS}"
  fi
}

trap restore_globals EXIT
save_original_globals

if [[ -n "${NUMA_SCAN_SIZE_MB}" ]]; then
  mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
  write_optional /sys/kernel/debug/sched/numa_balancing/scan_size_mb "${NUMA_SCAN_SIZE_MB}"
fi
if [[ -n "${NUMA_SCAN_PERIOD_MIN_MS}" ]]; then
  mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
  write_optional /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms "${NUMA_SCAN_PERIOD_MIN_MS}"
fi

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

  knob="$(pick_knob_file "${cg}" "${name}")" || return 1
  echo "${value}" > "${knob}"
}

read_knob() {
  local cg="$1"
  local name="$2"
  local knob

  knob="$(pick_knob_file "${cg}" "${name}")" || return 1
  cat "${knob}"
}

write_knob_optional() {
  write_knob "$@" 2>/dev/null || true
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
    "numa_miss",
    "numa_other",
    "numa_hint_faults",
	    "numa_pte_updates",
	    "numa_hint_faults_local",
	    "numa_pages_migrated",
	    "pgdemote_promoted",
	    "pgdemote_promoted_referenced",
	    "pgdemote_direct",
	    "pgdemote_kswapd",
	    "pgmigrate_fail",
	    "pgmigrate_success",
	    "pgscan_direct",
	    "pgscan_kswapd",
	    "pgpromote_candidate",
	    "pgpromote_candidate_demoted",
	    "pgpromote_candidate_nrl",
	    "pgpromote_sampled",
	    "pgpromote_sampled_pte_updates",
	    "pgpromote_sampled_refault",
	    "pgpromote_sampled_lost",
	    "pgpromote_success",
    "pgsteal_direct",
    "pgsteal_kswapd",
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

def parse_stat(path):
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

def parse_kv(path):
    data = {}
    if not path:
        return data
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            parts = raw.strip().split(None, 1)
            if len(parts) == 2:
                data[parts[0]] = parts[1]
    return data

stat = parse_stat(pick("stat"))
reclaimd = parse_kv(pick("reclaimd_state"))
migrate = parse_kv(pick("numa_migrate_state"))

for key in (
    "numa_hint_faults",
    "numa_pte_updates",
    "numa_page_migrate",
    "pgdemote_direct",
    "pgdemote_kswapd",
    "pgpromote_success",
):
    print(f"MEMSTAT.{key} {stat.get(key, 0)}")

for key, raw in sorted(reclaimd.items()):
    try:
        value = int(raw)
    except ValueError:
        value = raw
    print(f"RECLAIMD.{key} {value}")

for key in sorted(migrate):
    try:
        value = int(migrate.get(key, "0"))
    except ValueError:
        value = migrate.get(key, "0")
    print(f"MIGRATE.{key} {value}")
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
sample_index = int(sys.argv[3])
now_ms = int(time.time() * 1000)

def pick(*names):
    for name in names:
        path = os.path.join(cg, name)
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

def parse_numa(path):
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

def parse_vmstat():
    keys = {
        "numa_hint_faults",
	        "numa_pte_updates",
	        "numa_hint_faults_local",
	        "numa_pages_migrated",
	        "pgdemote_promoted",
	        "pgdemote_promoted_referenced",
	        "pgdemote_direct",
	        "pgdemote_kswapd",
	        "pgmigrate_fail",
	        "pgmigrate_success",
	        "pgpromote_candidate",
	        "pgpromote_candidate_demoted",
	        "pgpromote_candidate_nrl",
	        "pgpromote_sampled",
	        "pgpromote_sampled_pte_updates",
	        "pgpromote_sampled_refault",
	        "pgpromote_sampled_lost",
	        "pgpromote_success",
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

def read_int(path):
    if not path:
        return 0
    try:
        return int(open(path, "r", encoding="utf-8", errors="replace").read().strip())
    except Exception:
        return 0

stat = parse_flat(pick("memory.stat", "stat"))
numa = parse_numa(pick("memory.numa_stat", "numa_stat"))
reclaimd = parse_flat(pick("memory.reclaimd_state", "reclaimd_state"))
migrate = parse_flat(pick("memory.numa_migrate_state", "numa_migrate_state"))
vmstat = parse_vmstat()

fields = [
    sample_index,
    now_ms - start_ms,
    read_int(pick("memory.current", "current")),
    numa.get("anon_n0", 0),
    numa.get("anon_n1", 0),
    numa.get("active_anon_n0", 0),
    numa.get("active_anon_n1", 0),
    numa.get("inactive_anon_n0", 0),
    numa.get("inactive_anon_n1", 0),
    numa.get("file_n0", 0),
    numa.get("file_n1", 0),
    numa.get("active_file_n0", 0),
    numa.get("active_file_n1", 0),
    numa.get("inactive_file_n0", 0),
    numa.get("inactive_file_n1", 0),
    stat.get("numa_hint_faults", 0),
    stat.get("numa_pte_updates", 0),
    stat.get("pgpromote_success", 0),
    stat.get("pgdemote_direct", 0),
    stat.get("pgdemote_kswapd", 0),
    migrate.get("numa_migrate_success_total", 0),
	    migrate.get("numa_migrate_success_promotion", 0),
	    migrate.get("numa_migrate_fail_promotion_blocked", 0),
	    migrate.get("numa_migrate_fail_promotion_over_high", 0),
	    migrate.get("numa_migrate_fail_promotion_alloc", 0),
	    migrate.get("debug_promote_enter", 0),
	    migrate.get("debug_promote_latency_pass", 0),
	    migrate.get("debug_promote_latency_fail", 0),
	    migrate.get("debug_promote_latency_under_1s", 0),
	    migrate.get("debug_promote_latency_1s_2s", 0),
	    migrate.get("debug_promote_latency_2s_4s", 0),
	    migrate.get("debug_promote_latency_4s_8s", 0),
	    migrate.get("debug_promote_latency_8s_60s", 0),
	    migrate.get("debug_promote_latency_over_60s", 0),
	    migrate.get("debug_promote_latency_last", 0),
	    migrate.get("debug_promote_threshold_last", 0),
	    migrate.get("debug_promote_wmark_bypass", 0),
	    migrate.get("debug_promote_wmark_no_bypass", 0),
	    migrate.get("debug_promote_rate_limited", 0),
	    migrate.get("debug_promote_return_true", 0),
	    migrate.get("debug_promote_wmark_ok_last", 0),
	    migrate.get("numa_demote_promoted", 0),
	    migrate.get("numa_demote_promoted_referenced", 0),
	    migrate.get("numa_promote_candidate_demoted", 0),
	    migrate.get("numa_migration_stop_effective", 0),
	    migrate.get("numa_earlystop_running", 0),
	    migrate.get("numa_earlystop_current_demote_promoted", 0),
	    migrate.get("numa_earlystop_cnt", 0),
	    migrate.get("numa_restart_cnt", 0),
	    migrate.get("numa_promote_sample_rate", 0),
	    migrate.get("numa_promote_sampled", 0),
	    migrate.get("numa_promote_sampled_pte_updates", 0),
	    migrate.get("numa_promote_sampled_refault", 0),
	    migrate.get("numa_promote_sampled_refault_total_ms", 0),
	    migrate.get("numa_promote_sampled_lost", 0),
	    migrate.get("numa_local_fault_on_tiering", 0),
	    migrate.get("numa_local_fault_refault_hit_ms", 0),
	    migrate.get("numa_local_fault_sampled", 0),
	    migrate.get("numa_local_fault_pte_updates", 0),
	    migrate.get("numa_local_fault_refault", 0),
	    migrate.get("numa_local_fault_refault_hit", 0),
	    migrate.get("numa_local_fault_refault_total_ms", 0),
	    migrate.get("numa_local_fault_lost", 0),
	    migrate.get("numa_local_fault_refault_rate_pct", 0),
	    migrate.get("numa_local_fault_refault_avg_us", 0),
	    reclaimd.get("run_count", 0),
	    reclaimd.get("wake_count", 0),
    reclaimd.get("mode", 0),
    reclaimd.get("node0_capacity", 0),
    reclaimd.get("node0_low_wmark", 0),
    reclaimd.get("node0_high_wmark", 0),
    reclaimd.get("node0_usage_lru", 0),
    reclaimd.get("node0_usage_exact", 0),
    reclaimd.get("node0_over_high", 0),
    vmstat.get("numa_hint_faults", 0),
    vmstat.get("numa_pte_updates", 0),
    vmstat.get("numa_hint_faults_local", 0),
    vmstat.get("numa_pages_migrated", 0),
    vmstat.get("pgpromote_success", 0),
    vmstat.get("pgdemote_direct", 0),
    vmstat.get("pgdemote_kswapd", 0),
    vmstat.get("pgmigrate_success", 0),
	    vmstat.get("pgmigrate_fail", 0),
	    vmstat.get("pgpromote_candidate", 0),
	    vmstat.get("pgpromote_candidate_nrl", 0),
	    vmstat.get("pgdemote_promoted", 0),
	    vmstat.get("pgdemote_promoted_referenced", 0),
	    vmstat.get("pgpromote_candidate_demoted", 0),
	    vmstat.get("pgpromote_sampled", 0),
	    vmstat.get("pgpromote_sampled_pte_updates", 0),
	    vmstat.get("pgpromote_sampled_refault", 0),
	    vmstat.get("pgpromote_sampled_lost", 0),
	]
print(",".join(str(x) for x in fields))
PY
}

start_live_sampler() {
  local cg="$1"
  local out="$2"
  local stop_file="$3"
  local interval="$4"

	  printf '%s\n' \
		    "sample,elapsed_ms,memory_current,anon_n0,anon_n1,active_anon_n0,active_anon_n1,inactive_anon_n0,inactive_anon_n1,file_n0,file_n1,active_file_n0,active_file_n1,inactive_file_n0,inactive_file_n1,cg_numa_hint_faults,cg_numa_pte_updates,cg_pgpromote_success,cg_pgdemote_direct,cg_pgdemote_kswapd,cg_migrate_total,cg_migrate_promotion,cg_migrate_fail_promotion_blocked,cg_migrate_fail_promotion_over_high,cg_migrate_fail_promotion_alloc,cg_dbg_promote_enter,cg_dbg_promote_latency_pass,cg_dbg_promote_latency_fail,cg_dbg_promote_latency_under_1s,cg_dbg_promote_latency_1s_2s,cg_dbg_promote_latency_2s_4s,cg_dbg_promote_latency_4s_8s,cg_dbg_promote_latency_8s_60s,cg_dbg_promote_latency_over_60s,cg_dbg_promote_latency_last,cg_dbg_promote_threshold_last,cg_dbg_promote_wmark_bypass,cg_dbg_promote_wmark_no_bypass,cg_dbg_promote_rate_limited,cg_dbg_promote_return_true,cg_dbg_promote_wmark_ok_last,cg_demote_promoted,cg_demote_promoted_referenced,cg_promote_candidate_demoted,cg_migration_stop_effective,cg_earlystop_running,cg_earlystop_current_demote_promoted,cg_earlystop_cnt,cg_restart_cnt,cg_promote_sample_rate,cg_promote_sampled,cg_promote_sampled_pte_updates,cg_promote_sampled_refault,cg_promote_sampled_refault_total_ms,cg_promote_sampled_lost,cg_local_fault_on_tiering,cg_local_fault_refault_hit_ms,cg_local_fault_sampled,cg_local_fault_pte_updates,cg_local_fault_refault,cg_local_fault_refault_hit,cg_local_fault_refault_total_ms,cg_local_fault_lost,cg_local_fault_refault_rate_pct,cg_local_fault_refault_avg_us,reclaimd_run_count,reclaimd_wake_count,reclaimd_mode,reclaimd_node0_capacity,reclaimd_node0_low_wmark,reclaimd_node0_high_wmark,reclaimd_node0_usage_lru,reclaimd_node0_usage_exact,reclaimd_node0_over_high,vm_numa_hint_faults,vm_numa_pte_updates,vm_numa_hint_faults_local,vm_numa_pages_migrated,vm_pgpromote_success,vm_pgdemote_direct,vm_pgdemote_kswapd,vm_pgmigrate_success,vm_pgmigrate_fail,vm_pgpromote_candidate,vm_pgpromote_candidate_nrl,vm_pgdemote_promoted,vm_pgdemote_promoted_referenced,vm_pgpromote_candidate_demoted,vm_pgpromote_sampled,vm_pgpromote_sampled_pte_updates,vm_pgpromote_sampled_refault,vm_pgpromote_sampled_lost" \
	    > "${out}"

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
  ) &
}

wait_for_prefault_ready() {
  local ready_file="$1"
  local pid="$2"
  local timeout_sec="$3"
  local waited=0
  local max_wait

  max_wait=$((timeout_sec * 10))
  while [[ ! -f "${ready_file}" ]]; do
    if ! kill -0 "${pid}" 2>/dev/null; then
      return 1
    fi
    if (( waited >= max_wait )); then
      return 124
    fi
    sleep 0.1
    waited=$((waited + 1))
  done

  return 0
}

read_reclaimd_field() {
  local cg="$1"
  local key="$2"
  local knob

  knob="$(pick_knob_file "${cg}" "reclaimd_state")" || {
    echo 0
    return 0
  }
  awk -v key="${key}" '$1 == key { print $2; found = 1 } END { if (!found) print 0 }' "${knob}"
}

wait_for_prefault_settle() {
  local cg="$1"
  local out="$2"
  local timeout_sec="$3"
  local quiet_sec="$4"
  local waited=0
  local max_wait quiet_needed quiet_count=0
  local running over_high usage_exact demoted
  local stat_file

  if [[ ! "${PREFAULT_SETTLE_RECLAIMD}" =~ ^(1|true|yes|on)$ ]]; then
    return 0
  fi

  max_wait=$((timeout_sec * 10))
  quiet_needed=$((quiet_sec * 10))
  if (( quiet_needed < 1 )); then
    quiet_needed=1
  fi
  : > "${out}"

  while true; do
    running="$(read_reclaimd_field "${cg}" "running")"
    over_high="$(read_reclaimd_field "${cg}" "node0_over_high")"
    usage_exact="$(read_reclaimd_field "${cg}" "node0_usage_exact")"
    stat_file="$(pick_knob_file "${cg}" "stat")" || stat_file=""
    if [[ -n "${stat_file}" ]]; then
      demoted="$(awk '$1 == "pgdemote_direct" || $1 == "pgdemote_kswapd" { sum += $2 } END { print sum + 0 }' \
        "${stat_file}" 2>/dev/null || echo 0)"
    else
      demoted=0
    fi
    printf 'waited_ms=%s running=%s over_high=%s node0_usage_exact=%s pgdemote_total=%s\n' \
      "$((waited * 100))" "${running}" "${over_high}" "${usage_exact}" "${demoted}" >> "${out}"

    if [[ "${running}" == "0" && "${over_high}" == "0" ]]; then
      quiet_count=$((quiet_count + 1))
      if (( quiet_count >= quiet_needed )); then
        return 0
      fi
    else
      quiet_count=0
    fi

    if (( waited >= max_wait )); then
      return 124
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
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

configure_policy_globals() {
  local policy="$1"

  case "${policy}" in
    off)
      if [[ "${OFF_DEMOTION_ON}" == "1" ]]; then
        write_optional /sys/kernel/mm/numa/demotion_enabled 1
        write_optional /sys/kernel/mm/numa/demotion_target "${LOCAL_NODE} ${REMOTE_NODE}"
      else
        write_optional /sys/kernel/mm/numa/demotion_enabled 0
      fi
      write_optional /proc/sys/kernel/numa_balancing 0
      ;;
    on|earlystop|adaptive_cgroup|adaptive_localutil)
      write_optional /sys/kernel/mm/numa/demotion_enabled 1
      write_optional /sys/kernel/mm/numa/demotion_target "${LOCAL_NODE} ${REMOTE_NODE}"
      if ! echo "${GLOBAL_NUMA_ON}" > /proc/sys/kernel/numa_balancing 2>/dev/null; then
        write_optional /proc/sys/kernel/numa_balancing 1
      fi
      ;;
    adaptive_global)
      write_optional /sys/kernel/mm/numa/demotion_enabled 1
      write_optional /sys/kernel/mm/numa/demotion_target "${LOCAL_NODE} ${REMOTE_NODE}"
      if [[ "${CANDIDATE_PHASE_FIRST_KIND:-friendly}" == "sparse" ]]; then
        write_optional /proc/sys/kernel/numa_balancing 0
      elif ! echo "${GLOBAL_NUMA_ON}" > /proc/sys/kernel/numa_balancing 2>/dev/null; then
        write_optional /proc/sys/kernel/numa_balancing 1
      fi
      ;;
    oracle_cgroup_global0|oracle_cgroup_global0_delay20)
      write_optional /sys/kernel/mm/numa/demotion_enabled 1
      write_optional /sys/kernel/mm/numa/demotion_target "${LOCAL_NODE} ${REMOTE_NODE}"
      write_optional /proc/sys/kernel/numa_balancing 0
      ;;
    *)
      echo "unknown policy: ${policy}" >&2
      return 1
      ;;
  esac
}

setup_cgroup() {
  local cg="$1"
  local policy="$2"

  reset_cgroup_dir "${cg}"
  mkdir -p "${cg}"

  if [[ -f "${cg}/cpuset.mems" ]]; then
    echo "${CPUSET_MEMS}" > "${cg}/cpuset.mems"
  fi
  if [[ -f "${cg}/cpuset.cpus" ]]; then
    echo "${CPUSET_CPUS}" > "${cg}/cpuset.cpus"
  fi

  write_knob "${cg}" "node_capacity" "${LOCAL_NODE} ${CAPACITY_PAGES}"
  case "${policy}" in
    off)
      write_knob "${cg}" "node_balancing" 0
      if [[ "${OFF_DEMOTION_ON}" == "1" ]]; then
        write_knob "${cg}" "kswapd_demotion_enabled" "${KSWAPD_DEMOTION_ON}"
      else
        write_knob "${cg}" "kswapd_demotion_enabled" 0
      fi
      ;;
    on|earlystop|adaptive_global|adaptive_localutil)
      write_knob "${cg}" "node_balancing" "${NODE_BALANCING_ON}"
      write_knob "${cg}" "kswapd_demotion_enabled" "${KSWAPD_DEMOTION_ON}"
      ;;
    adaptive_cgroup|oracle_cgroup_global0)
      if [[ "${CANDIDATE_PHASE_FIRST_KIND:-friendly}" == "sparse" ]]; then
        write_knob "${cg}" "node_balancing" 0
      else
        write_knob "${cg}" "node_balancing" "${NODE_BALANCING_ON}"
      fi
      write_knob "${cg}" "kswapd_demotion_enabled" "${KSWAPD_DEMOTION_ON}"
      ;;
    oracle_cgroup_global0_delay20)
      write_knob "${cg}" "node_balancing" "${NODE_BALANCING_ON}"
      write_knob "${cg}" "kswapd_demotion_enabled" "${KSWAPD_DEMOTION_ON}"
      ;;
  esac
	  write_knob "${cg}" "numa_balancing_fast_scan" "${NUMA_FAST_SCAN}"
	  write_knob "${cg}" "numa_balancing_hot_threshold_ms" "${HOT_THRESHOLD_MS}"
	  write_knob_optional "${cg}" "numa_migration_stop_enabled" "${NUMA_MIGRATION_STOP_ENABLED}"
		  write_knob_optional "${cg}" "numa_pingpong_stat_enabled" "${NUMA_PINGPONG_STAT_ENABLED}"
		  write_knob_optional "${cg}" "numa_promote_sample_stat_enabled" "${NUMA_PROMOTE_SAMPLE_STAT_ENABLED}"
		  write_knob_optional "${cg}" "numa_promote_sample_rate" "${NUMA_PROMOTE_SAMPLE_RATE}"
		  write_knob_optional "${cg}" "numa_local_fault_refault_hit_ms" "${NUMA_LOCAL_FAULT_REFAULT_HIT_MS}"
		  if [[ "${PREFAULT_PHASE_GATE}" =~ ^(1|true|yes|on)$ &&
		        "${NUMA_LOCAL_FAULT_DEFER_UNTIL_AFTER_PREFAULT}" =~ ^(1|true|yes|on)$ ]]; then
		    write_knob_optional "${cg}" "numa_local_fault_on_tiering" 0
		  else
		    write_knob_optional "${cg}" "numa_local_fault_on_tiering" "${NUMA_LOCAL_FAULT_ON_TIERING}"
		  fi
		  write_knob_optional "${cg}" "node_force_lru_evict" "${LOCAL_NODE} 1"
		}

policy_uses_phase_controller() {
  case "$1" in
    adaptive_global|adaptive_cgroup|oracle_cgroup_global0|oracle_cgroup_global0_delay20)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

policy_uses_local_util_controller() {
  case "$1" in
    adaptive_localutil)
      return 0 ;;
    *)
      return 1 ;;
  esac
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
  local use_window_buckets="${LOCAL_UTIL_ADAPT_USE_WINDOW_BUCKETS}"
  local eval_lag="${LOCAL_UTIL_ADAPT_EVAL_LAG}"
  local bucket_prefix bucket_seq bucket_pte bucket_hit bucket_refault bucket_lost
  local base_pte base_hit base_refault base_lost
  local cur_pte cur_hit cur_refault cur_lost
  local delta_pte delta_hit delta_refault delta_lost
  local access_bp access_whole access_frac
  local fast_bp fast_whole fast_frac
  local consecutive elapsed window window_seq
  local started_ms now_ms node_balancing

  if ! [[ "${window_sec}" =~ ^[0-9]+$ ]] || (( window_sec < 1 )); then
    window_sec=10
  fi
  if ! [[ "${threshold_pct}" =~ ^[0-9]+$ ]]; then
    threshold_pct=80
  fi
  if ! [[ "${consecutive_target}" =~ ^[0-9]+$ ]] || (( consecutive_target < 1 )); then
    consecutive_target=3
  fi
  if ! [[ "${min_pte}" =~ ^[0-9]+$ ]]; then
    min_pte=0
  fi
  if ! [[ "${use_window_buckets}" =~ ^[0-9]+$ ]]; then
    use_window_buckets=1
  fi
  if ! [[ "${eval_lag}" =~ ^[0-9]+$ ]]; then
    eval_lag=1
  fi
  if (( eval_lag > 2 )); then
    eval_lag=2
  fi

  started_ms="$(date +%s%3N)"
  consecutive=0
  window=0

  window_seq="$(read_knob "${cg}" "numa_local_fault_window" 2>/dev/null | tr -d '\n' || echo 0)"
  printf 'event,timestamp,elapsed_ms,window,window_seq,window_sec,threshold_pct,min_pte_updates,pte_delta,hit_delta,refault_delta,lost_delta,access_pct,fast_pct,consecutive,node_balancing\n'
  printf 'start,%s,0,0,%s,%s,%s,%s,0,0,0,0,0.00,0.00,0,%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${window_seq}" \
    "${window_sec}" \
    "${threshold_pct}" \
    "${min_pte}" \
    "$(read_knob "${cg}" "node_balancing" 2>/dev/null | tr -d '\n')"

  while [[ ! -f "${stop_file}" ]]; do
    window=$((window + 1))
    write_knob_optional "${cg}" "numa_local_fault_window" 1
    window_seq="$(read_knob "${cg}" "numa_local_fault_window" 2>/dev/null | tr -d '\n' || echo 0)"
    base_pte="$(read_migrate_key "${cg}" "numa_local_fault_pte_updates")"
    base_hit="$(read_migrate_key "${cg}" "numa_local_fault_refault_hit")"
    base_refault="$(read_migrate_key "${cg}" "numa_local_fault_refault")"
    base_lost="$(read_migrate_key "${cg}" "numa_local_fault_lost")"

    sleep_seconds_or_stop "${stop_file}" "${window_sec}"
    [[ ! -f "${stop_file}" ]] || break

    cur_pte="$(read_migrate_key "${cg}" "numa_local_fault_pte_updates")"
    cur_hit="$(read_migrate_key "${cg}" "numa_local_fault_refault_hit")"
    cur_refault="$(read_migrate_key "${cg}" "numa_local_fault_refault")"
    cur_lost="$(read_migrate_key "${cg}" "numa_local_fault_lost")"
    delta_pte=$((cur_pte - base_pte))
    delta_hit=$((cur_hit - base_hit))
    delta_refault=$((cur_refault - base_refault))
    delta_lost=$((cur_lost - base_lost))

    if (( use_window_buckets != 0 )); then
      case "${eval_lag}" in
        0) bucket_prefix="current" ;;
        2) bucket_prefix="prev2" ;;
        *) bucket_prefix="prev" ;;
      esac
      bucket_seq="$(read_migrate_key "${cg}" "numa_local_fault_window_${bucket_prefix}_seq")"
      bucket_pte="$(read_migrate_key "${cg}" "numa_local_fault_window_${bucket_prefix}_pte_updates")"
      bucket_hit="$(read_migrate_key "${cg}" "numa_local_fault_window_${bucket_prefix}_refault_hit")"
      bucket_refault="$(read_migrate_key "${cg}" "numa_local_fault_window_${bucket_prefix}_refault")"
      bucket_lost="$(read_migrate_key "${cg}" "numa_local_fault_window_${bucket_prefix}_lost")"
      if (( bucket_seq > 0 )); then
        window_seq="${bucket_seq}"
        delta_pte="${bucket_pte}"
        delta_hit="${bucket_hit}"
        delta_refault="${bucket_refault}"
        delta_lost="${bucket_lost}"
      fi
    fi

    if (( delta_pte > 0 )); then
      access_bp=$((delta_refault * 10000 / delta_pte))
      fast_bp=$((delta_hit * 10000 / delta_pte))
    else
      access_bp=0
      fast_bp=0
    fi
    if (( delta_pte >= min_pte && access_bp >= threshold_pct * 100 )); then
      consecutive=$((consecutive + 1))
    else
      consecutive=0
    fi
    access_whole=$((access_bp / 100))
    access_frac=$((access_bp % 100))
    fast_whole=$((fast_bp / 100))
    fast_frac=$((fast_bp % 100))
    now_ms="$(date +%s%3N)"
    elapsed=$((now_ms - started_ms))
    node_balancing="$(read_knob "${cg}" "node_balancing" 2>/dev/null | tr -d '\n')"

    printf 'sample,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s.%02d,%s.%02d,%s,%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "${elapsed}" \
      "${window}" \
      "${window_seq}" \
      "${window_sec}" \
      "${threshold_pct}" \
      "${min_pte}" \
      "${delta_pte}" \
      "${delta_hit}" \
      "${delta_refault}" \
      "${delta_lost}" \
      "${access_whole}" \
      "${access_frac}" \
      "${fast_whole}" \
      "${fast_frac}" \
      "${consecutive}" \
      "${node_balancing}"

    if (( consecutive >= consecutive_target )); then
      write_knob "${cg}" "node_balancing" 0
      node_balancing="$(read_knob "${cg}" "node_balancing" 2>/dev/null | tr -d '\n')"
      now_ms="$(date +%s%3N)"
      elapsed=$((now_ms - started_ms))
      printf 'off,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s.%02d,%s.%02d,%s,%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "${elapsed}" \
        "${window}" \
        "${window_seq}" \
        "${window_sec}" \
        "${threshold_pct}" \
        "${min_pte}" \
        "${delta_pte}" \
        "${delta_hit}" \
        "${delta_refault}" \
        "${delta_lost}" \
        "${access_whole}" \
        "${access_frac}" \
        "${fast_whole}" \
        "${fast_frac}" \
        "${consecutive}" \
        "${node_balancing}"
      break
    fi
  done
}

phase_kind_for() {
  local phase="$1"
  local phase_kind="sparse"

  if [[ "${CANDIDATE_PHASE_FIRST_KIND:-friendly}" == "sparse" ]]; then
    if (( phase % 2 == 0 )); then
      phase_kind="friendly"
    fi
  elif (( phase % 2 == 1 )); then
    phase_kind="friendly"
  fi

  echo "${phase_kind}"
}

apply_phase_policy() {
  local cg="$1"
  local policy="$2"
  local phase="$3"
  local phase_kind

  phase_kind="$(phase_kind_for "${phase}")"

  if (( phase != 1 )); then
    case "${policy}:${phase_kind}" in
      adaptive_global:friendly)
        if ! echo "${GLOBAL_NUMA_ON}" > /proc/sys/kernel/numa_balancing 2>/dev/null; then
          write_optional /proc/sys/kernel/numa_balancing 1
        fi
        ;;
      adaptive_global:sparse)
        write_optional /proc/sys/kernel/numa_balancing 0
        ;;
      adaptive_cgroup:friendly)
        write_knob "${cg}" "node_balancing" "${NODE_BALANCING_ON}"
        ;;
      adaptive_cgroup:sparse)
        write_knob "${cg}" "node_balancing" 0
        ;;
      oracle_cgroup_global0:friendly)
        write_optional /proc/sys/kernel/numa_balancing 0
        write_knob "${cg}" "node_balancing" "${NODE_BALANCING_ON}"
        ;;
      oracle_cgroup_global0:sparse)
        write_optional /proc/sys/kernel/numa_balancing 0
        write_knob "${cg}" "node_balancing" 0
        ;;
      oracle_cgroup_global0_delay20:friendly)
        write_optional /proc/sys/kernel/numa_balancing 0
        write_knob "${cg}" "node_balancing" "${NODE_BALANCING_ON}"
        ;;
      oracle_cgroup_global0_delay20:sparse)
        write_optional /proc/sys/kernel/numa_balancing 0
        write_knob "${cg}" "node_balancing" "${NODE_BALANCING_ON}"
        ;;
    esac
  fi

  printf '%s phase=%s kind=%s policy=%s global=%s cgroup_node_balancing=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${phase}" \
    "${phase_kind}" \
    "${policy}" \
    "$(read_optional /proc/sys/kernel/numa_balancing 2>/dev/null | tr -d '\n')" \
    "$(read_knob "${cg}" "node_balancing" 2>/dev/null | tr -d '\n')"
}

apply_delayed_phase_policy() {
  local cg="$1"
  local policy="$2"
  local phase="$3"
  local phase_kind

  phase_kind="$(phase_kind_for "${phase}")"

  case "${policy}:${phase_kind}" in
    oracle_cgroup_global0_delay20:sparse)
      write_optional /proc/sys/kernel/numa_balancing 0
      write_knob "${cg}" "node_balancing" 0
      printf '%s phase=%s kind=%s policy=%s action=delayed_off delay_sec=%s global=%s cgroup_node_balancing=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "${phase}" \
        "${phase_kind}" \
        "${policy}" \
        "${PHASE_SPARSE_OFF_DELAY_SEC}" \
        "$(read_optional /proc/sys/kernel/numa_balancing 2>/dev/null | tr -d '\n')" \
        "$(read_knob "${cg}" "node_balancing" 2>/dev/null | tr -d '\n')"
      ;;
  esac
}

sleep_seconds_or_stop() {
  local stop_file="$1"
  local remaining_sec="$2"

  while (( remaining_sec > 0 )); do
    [[ ! -f "${stop_file}" ]] || return 0
    sleep 1
    remaining_sec=$((remaining_sec - 1))
  done
}

sleep_phase_or_stop() {
  local stop_file="$1"
  sleep_seconds_or_stop "${stop_file}" "$(( (PHASE_MS + 999) / 1000 ))"
}

run_phase_policy_controller() {
  local cg="$1"
  local policy="$2"
  local stop_file="$3"
  local total_phases="${PHASE_COUNT:-$((PHASE_REPEAT * 2))}"
  local phase_sec="$(( (PHASE_MS + 999) / 1000 ))"
  local phase
  local phase_kind
  local sparse_off_delay_sec

  for phase in $(seq 1 "${total_phases}"); do
    [[ ! -f "${stop_file}" ]] || break
    apply_phase_policy "${cg}" "${policy}" "${phase}"
    phase_kind="$(phase_kind_for "${phase}")"
    sparse_off_delay_sec=0
    case "${policy}:${phase_kind}" in
      oracle_cgroup_global0_delay20:sparse)
        if [[ "${PHASE_SPARSE_OFF_DELAY_SEC}" =~ ^[0-9]+$ ]]; then
          sparse_off_delay_sec="${PHASE_SPARSE_OFF_DELAY_SEC}"
        fi
        ;;
    esac
    if (( sparse_off_delay_sec > 0 && sparse_off_delay_sec < phase_sec )); then
      sleep_seconds_or_stop "${stop_file}" "${sparse_off_delay_sec}"
      [[ ! -f "${stop_file}" ]] || break
      apply_delayed_phase_policy "${cg}" "${policy}" "${phase}"
      sleep_seconds_or_stop "${stop_file}" "$(( phase_sec - sparse_off_delay_sec ))"
    else
      sleep_phase_or_stop "${stop_file}"
    fi
  done
}

candidate_args() {
  local name="$1"

  CANDIDATE_PRIMARY="ops"
  CANDIDATE_KIND="unknown"
  CANDIDATE_REMOTE_FIRSTTOUCH=0
  CANDIDATE_PHASE_FIRST_KIND="friendly"
  CANDIDATE_ARGS=()

  case "${name}" in
    reuse_bw_read_512m)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="friendly"
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 512M --move-policy fixed --threads "${THREADS}")
      ;;
    dense_reuse_read_1g_remote)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="friendly"
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 1G --move-policy fixed --placement "bind:${REMOTE_NODE}" --threads "${THREADS}")
      ;;
    dense_reuse_read_1g_remoteft)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 1G --move-policy fixed --threads "${THREADS}")
      ;;
    dense_rf_read_256m)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 256M --move-policy fixed --threads "${THREADS}")
      ;;
    dense_rf_read_64m)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 64M --move-policy fixed --threads "${THREADS}")
      ;;
    dense_rf_read_128m)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 128M --move-policy fixed --threads "${THREADS}")
      ;;
    dense_rf_read_512m)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 512M --move-policy fixed --threads "${THREADS}")
      ;;
    dense_reuse_read_2g_remote)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="friendly"
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 2G --move-policy fixed --placement "bind:${REMOTE_NODE}" --threads "${THREADS}")
      ;;
    dense_reuse_read_2g_remoteft)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 2G --move-policy fixed --threads "${THREADS}")
      ;;
    dense_rf_write_1g)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode bw --bw-kernel write --window-size 1G --move-policy fixed --threads "${THREADS}")
      ;;
    dense_rf_copy_1g)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode bw --bw-kernel copy --window-size 1G --move-policy fixed --threads "${THREADS}")
      ;;
    dense_rf_copy_256m)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode bw --bw-kernel copy --window-size 256M --move-policy fixed --threads "${THREADS}")
      ;;
    dense_rf_triad_256m)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode bw --bw-kernel triad --window-size 256M --move-policy fixed --threads "${THREADS}")
      ;;
    dense_reuse_read_4g_remote)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="friendly"
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 4G --move-policy fixed --placement "bind:${REMOTE_NODE}" --threads "${THREADS}")
      ;;
	    dense_reuse_read_4g_remoteft)
	      CANDIDATE_PRIMARY="bytes"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_REMOTE_FIRSTTOUCH=1
	      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 4G --move-policy fixed --threads "${THREADS}")
	      ;;
	    pc_512m_remoteft)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_REMOTE_FIRSTTOUCH=1
	      CANDIDATE_ARGS=(--mode pc --window-size 512M --move-policy fixed --pc-chains 1 --threads "${THREADS}")
	      ;;
	    pc_1g_remoteft)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_REMOTE_FIRSTTOUCH=1
	      CANDIDATE_ARGS=(--mode pc --window-size 1G --move-policy fixed --pc-chains 1 --threads "${THREADS}")
	      ;;
	    pc_2g_remoteft)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_REMOTE_FIRSTTOUCH=1
	      CANDIDATE_ARGS=(--mode pc --window-size 2G --move-policy fixed --pc-chains 1 --threads "${THREADS}")
	      ;;
	    pc_4g_remoteft)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_REMOTE_FIRSTTOUCH=1
	      CANDIDATE_ARGS=(--mode pc --window-size 4G --move-policy fixed --pc-chains 1 --threads "${THREADS}")
	      ;;
	    pc_8g_remoteft)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_REMOTE_FIRSTTOUCH=1
	      CANDIDATE_ARGS=(--mode pc --window-size 8G --move-policy fixed --pc-chains 1 --threads "${THREADS}")
	      ;;
	    pc_64g_stride_remoteft)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="pointer-chase"
	      CANDIDATE_REMOTE_FIRSTTOUCH=1
	      CANDIDATE_ARGS=(--mode pc --window-size 64G --move-policy fixed --pc-chains 1 --pc-pattern stride --threads "${THREADS}")
	      ;;
	    pc_32g_stride_remoteft)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="pointer-chase"
	      CANDIDATE_REMOTE_FIRSTTOUCH=1
	      CANDIDATE_ARGS=(--mode pc --window-size 32G --move-policy fixed --pc-chains 1 --pc-pattern stride --threads "${THREADS}")
	      ;;
	    pc_48g_stride_remoteft)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="pointer-chase"
	      CANDIDATE_REMOTE_FIRSTTOUCH=1
	      CANDIDATE_ARGS=(--mode pc --window-size 48G --move-policy fixed --pc-chains 1 --pc-pattern stride --threads "${THREADS}")
	      ;;
    dense_reuse_read_16g_remoteft)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 16G --move-policy fixed --threads "${THREADS}")
      ;;
    skewed_hotset_16g_remoteft)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 16G --move-policy fixed --hotset-pages 4194304 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
    skew_rf_read_512m)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 512M --move-policy fixed --hotset-pages 131072 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
    skew_rf_read_1g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 1G --move-policy fixed --hotset-pages 262144 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
    skew_rf_read_2g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 2G --move-policy fixed --hotset-pages 524288 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
    skew_rf_read_4g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --move-policy fixed --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
    skew_rf_rw_1g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 1G --move-policy fixed --hotset-pages 262144 --hot-prob-pct 100 --hotset-read-pct 90 --hotset-write-pct 10 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
    skew_rf_rmw_1g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 1G --move-policy fixed --hotset-pages 262144 --hot-prob-pct 100 --hotset-read-pct 0 --hotset-write-pct 0 --hotset-rmw-pct 100 --threads "${THREADS}")
      ;;
    skew_rf_hot64m_win1g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 1G --move-policy fixed --hotset-pages 16384 --hot-prob-pct 98 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
    skew_rf_hot256m_win2g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 2G --move-policy fixed --hotset-pages 65536 --hot-prob-pct 98 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
    skew_rf_readmostly_hot256m_win2g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 2G --move-policy fixed --hotset-pages 65536 --hot-prob-pct 98 --hotset-read-pct 90 --hotset-write-pct 10 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
    skew_rf_read_1g_move_1s)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 1G --window-offset 0 --move-policy random --move-step 1G --move-min-offset 0 --move-max-offset 63G --move-interval-ms 1000 --hotset-pages 262144 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
    skew_rf_read_4g_move_5s)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --window-offset 0 --move-policy random --move-step 4G --move-min-offset 0 --move-max-offset 60G --move-interval-ms 5000 --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
    skew_rf_read_8g_move_1s_mulshift_persistent)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 8G --window-offset 0 --move-policy random --move-step 8G --move-min-offset 0 --move-max-offset 56G --move-interval-ms 1000 --hotset-pages 2097152 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift --threads "${THREADS}")
      ;;
    skew_rf_read_12g_move_1s_mulshift_persistent)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 12G --window-offset 0 --move-policy random --move-step 4G --move-min-offset 0 --move-max-offset 52G --move-interval-ms 1000 --hotset-pages 3145728 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift --threads "${THREADS}")
      ;;
    skew_rf_read_12g_move_500ms_mulshift_persistent)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 12G --window-offset 0 --move-policy random --move-step 4G --move-min-offset 0 --move-max-offset 52G --move-interval-ms 500 --hotset-pages 3145728 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift --threads "${THREADS}")
      ;;
    skew_rf_read_12g_move_250ms_mulshift_persistent)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 12G --window-offset 0 --move-policy random --move-step 4G --move-min-offset 0 --move-max-offset 52G --move-interval-ms 250 --hotset-pages 3145728 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift --threads "${THREADS}")
      ;;
    skew_rf_read_16g_move_1s_mulshift_persistent)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 16G --window-offset 0 --move-policy random --move-step 4G --move-min-offset 0 --move-max-offset 48G --move-interval-ms 1000 --hotset-pages 4194304 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift --threads "${THREADS}")
      ;;
    skew_rf_read_16g_move_3s_mulshift_persistent)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 16G --window-offset 0 --move-policy random --move-step 4G --move-min-offset 0 --move-max-offset 48G --move-interval-ms 3000 --hotset-pages 4194304 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift --threads "${THREADS}")
      ;;
    skew_rf_read_16g_move_500ms_mulshift_persistent)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 16G --window-offset 0 --move-policy random --move-step 4G --move-min-offset 0 --move-max-offset 48G --move-interval-ms 500 --hotset-pages 4194304 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift --threads "${THREADS}")
      ;;
    skew_rf_read_16g_move_250ms_mulshift_persistent)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 16G --window-offset 0 --move-policy random --move-step 4G --move-min-offset 0 --move-max-offset 48G --move-interval-ms 250 --hotset-pages 4194304 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift --threads "${THREADS}")
      ;;
    skew_rf_read_4g_move_15s)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --window-offset 0 --move-policy random --move-step 4G --move-min-offset 0 --move-max-offset 60G --move-interval-ms 15000 --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
    skew_rf_read_4g_move_15s_rss16g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --window-offset 0 --move-policy random --move-step 4G --move-min-offset 0 --move-max-offset 12G --move-interval-ms 15000 --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
    index_rf_uniform_1g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode irregular-index --index-kernel gather --index-distribution uniform --window-size 1G --move-policy fixed --threads "${THREADS}")
      ;;
    index_rf_zipf_1g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode irregular-index --index-kernel gather --index-distribution zipf --index-zipf-alpha 1.2 --window-size 1G --move-policy fixed --threads "${THREADS}")
      ;;
    index_rf_zipf_2g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode irregular-index --index-kernel gather --index-distribution zipf --index-zipf-alpha 1.2 --window-size 2G --move-policy fixed --threads "${THREADS}")
      ;;
    index_rf_zipf15_1g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode irregular-index --index-kernel gather --index-distribution zipf --index-zipf-alpha 1.5 --window-size 1G --move-policy fixed --threads "${THREADS}")
      ;;
    index_rf_zipf15_2g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode irregular-index --index-kernel gather --index-distribution zipf --index-zipf-alpha 1.5 --window-size 2G --move-policy fixed --threads "${THREADS}")
      ;;
    index_rf_zipf2_1g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode irregular-index --index-kernel gather --index-distribution zipf --index-zipf-alpha 2.0 --window-size 1G --move-policy fixed --threads "${THREADS}")
      ;;
    index_rf_zipf2_4g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode irregular-index --index-kernel gather --index-distribution zipf --index-zipf-alpha 2.0 --window-size 4G --move-policy fixed --threads "${THREADS}")
      ;;
    index_rf_segmented_64g_span4k)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode irregular-index --index-kernel gather --index-distribution segmented --index-segments 64 --index-segment-span-ops 4096 --window-size 64G --move-policy fixed --threads "${THREADS}")
      ;;
    index_rf_segmented_64g_span64k)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode irregular-index --index-kernel gather --index-distribution segmented --index-segments 64 --index-segment-span-ops 65536 --window-size 64G --move-policy fixed --threads "${THREADS}")
      ;;
    index_rf_segmented_64g_span256k)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode irregular-index --index-kernel gather --index-distribution segmented --index-segments 64 --index-segment-span-ops 262144 --window-size 64G --move-policy fixed --threads "${THREADS}")
      ;;
    index_rf_segmented_64g_span1m)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode irregular-index --index-kernel gather --index-distribution segmented --index-segments 64 --index-segment-span-ops 1048576 --window-size 64G --move-policy fixed --threads "${THREADS}")
      ;;
    index_rf_segmented_64g_span4m)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode irregular-index --index-kernel gather --index-distribution segmented --index-segments 64 --index-segment-span-ops 4194304 --window-size 64G --move-policy fixed --threads "${THREADS}")
      ;;
    index_rf_cluster_4g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode irregular-index --index-kernel gather --index-distribution clustered --index-cluster-size 512M --index-cluster-span-ops 262144 --window-size 4G --move-policy fixed --threads "${THREADS}")
      ;;
    tail_hotset_8g_fixed)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 8G --window-offset 40G --move-policy fixed --hotset-pages 2097152 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
    tail_hotset_4g_fixed)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --window-offset 44G --move-policy fixed --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
    tail_hotset_4g_fixed_36g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --window-offset 36G --move-policy fixed --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
    tail_hotset_4g_move_60s)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --window-offset 44G --move-policy random --move-step 4G --move-min-offset 28G --move-max-offset 44G --move-interval-ms 60000 --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
    tail_hotset_4g_move_30s)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --window-offset 44G --move-policy random --move-step 4G --move-min-offset 28G --move-max-offset 44G --move-interval-ms 30000 --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
    tail_hotset_4g_move_10s)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --window-offset 44G --move-policy random --move-step 4G --move-min-offset 28G --move-max-offset 44G --move-interval-ms 10000 --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
    phase_tail_hotset_sparse16)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="phase-switch"
      CANDIDATE_ARGS=(--phase-preset tail-hotset-sparse16 --phase-ms "${PHASE_MS}" --phase-repeat "${PHASE_REPEAT}" --threads "${THREADS}")
      ;;
    phase_tail_hotset_sparse24)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="phase-switch"
      CANDIDATE_ARGS=(--phase-preset tail-hotset-sparse24 --phase-ms "${PHASE_MS}" --phase-repeat "${PHASE_REPEAT}" --threads "${THREADS}")
      ;;
    phase_sparse24_tail_hotset)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="phase-switch"
      CANDIDATE_PHASE_FIRST_KIND="sparse"
      CANDIDATE_ARGS=(--phase-preset sparse24-tail-hotset --phase-ms "${PHASE_MS}" --phase-repeat "${PHASE_REPEAT}" --threads "${THREADS}")
      ;;
    phase_skew4g_sparse64)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="phase-switch"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_PHASE_FIRST_KIND="friendly"
      CANDIDATE_ARGS=(--phase-preset skew4g-sparse64 --phase-ms "${PHASE_MS}" --phase-repeat "${PHASE_REPEAT}" --threads "${THREADS}")
      ;;
    phase_mulshift4g_sparse24)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="phase-switch"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_PHASE_FIRST_KIND="friendly"
      CANDIDATE_ARGS=(--phase-preset mulshift4g-sparse24 --phase-ms "${PHASE_MS}" --phase-repeat "${PHASE_REPEAT}" --threads "${THREADS}")
      ;;
    phase_mulshift4g_rot_sparse24)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="phase-switch"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_PHASE_FIRST_KIND="friendly"
      CANDIDATE_ARGS=(--phase-preset mulshift4g-rot-sparse24 --phase-ms "${PHASE_MS}" --phase-repeat "${PHASE_REPEAT}" --threads "${THREADS}")
      ;;
    phase_mulshift4g_sparse64)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="phase-switch"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_PHASE_FIRST_KIND="friendly"
      CANDIDATE_ARGS=(--phase-preset mulshift4g-sparse64 --phase-ms "${PHASE_MS}" --phase-repeat "${PHASE_REPEAT}" --threads "${THREADS}")
      ;;
    phase_mulshift4g_rot_sparse64)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="phase-switch"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_PHASE_FIRST_KIND="friendly"
      CANDIDATE_ARGS=(--phase-preset mulshift4g-rot-sparse64 --phase-ms "${PHASE_MS}" --phase-repeat "${PHASE_REPEAT}" --threads "${THREADS}")
      ;;
    phase_mulshift4g_rot_move16g3s)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="phase-switch"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_PHASE_FIRST_KIND="friendly"
      CANDIDATE_ARGS=(--phase-preset mulshift4g-rot-move16g3s --phase-ms "${PHASE_MS}" --phase-repeat "${PHASE_REPEAT}" --threads "${THREADS}")
      ;;
    phase_mulshift4g_block2m_sparse64)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="phase-switch"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_PHASE_FIRST_KIND="friendly"
      CANDIDATE_ARGS=(--phase-preset mulshift4g-block2m-sparse64 --phase-ms "${PHASE_MS}" --phase-repeat "${PHASE_REPEAT}" --threads "${THREADS}")
      ;;
    phase_mulshift4g_block2m_sparse64_localft)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="phase-switch"
      CANDIDATE_PHASE_FIRST_KIND="friendly"
      CANDIDATE_ARGS=(--phase-preset mulshift4g-block2m-sparse64 --phase-ms "${PHASE_MS}" --phase-repeat "${PHASE_REPEAT}" --threads "${THREADS}")
      ;;
    phase_move15s4g_split32_stream4k_localft)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="phase-switch"
      CANDIDATE_PHASE_FIRST_KIND="friendly"
      CANDIDATE_ARGS=(--phase-preset move15s4g-split32 --window-size 32G --placement "window-split:${LOCAL_NODE},${REMOTE_NODE}" --phase-ms "${PHASE_MS}" --phase-repeat "${PHASE_REPEAT}" --threads "${THREADS}")
      ;;
    phase_move15s4g_remote_split32_stream4k_localft)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="phase-switch"
      CANDIDATE_PHASE_FIRST_KIND="friendly"
      CANDIDATE_ARGS=(--phase-preset move15s4g-remote-split32 --window-size 32G --placement "window-split:${LOCAL_NODE},${REMOTE_NODE}" --phase-ms "${PHASE_MS}" --phase-repeat "${PHASE_REPEAT}" --threads "${THREADS}")
      ;;
    phase_move60s4g_remote_split32_stream4k_localft)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="phase-switch"
      CANDIDATE_PHASE_FIRST_KIND="friendly"
      CANDIDATE_ARGS=(--phase-preset move60s4g-remote-split32 --window-size 32G --placement "window-split:${LOCAL_NODE},${REMOTE_NODE}" --phase-ms "${PHASE_MS}" --phase-repeat "${PHASE_REPEAT}" --threads "${THREADS}")
      ;;
    phase_fixed4g_remote_split32_stream4k_localft)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="phase-switch"
      CANDIDATE_PHASE_FIRST_KIND="friendly"
      CANDIDATE_ARGS=(--phase-preset fixed4g-remote-split32 --window-size 32G --placement "window-split:${LOCAL_NODE},${REMOTE_NODE}" --phase-ms "${PHASE_MS}" --phase-repeat "${PHASE_REPEAT}" --threads "${THREADS}")
      ;;
    phase_fixed8g_remote_split32_stream4k_localft)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="phase-switch"
      CANDIDATE_PHASE_FIRST_KIND="friendly"
      CANDIDATE_ARGS=(--phase-preset fixed8g-remote-split32 --window-size 32G --placement "window-split:${LOCAL_NODE},${REMOTE_NODE}" --phase-ms "${PHASE_MS}" --phase-repeat "${PHASE_REPEAT}" --threads "${THREADS}")
      ;;
    phase_move15s4g_remote_split32_stream4k_local*g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="phase-switch"
      CANDIDATE_PHASE_FIRST_KIND="friendly"
      local_split_gib="${candidate#phase_move15s4g_remote_split32_stream4k_local}"
      local_split_gib="${local_split_gib%g}"
      if ! [[ "${local_split_gib}" =~ ^[0-9]+$ ]] || (( local_split_gib == 0 )); then
        echo "invalid local split candidate: ${candidate}" >&2
        return 1
      fi
      # The phase prefault helper currently uses half of base --window-size as
      # the local prefix size. Keep the active unfriendly phase window fixed at
      # 32G inside the phase preset and vary only initial local residency.
      prefault_window_gib=$(( local_split_gib * 2 ))
      CANDIDATE_ARGS=(--phase-preset move15s4g-remote-split32 --window-size "${prefault_window_gib}G" --placement "window-split:${LOCAL_NODE},${REMOTE_NODE}" --phase-ms "${PHASE_MS}" --phase-repeat "${PHASE_REPEAT}" --threads "${THREADS}")
      ;;
    tail_hotset_8g_move_60s)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 8G --window-offset 40G --move-policy random --move-step 8G --move-min-offset 24G --move-max-offset 40G --move-interval-ms 60000 --hotset-pages 2097152 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
    tail_hotset_8g_move_30s)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 8G --window-offset 40G --move-policy random --move-step 8G --move-min-offset 24G --move-max-offset 40G --move-interval-ms 30000 --hotset-pages 2097152 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
	    tail_hotset_8g_move_10s)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 8G --window-offset 40G --move-policy random --move-step 8G --move-min-offset 24G --move-max-offset 40G --move-interval-ms 10000 --hotset-pages 2097152 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
	      ;;
	    tail64_hotset_2g_fixed)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 2G --window-offset 62G --move-policy fixed --hotset-pages 524288 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
	      ;;
	    tail64_hotset_4g_fixed)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --window-offset 60G --move-policy fixed --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
	      ;;
	    tail64_hotset_8g_fixed)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 8G --window-offset 56G --move-policy fixed --hotset-pages 2097152 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
	      ;;
	    tail64_hotset_2g_move_30s)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 2G --window-offset 62G --move-policy random --move-step 2G --move-min-offset 32G --move-max-offset 62G --move-interval-ms 30000 --hotset-pages 524288 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
	      ;;
	    tail64_hotset_4g_move_30s)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --window-offset 60G --move-policy random --move-step 4G --move-min-offset 32G --move-max-offset 60G --move-interval-ms 30000 --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
	      ;;
	    tail64_hotset_4g_move_10s)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --window-offset 60G --move-policy random --move-step 4G --move-min-offset 32G --move-max-offset 60G --move-interval-ms 10000 --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
	      ;;
	    tail64_hotset_8g_move_30s)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 8G --window-offset 56G --move-policy random --move-step 8G --move-min-offset 32G --move-max-offset 56G --move-interval-ms 30000 --hotset-pages 2097152 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
	      ;;
	    reuse_pc_512m)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode pc --window-size 512M --move-policy fixed --pc-chains 1 --threads "${THREADS}")
      ;;
	    head64_pc_512m_fixed)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode pc --window-size 512M --window-offset 0 --move-policy fixed --pc-chains 1 --threads "${THREADS}")
	      ;;
	    head64_pc_1g_fixed)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode pc --window-size 1G --window-offset 0 --move-policy fixed --pc-chains 1 --threads "${THREADS}")
	      ;;
	    head64_pc_2g_fixed)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode pc --window-size 2G --window-offset 0 --move-policy fixed --pc-chains 1 --threads "${THREADS}")
	      ;;
	    head64_pc_512m_move_5s)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="unfriendly"
	      CANDIDATE_ARGS=(--mode pc --window-size 512M --window-offset 0 --move-policy random --move-step 512M --move-min-offset 0 --move-max-offset 63500M --move-interval-ms 5000 --pc-chains 1 --threads "${THREADS}")
	      ;;
	    head64_pc_512m_move_1s)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="unfriendly"
	      CANDIDATE_ARGS=(--mode pc --window-size 512M --window-offset 0 --move-policy random --move-step 512M --move-min-offset 0 --move-max-offset 63500M --move-interval-ms 1000 --pc-chains 1 --threads "${THREADS}")
	      ;;
	    head64_pc_512m_move_500ms)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="unfriendly"
	      CANDIDATE_ARGS=(--mode pc --window-size 512M --window-offset 0 --move-policy random --move-step 512M --move-min-offset 0 --move-max-offset 63500M --move-interval-ms 500 --pc-chains 1 --threads "${THREADS}")
	      ;;
	    head64_pc_512m_move_250ms)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="unfriendly"
	      CANDIDATE_ARGS=(--mode pc --window-size 512M --window-offset 0 --move-policy random --move-step 512M --move-min-offset 0 --move-max-offset 63500M --move-interval-ms 250 --pc-chains 1 --threads "${THREADS}")
	      ;;
	    head64_pc_1g_move_1s)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="unfriendly"
	      CANDIDATE_ARGS=(--mode pc --window-size 1G --window-offset 0 --move-policy random --move-step 1G --move-min-offset 0 --move-max-offset 63G --move-interval-ms 1000 --pc-chains 1 --threads "${THREADS}")
	      ;;
	    head64_pc_1g_move_500ms)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="unfriendly"
	      CANDIDATE_ARGS=(--mode pc --window-size 1G --window-offset 0 --move-policy random --move-step 1G --move-min-offset 0 --move-max-offset 63G --move-interval-ms 500 --pc-chains 1 --threads "${THREADS}")
	      ;;
	    head64_pc_2g_move_1s)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="unfriendly"
	      CANDIDATE_ARGS=(--mode pc --window-size 2G --window-offset 0 --move-policy random --move-step 2G --move-min-offset 0 --move-max-offset 62G --move-interval-ms 1000 --pc-chains 1 --threads "${THREADS}")
	      ;;
	    head64_pc_2g_move_500ms)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="unfriendly"
	      CANDIDATE_ARGS=(--mode pc --window-size 2G --window-offset 0 --move-policy random --move-step 2G --move-min-offset 0 --move-max-offset 62G --move-interval-ms 500 --pc-chains 1 --threads "${THREADS}")
	      ;;
	    head64_bw_read_512m_fixed)
	      CANDIDATE_PRIMARY="bytes"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 512M --window-offset 0 --move-policy fixed --threads "${THREADS}")
	      ;;
	    head64_bw_read_2g_fixed)
	      CANDIDATE_PRIMARY="bytes"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 2G --window-offset 0 --move-policy fixed --threads "${THREADS}")
	      ;;
	    head64_skewed_read_2g_fixed)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 2G --window-offset 0 --move-policy fixed --hotset-pages 524288 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
	      ;;
	    head64_skewed_read_4g_fixed)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --window-offset 0 --move-policy fixed --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
	      ;;
	    skew_rf_read_4g_fixed_rss16g_persistent)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_REMOTE_FIRSTTOUCH=1
	      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --window-offset 0 --move-policy fixed --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
	      ;;
	    skew_rf_read_4g_fixed_rss16g_mulshift_persistent)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_REMOTE_FIRSTTOUCH=1
	      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --window-offset 0 --move-policy fixed --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift --threads "${THREADS}")
	      ;;
	    skew_lf_hotremote_4g_fixed_rss16g_mulshift_persistent)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --window-offset 0 --move-policy fixed --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift --hotset-prefault-node "${REMOTE_NODE}" --threads "${THREADS}")
	      ;;
	    skew_lf_hotremote_4g_move_15s_rss64g_mulshift_persistent)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --window-offset 0 --move-policy random --move-step 4G --move-min-offset 0 --move-max-offset 60G --move-interval-ms 15000 --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift --hotset-prefault-node "${REMOTE_NODE}" --threads "${THREADS}")
	      ;;
	    skew_lf_hotremote_4g_move_60s_remoteonly_mulshift_persistent)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --window-offset 16G --move-policy random --move-step 4G --move-min-offset 16G --move-max-offset 60G --move-interval-ms 60000 --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift --hotset-prefault-node "${REMOTE_NODE}" --threads "${THREADS}")
	      ;;
	    skew_lf_hotremote_32g_fixed_rss16g_mulshift_persistent)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 32G --window-offset 0 --move-policy fixed --hotset-pages 8388608 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift --hotset-prefault-node "${REMOTE_NODE}" --threads "${THREADS}")
	      ;;
	    pc_lf_windowremote_32g_fixed_rss16g_chase1_persistent)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode pc --window-size 32G --window-offset 0 --move-policy fixed --pc-chains 1 --pc-pattern random --hotset-prefault-node "${REMOTE_NODE}" --threads "${THREADS}")
	      ;;
	    skew_lf_hotremote_16g_fixed_rss16g_mulshift_persistent)
	      CANDIDATE_PRIMARY="ops"
	      CANDIDATE_KIND="friendly"
	      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 16G --window-offset 0 --move-policy fixed --hotset-pages 4194304 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift --hotset-prefault-node "${REMOTE_NODE}" --threads "${THREADS}")
	      ;;
		    head64_skewed_read_4g_move_10s)
		      CANDIDATE_PRIMARY="ops"
		      CANDIDATE_KIND="unfriendly"
		      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --window-offset 0 --move-policy random --move-step 4G --move-min-offset 0 --move-max-offset 60G --move-interval-ms 10000 --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
		      ;;
		    skew_rf_read_4g_move_15s_rss16g_persistent)
		      CANDIDATE_PRIMARY="ops"
		      CANDIDATE_KIND="friendly"
		      CANDIDATE_REMOTE_FIRSTTOUCH=1
		      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --window-offset 0 --move-policy random --move-step 4G --move-min-offset 0 --move-max-offset 12G --move-interval-ms 15000 --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
		      ;;
		    skew_rf_read_4g_move_15s_rss16g_mulshift_persistent)
		      CANDIDATE_PRIMARY="ops"
		      CANDIDATE_KIND="friendly"
		      CANDIDATE_REMOTE_FIRSTTOUCH=1
		      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --window-offset 0 --move-policy random --move-step 4G --move-min-offset 0 --move-max-offset 12G --move-interval-ms 15000 --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift --threads "${THREADS}")
		      ;;
		    head64_skewed_read_4g_move_5s)
		      CANDIDATE_PRIMARY="ops"
		      CANDIDATE_KIND="unfriendly"
		      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 4G --window-offset 0 --move-policy random --move-step 4G --move-min-offset 0 --move-max-offset 60G --move-interval-ms 5000 --hotset-pages 1048576 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --threads "${THREADS}")
	      ;;
    skewed_hotset_readmostly_2g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="friendly"
      CANDIDATE_ARGS=(--mode skewed-hotset --window-size 2G --move-policy fixed --hotset-pages 65536 --hot-prob-pct 98 --hotset-read-pct 90 --hotset-write-pct 10 --hotset-rmw-pct 0 --threads "${THREADS}")
      ;;
    stream_triad_sweep_8g)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_ARGS=(--mode bw --bw-kernel triad --window-size 8G --move-policy sweep --move-step 1G --move-interval-ms 1000 --threads "${THREADS}")
      ;;
    sparse_stride_read_8g)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 8G --move-policy fixed --bw-stride 512 --bw-block 4K --threads "${THREADS}")
      ;;
    sparse_stride_read_8g_remoteft)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 8G --move-policy fixed --bw-stride 512 --bw-block 4K --threads "${THREADS}")
      ;;
    sparse_stride_read_16g)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 16G --move-policy fixed --bw-stride 512 --bw-block 4K --threads "${THREADS}")
      ;;
    sparse_stride_read_16g_remoteft)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 16G --move-policy fixed --bw-stride 512 --bw-block 4K --threads "${THREADS}")
      ;;
    sparse_stride_read_32g)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 32G --move-policy fixed --bw-stride 512 --bw-block 4K --threads "${THREADS}")
      ;;
    stream_read_32g_remote_4kstride)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --arena-size 32G --window-size 32G --move-policy fixed --placement "window-split:${REMOTE_NODE},${REMOTE_NODE}" --bw-stride 512 --bw-block 4K --threads "${THREADS}")
      ;;
    stream_read_32g_split8_4kstride)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --arena-size 32G --window-size 32G --move-policy fixed --placement "window-split:${LOCAL_NODE},${REMOTE_NODE}" --window-split-local 8G --bw-stride 512 --bw-block 4K --threads "${THREADS}")
      ;;
    stream_read_32g_split16_4kstride)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --arena-size 32G --window-size 32G --move-policy fixed --placement "window-split:${LOCAL_NODE},${REMOTE_NODE}" --bw-stride 512 --bw-block 4K --threads "${THREADS}")
      ;;
    stream_read_32g_split16_4kstride_sharedscan)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --arena-size 32G --window-size 32G --move-policy fixed --placement "window-split:${LOCAL_NODE},${REMOTE_NODE}" --bw-stride 512 --bw-block 4K --bw-shared-window --threads "${THREADS}")
      ;;
    sparse_stride_read_64g)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 64G --move-policy fixed --bw-stride 512 --bw-block 4K --threads "${THREADS}")
      ;;
    sparse_stride_read_64g_remoteft)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 64G --move-policy fixed --bw-stride 512 --bw-block 4K --threads "${THREADS}")
      ;;
    sparse_stride_read_64g_block2m)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 64G --move-policy fixed --bw-stride 512 --bw-block 2M --threads "${THREADS}")
      ;;
    sparse_stride_read_64g_block2m_localft)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 64G --move-policy fixed --bw-stride 512 --bw-block 2M --threads "${THREADS}")
      ;;
    sparse_stride_read_64g_block2m_remoteft)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode bw --bw-kernel read --window-size 64G --move-policy fixed --bw-stride 512 --bw-block 2M --threads "${THREADS}")
      ;;
    sparse_stride_write_64g)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_ARGS=(--mode bw --bw-kernel write --window-size 64G --move-policy fixed --bw-stride 512 --bw-block 4K --threads "${THREADS}")
      ;;
    sparse_stride_write_64g_remoteft)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode bw --bw-kernel write --window-size 64G --move-policy fixed --bw-stride 512 --bw-block 4K --threads "${THREADS}")
      ;;
    stream_triad_sweep_32g)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_ARGS=(--mode bw --bw-kernel triad --window-size 32G --move-policy sweep --move-step 4G --move-interval-ms 1000 --threads "${THREADS}")
      ;;
    stream_triad_sweep_48g)
      CANDIDATE_PRIMARY="bytes"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_ARGS=(--mode bw --bw-kernel triad --window-size 48G --move-policy sweep --move-step 4G --move-interval-ms 1000 --threads "${THREADS}")
      ;;
    irregular_uniform_sweep_4g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_ARGS=(--mode irregular-index --index-kernel gather --index-distribution uniform --window-size 4G --move-policy sweep --move-step 512M --move-interval-ms 1000 --threads "${THREADS}")
      ;;
    irregular_uniform_sweep_16g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_ARGS=(--mode irregular-index --index-kernel gather --index-distribution uniform --window-size 16G --move-policy sweep --move-step 2G --move-interval-ms 1000 --threads "${THREADS}")
      ;;
    irregular_uniform_sweep_32g)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_ARGS=(--mode irregular-index --index-kernel gather --index-distribution uniform --window-size 32G --move-policy sweep --move-step 4G --move-interval-ms 1000 --threads "${THREADS}")
      ;;
    irregular_uniform_sweep_32g_remoteft)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode irregular-index --index-kernel gather --index-distribution uniform --window-size 32G --move-policy sweep --move-step 4G --move-interval-ms 1000 --threads "${THREADS}")
      ;;
    irregular_uniform_sweep_64g_remoteft)
      CANDIDATE_PRIMARY="ops"
      CANDIDATE_KIND="unfriendly"
      CANDIDATE_REMOTE_FIRSTTOUCH=1
      CANDIDATE_ARGS=(--mode irregular-index --index-kernel gather --index-distribution uniform --window-size 64G --move-policy sweep --move-step 4G --move-interval-ms 1000 --threads "${THREADS}")
      ;;
    *)
      echo "unknown candidate: ${name}" >&2
      return 1
      ;;
  esac
}

summarize_case() {
  local case_dir="$1"
  local candidate="$2"
  local policy="$3"
  local rep="$4"
  local primary="$5"
  local expected="$6"
  local ret="$7"

  python3 - "$case_dir" "$candidate" "$policy" "$rep" "$primary" "$expected" "$ret" > "${case_dir}/summary.json" <<'PY'
import csv
import json
import statistics
import sys
from pathlib import Path

case_dir = Path(sys.argv[1])
candidate, policy, rep, primary, expected, ret = sys.argv[2:]

def parse_diff(path):
    data = {}
    if not path.exists():
        return data
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = raw.split(None, 1)
        if len(parts) == 2:
            try:
                data[parts[0]] = int(parts[1])
            except ValueError:
                pass
    return data

rows = []
csv_path = case_dir / "mbench.stdout.csv"
if csv_path.exists():
    with csv_path.open("r", encoding="utf-8", errors="replace") as f:
        reader = csv.DictReader(line for line in f if line.strip())
        for row in reader:
            rows.append(row)

rates = []
last_time = None
for row in rows:
    try:
        time_ms = float(row["time_ms"])
        delta = float(row[f"{primary}_delta"])
    except Exception:
        continue
    if last_time is None:
        last_time = time_ms
        continue
    dt_s = max(0.001, (time_ms - last_time) / 1000.0)
    rates.append(delta / dt_s)
    last_time = time_ms

steady = rates[3:] if len(rates) > 6 else rates
summary = {
    "candidate": candidate,
    "policy": policy,
    "rep": int(rep),
    "primary": primary,
    "expected": expected,
    "returncode": int(ret),
    "sample_rows": len(rows),
    "rate_samples": len(rates),
    "steady_samples": len(steady),
}
if steady:
    summary["steady_median_rate"] = statistics.median(steady)
    summary["steady_mean_rate"] = sum(steady) / len(steady)
    if len(steady) >= 2 and summary["steady_mean_rate"]:
        summary["steady_cv"] = statistics.stdev(steady) / summary["steady_mean_rate"]
if rows:
    for key in ("ops_total", "bytes_total", "window_offset"):
        try:
            summary[f"final_{key}"] = int(float(rows[-1].get(key, "")))
        except Exception:
            pass
if rows and "phase_name" in rows[0]:
    phase_rates = {}
    last = None
    for row in rows:
        try:
            time_ms = float(row["time_ms"])
        except Exception:
            continue
        phase = row.get("phase_name", "")
        phase_id = row.get("phase_id", "")
        key = f"{phase_id}:{phase}"
        bucket = phase_rates.setdefault(key, {"ops": [], "bytes": [], "first_ms": time_ms, "last_ms": time_ms})
        bucket["last_ms"] = time_ms
        if last is not None:
            try:
                dt_s = max(0.001, (time_ms - last["time_ms"]) / 1000.0)
                bucket["ops"].append(float(row.get("ops_delta", 0)) / dt_s)
                bucket["bytes"].append(float(row.get("bytes_delta", 0)) / dt_s)
            except Exception:
                pass
        last = {"time_ms": time_ms}
    phase_summary = []
    for key, bucket in sorted(phase_rates.items()):
        phase_id, phase_name = key.split(":", 1)
        ops_rates = bucket["ops"][2:] if len(bucket["ops"]) > 4 else bucket["ops"]
        bytes_rates = bucket["bytes"][2:] if len(bucket["bytes"]) > 4 else bucket["bytes"]
        item = {
            "phase_id": int(phase_id) if phase_id else 0,
            "phase_name": phase_name,
            "sample_count": len(bucket["ops"]),
            "steady_sample_count": len(ops_rates),
            "first_ms": bucket["first_ms"],
            "last_ms": bucket["last_ms"],
        }
        if ops_rates:
            item["mean_ops_s"] = sum(ops_rates) / len(ops_rates)
            item["median_ops_s"] = statistics.median(ops_rates)
        if bytes_rates:
            item["mean_MBps"] = (sum(bytes_rates) / len(bytes_rates)) / (1000 ** 2)
            item["median_MBps"] = statistics.median(bytes_rates) / (1000 ** 2)
        phase_summary.append(item)
    summary["phase_summary"] = phase_summary

vm = parse_diff(case_dir / "vmstat.diff")
cg = parse_diff(case_dir / "cgroup.diff")
summary.update({f"vmstat.{k}": v for k, v in vm.items()})
summary.update({f"cgroup.{k}": v for k, v in cg.items()})
promote_pages = cg.get("MEMSTAT.pgpromote_success", vm.get("pgpromote_success", 0))
demote_direct_pages = cg.get("MEMSTAT.pgdemote_direct", vm.get("pgdemote_direct", 0))
demote_kswapd_pages = cg.get("MEMSTAT.pgdemote_kswapd", vm.get("pgdemote_kswapd", 0))
demote_pages = demote_direct_pages + demote_kswapd_pages
migrate_pages = cg.get("MIGRATE.numa_migrate_success_total", vm.get("numa_pages_migrated", 0))
summary["promote_pages"] = promote_pages
summary["demote_direct_pages"] = demote_direct_pages
summary["demote_kswapd_pages"] = demote_kswapd_pages
summary["demote_pages"] = demote_pages
summary["migrate_pages"] = migrate_pages
summary["migrate_gib"] = (
    migrate_pages * 4096 / (1024 ** 3)
)
summary["hint_faults"] = vm.get("numa_hint_faults", 0)
summary["promote_gib"] = (
    promote_pages * 4096 / (1024 ** 3)
)
summary["demote_gib"] = (
    demote_pages * 4096 / (1024 ** 3)
)
print(json.dumps(summary, indent=2, sort_keys=True))
PY
}

run_case() {
  local candidate="$1"
  local policy="$2"
  local rep="$3"
  local primary expected safe_name case_dir cg ret
  local cmd exec_cmd
  local remote_firsttouch helper_pid controller_pid controller_stop
  local sampler_pid sampler_stop mbench_pid ready_file start_file use_prefault_gate

  candidate_args "${candidate}"
  primary="${CANDIDATE_PRIMARY}"
  expected="${CANDIDATE_KIND}"
  remote_firsttouch="${CANDIDATE_REMOTE_FIRSTTOUCH}"
  safe_name="${candidate}__${policy}__rep${rep}"
  case_dir="${RUN_ROOT}/${safe_name}"
  cg="${CGROOT}/${CG_PREFIX}_${safe_name}"
  mkdir -p "${case_dir}"

  configure_policy_globals "${policy}"
  setup_cgroup "${cg}" "${policy}"
  if [[ "${remote_firsttouch}" == "1" && -f "${cg}/cpuset.mems" ]]; then
    echo "${REMOTE_NODE}" > "${cg}/cpuset.mems"
  fi

  cp /proc/self/status "${case_dir}/runner.status.before.txt" || true
	  snapshot_cgroup_stats "${cg}" "${case_dir}/cgroup.before"
	  snapshot_vmstat "${case_dir}/vmstat.before"
	  if [[ -f "${cg}/memory.numa_stat" ]]; then
	    cp "${cg}/memory.numa_stat" "${case_dir}/memory.numa_stat.before.txt" || true
  elif [[ -f "${cg}/numa_stat" ]]; then
    cp "${cg}/numa_stat" "${case_dir}/memory.numa_stat.before.txt" || true
  fi

  cmd=(timeout --signal=TERM "${TIMEOUT_SEC}" "${MBENCH}" --csv --quiet --sample-ms "${SAMPLE_MS}" --ops-per-pass "${OPS_PER_PASS}" --pause-ns "${PAUSE_NS}" --arena-size "${ARENA_SIZE}" "${CANDIDATE_ARGS[@]}")
  if [[ -n "${MBENCH_FORCE_DURATION_MS}" ]]; then
    cmd+=("--duration-ms" "${MBENCH_FORCE_DURATION_MS}")
  fi
  exec_cmd=("${cmd[@]}")
  if [[ "${PERF_STAT}" =~ ^(1|true|yes|on)$ ]]; then
    if command -v perf >/dev/null 2>&1 &&
       perf stat -x, -o "${case_dir}/perf.probe.csv" -e cycles -- true \
         >/dev/null 2> "${case_dir}/perf.probe.stderr"; then
      exec_cmd=(perf stat -x, -o "${case_dir}/perf.stat.csv" -e "${PERF_EVENTS}" -- "${cmd[@]}")
    else
      echo "perf unavailable or unusable in guest" > "${case_dir}/perf.unavailable.txt"
    fi
  fi
  printf '%q ' "${cmd[@]}" > "${case_dir}/cmd.txt"
  printf '\n' >> "${case_dir}/cmd.txt"
  printf '%q ' "${exec_cmd[@]}" > "${case_dir}/exec_cmd.txt"
  printf '\n' >> "${case_dir}/exec_cmd.txt"
  {
    echo "candidate=${candidate}"
    echo "policy=${policy}"
    echo "rep=${rep}"
    echo "primary=${primary}"
    echo "expected=${expected}"
    echo "arena_size=${ARENA_SIZE}"
    echo "capacity_pages=${CAPACITY_PAGES}"
    echo "timeout_sec=${TIMEOUT_SEC}"
    echo "cpuset_cpus=${CPUSET_CPUS}"
    echo "cpuset_mems=${CPUSET_MEMS}"
    echo "remote_firsttouch=${remote_firsttouch}"
    echo "remote_firsttouch_sec=${REMOTE_FIRSTTOUCH_SEC}"
    echo "phase_ms=${PHASE_MS}"
    echo "phase_repeat=${PHASE_REPEAT}"
	    echo "phase_first_kind=per_candidate"
	    echo "live_sample_sec=${LIVE_SAMPLE_SEC}"
	    echo "phase_controller_delay_sec=${PHASE_CONTROLLER_DELAY_SEC}"
	    echo "phase_sparse_off_delay_sec=${PHASE_SPARSE_OFF_DELAY_SEC}"
	    echo "local_util_adapt_window_sec=${LOCAL_UTIL_ADAPT_WINDOW_SEC}"
	    echo "local_util_adapt_threshold_pct=${LOCAL_UTIL_ADAPT_THRESHOLD_PCT}"
	    echo "local_util_adapt_consecutive=${LOCAL_UTIL_ADAPT_CONSECUTIVE}"
	    echo "local_util_adapt_min_pte_updates=${LOCAL_UTIL_ADAPT_MIN_PTE_UPDATES}"
	    echo "mbench_force_duration_ms=${MBENCH_FORCE_DURATION_MS}"
	    echo "prefault_phase_gate=${PREFAULT_PHASE_GATE}"
	    echo "prefault_ready_timeout_sec=${PREFAULT_READY_TIMEOUT_SEC}"
	    echo "prefault_settle_reclaimd=${PREFAULT_SETTLE_RECLAIMD}"
		    echo "prefault_settle_timeout_sec=${PREFAULT_SETTLE_TIMEOUT_SEC}"
		    echo "prefault_settle_quiet_sec=${PREFAULT_SETTLE_QUIET_SEC}"
		    echo "perf_stat=${PERF_STAT}"
		    echo "perf_events=${PERF_EVENTS}"
		    echo "numa_migration_stop_enabled=${NUMA_MIGRATION_STOP_ENABLED}"
			    echo "numa_pingpong_stat_enabled=${NUMA_PINGPONG_STAT_ENABLED}"
			    echo "numa_promote_sample_stat_enabled=${NUMA_PROMOTE_SAMPLE_STAT_ENABLED}"
			    echo "numa_promote_sample_rate=${NUMA_PROMOTE_SAMPLE_RATE}"
			    echo "numa_local_fault_on_tiering=${NUMA_LOCAL_FAULT_ON_TIERING}"
			    echo "numa_local_fault_defer_until_after_prefault=${NUMA_LOCAL_FAULT_DEFER_UNTIL_AFTER_PREFAULT}"
			    echo "numa_local_fault_refault_hit_ms=${NUMA_LOCAL_FAULT_REFAULT_HIT_MS}"
			  } > "${case_dir}/meta.env"

	  log "run ${safe_name}"
	  helper_pid=""
	  controller_pid=""
	  controller_stop="${case_dir}/policy-controller.stop"
	  rm -f "${controller_stop}"
	  use_prefault_gate=0
	  if [[ "${PREFAULT_PHASE_GATE}" =~ ^(1|true|yes|on)$ ]]; then
	    use_prefault_gate=1
	  fi
	  if [[ "${remote_firsttouch}" == "1" && -f "${cg}/cpuset.mems" ]]; then
	    if [[ "${use_prefault_gate}" == "1" ]]; then
	      echo "${REMOTE_NODE}" > "${cg}/cpuset.mems" 2>/dev/null || true
	    else
	      (
	        sleep "${REMOTE_FIRSTTOUCH_SEC}"
	        echo "${CPUSET_MEMS}" > "${cg}/cpuset.mems" 2>/dev/null || true
	      ) &
	      helper_pid=$!
	    fi
	  fi
	  sampler_pid=""
	  sampler_stop="${case_dir}/live.stop"
	  rm -f "${sampler_stop}"
	  ready_file="${case_dir}/mbench.prefault.ready"
	  start_file="${case_dir}/mbench.start"
	  rm -f "${ready_file}" "${start_file}"

	  set +e
	  if [[ "${use_prefault_gate}" == "1" ]]; then
	    MBENCH_READY_FILE="${ready_file}" MBENCH_START_FILE="${start_file}" \
	      bash -c 'echo $$ > "$1"; shift; exec "$@"' bash "${cg}/cgroup.procs" "${exec_cmd[@]}" \
	      > "${case_dir}/mbench.stdout.csv" \
	      2> "${case_dir}/mbench.stderr.txt" &
	    mbench_pid=$!

	    wait_for_prefault_ready "${ready_file}" "${mbench_pid}" "${PREFAULT_READY_TIMEOUT_SEC}"
	    ret=$?
	    if [[ "${ret}" -eq 0 ]]; then
	      if [[ "${remote_firsttouch}" == "1" && -f "${cg}/cpuset.mems" ]]; then
	        echo "${CPUSET_MEMS}" > "${cg}/cpuset.mems" 2>/dev/null || true
	        if [[ -n "${helper_pid}" ]]; then
	          kill "${helper_pid}" 2>/dev/null || true
	          wait "${helper_pid}" 2>/dev/null || true
	          helper_pid=""
	        fi
	      fi
	      wait_for_prefault_settle "${cg}" "${case_dir}/prefault-settle.log" \
	        "${PREFAULT_SETTLE_TIMEOUT_SEC}" "${PREFAULT_SETTLE_QUIET_SEC}"
	      ret=$?
	    fi
	    if [[ "${ret}" -eq 0 ]]; then
	      cp "${case_dir}/cgroup.before" "${case_dir}/cgroup.preprefault" 2>/dev/null || true
	      cp "${case_dir}/vmstat.before" "${case_dir}/vmstat.preprefault" 2>/dev/null || true
	      cp "${case_dir}/memory.numa_stat.before.txt" \
	        "${case_dir}/memory.numa_stat.preprefault.txt" 2>/dev/null || true
	      snapshot_cgroup_stats "${cg}" "${case_dir}/cgroup.before"
	      snapshot_vmstat "${case_dir}/vmstat.before"
	      if [[ -f "${cg}/memory.numa_stat" ]]; then
	        cp "${cg}/memory.numa_stat" "${case_dir}/memory.numa_stat.before.txt" || true
	      elif [[ -f "${cg}/numa_stat" ]]; then
	        cp "${cg}/numa_stat" "${case_dir}/memory.numa_stat.before.txt" || true
	      fi
	      if [[ "${NUMA_LOCAL_FAULT_ON_TIERING}" != "0" &&
	            "${NUMA_LOCAL_FAULT_DEFER_UNTIL_AFTER_PREFAULT}" =~ ^(1|true|yes|on)$ ]]; then
	        write_knob_optional "${cg}" "numa_local_fault_on_tiering" \
	          "${NUMA_LOCAL_FAULT_ON_TIERING}"
	      fi
	      if policy_uses_phase_controller "${policy}"; then
	        (
	          if [[ "${PHASE_CONTROLLER_DELAY_SEC}" =~ ^[0-9]+$ &&
	                "${PHASE_CONTROLLER_DELAY_SEC}" -gt 0 ]]; then
	            sleep "${PHASE_CONTROLLER_DELAY_SEC}"
	          fi
	          run_phase_policy_controller "${cg}" "${policy}" "${controller_stop}"
	        ) > "${case_dir}/policy-controller.log" 2>&1 &
	        controller_pid=$!
	      elif policy_uses_local_util_controller "${policy}"; then
	        (
	          if [[ "${PHASE_CONTROLLER_DELAY_SEC}" =~ ^[0-9]+$ &&
	                "${PHASE_CONTROLLER_DELAY_SEC}" -gt 0 ]]; then
	            sleep "${PHASE_CONTROLLER_DELAY_SEC}"
	          fi
	          run_local_util_controller "${cg}" "${controller_stop}"
	        ) > "${case_dir}/policy-controller.log" 2>&1 &
	        controller_pid=$!
	      fi
	      if [[ "${LIVE_SAMPLE_SEC}" =~ ^[0-9]+$ && "${LIVE_SAMPLE_SEC}" -gt 0 ]]; then
	        start_live_sampler "${cg}" "${case_dir}/live.csv" "${sampler_stop}" "${LIVE_SAMPLE_SEC}"
	        sampler_pid=$!
	      fi
	      touch "${start_file}"
	      wait "${mbench_pid}"
	      ret=$?
	    else
	      kill "${mbench_pid}" 2>/dev/null || true
	      wait "${mbench_pid}" 2>/dev/null || true
	    fi
	  else
	    if policy_uses_phase_controller "${policy}"; then
	      (
	        if [[ "${PHASE_CONTROLLER_DELAY_SEC}" =~ ^[0-9]+$ &&
	              "${PHASE_CONTROLLER_DELAY_SEC}" -gt 0 ]]; then
	          sleep "${PHASE_CONTROLLER_DELAY_SEC}"
	        fi
	        run_phase_policy_controller "${cg}" "${policy}" "${controller_stop}"
	      ) > "${case_dir}/policy-controller.log" 2>&1 &
	      controller_pid=$!
	    elif policy_uses_local_util_controller "${policy}"; then
	      (
	        if [[ "${PHASE_CONTROLLER_DELAY_SEC}" =~ ^[0-9]+$ &&
	              "${PHASE_CONTROLLER_DELAY_SEC}" -gt 0 ]]; then
	          sleep "${PHASE_CONTROLLER_DELAY_SEC}"
	        fi
	        run_local_util_controller "${cg}" "${controller_stop}"
	      ) > "${case_dir}/policy-controller.log" 2>&1 &
	      controller_pid=$!
	    fi
	    if [[ "${LIVE_SAMPLE_SEC}" =~ ^[0-9]+$ && "${LIVE_SAMPLE_SEC}" -gt 0 ]]; then
	      start_live_sampler "${cg}" "${case_dir}/live.csv" "${sampler_stop}" "${LIVE_SAMPLE_SEC}"
	      sampler_pid=$!
	    fi
	    bash -c 'echo $$ > "$1"; shift; exec "$@"' bash "${cg}/cgroup.procs" "${exec_cmd[@]}" \
	      > "${case_dir}/mbench.stdout.csv" \
	      2> "${case_dir}/mbench.stderr.txt"
	    ret=$?
	  fi
	  set -e
	  if [[ -n "${sampler_pid}" ]]; then
	    touch "${sampler_stop}"
	    wait "${sampler_pid}" 2>/dev/null || true
    rm -f "${sampler_stop}"
  fi
  if [[ -n "${controller_pid}" ]]; then
    touch "${controller_stop}"
    wait "${controller_pid}" 2>/dev/null || true
    rm -f "${controller_stop}"
  fi
  if [[ -n "${helper_pid}" ]]; then
    wait "${helper_pid}" 2>/dev/null || true
  fi

  snapshot_cgroup_stats "${cg}" "${case_dir}/cgroup.after"
  snapshot_vmstat "${case_dir}/vmstat.after"
  write_diff "${case_dir}/cgroup.before" "${case_dir}/cgroup.after" "${case_dir}/cgroup.diff"
  write_diff "${case_dir}/vmstat.before" "${case_dir}/vmstat.after" "${case_dir}/vmstat.diff"
  if [[ -f "${cg}/memory.numa_stat" ]]; then
    cp "${cg}/memory.numa_stat" "${case_dir}/memory.numa_stat.after.txt" || true
  elif [[ -f "${cg}/numa_stat" ]]; then
    cp "${cg}/numa_stat" "${case_dir}/memory.numa_stat.after.txt" || true
  fi

	  summarize_case "${case_dir}" "${candidate}" "${policy}" "${rep}" "${primary}" "${expected}" "${ret}"
	  if [[ -x "${PHASE_STAT_SUMMARIZER}" && -f "${case_dir}/live.csv" ]]; then
	    "${PHASE_STAT_SUMMARIZER}" \
	      --live "${case_dir}/live.csv" \
	      --mbench "${case_dir}/mbench.stdout.csv" \
	      --phase-ms "${PHASE_MS}" \
	      --boundary-window-ms "${PHASE_BOUNDARY_WINDOW_MS:-5000}" \
	      --out-dir "${case_dir}" || true
	  fi
	  reset_cgroup_dir "${cg}"
  log "done ${safe_name} ret=${ret}"
}

emit_run_meta() {
  {
    echo "run_id=${RUN_ID}"
    echo "mbench=${MBENCH}"
    echo "arena_size=${ARENA_SIZE}"
    echo "sample_ms=${SAMPLE_MS}"
    echo "ops_per_pass=${OPS_PER_PASS}"
    echo "pause_ns=${PAUSE_NS}"
    echo "timeout_sec=${TIMEOUT_SEC}"
    echo "reps=${REPS}"
    echo "policies=${POLICIES}"
    echo "candidates=${CANDIDATES}"
    echo "local_node=${LOCAL_NODE}"
    echo "remote_node=${REMOTE_NODE}"
    echo "cpuset_cpus=${CPUSET_CPUS}"
    echo "cpuset_mems=${CPUSET_MEMS}"
    echo "capacity_pages=${CAPACITY_PAGES}"
    echo "node_balancing_on=${NODE_BALANCING_ON}"
    echo "kswapd_demotion_on=${KSWAPD_DEMOTION_ON}"
    echo "off_demotion_on=${OFF_DEMOTION_ON}"
    echo "global_numa_on=${GLOBAL_NUMA_ON}"
    echo "numa_scan_size_mb=${NUMA_SCAN_SIZE_MB}"
    echo "effective_numa_scan_size_mb=$(read_optional /sys/kernel/debug/sched/numa_balancing/scan_size_mb || true)"
    echo "numa_scan_period_min_ms=${NUMA_SCAN_PERIOD_MIN_MS}"
    echo "effective_numa_scan_period_min_ms=$(read_optional /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms || true)"
    echo "numa_fast_scan=${NUMA_FAST_SCAN}"
    echo "hot_threshold_ms=${HOT_THRESHOLD_MS}"
    echo "remote_firsttouch_sec=${REMOTE_FIRSTTOUCH_SEC}"
    echo "phase_ms=${PHASE_MS}"
    echo "phase_repeat=${PHASE_REPEAT}"
	    echo "phase_first_kind=${CANDIDATE_PHASE_FIRST_KIND}"
	    echo "live_sample_sec=${LIVE_SAMPLE_SEC}"
	    echo "phase_controller_delay_sec=${PHASE_CONTROLLER_DELAY_SEC}"
	    echo "phase_sparse_off_delay_sec=${PHASE_SPARSE_OFF_DELAY_SEC}"
	    echo "local_util_adapt_window_sec=${LOCAL_UTIL_ADAPT_WINDOW_SEC}"
	    echo "local_util_adapt_threshold_pct=${LOCAL_UTIL_ADAPT_THRESHOLD_PCT}"
	    echo "local_util_adapt_consecutive=${LOCAL_UTIL_ADAPT_CONSECUTIVE}"
	    echo "local_util_adapt_min_pte_updates=${LOCAL_UTIL_ADAPT_MIN_PTE_UPDATES}"
	    echo "mbench_force_duration_ms=${MBENCH_FORCE_DURATION_MS}"
	    echo "prefault_phase_gate=${PREFAULT_PHASE_GATE}"
	    echo "prefault_ready_timeout_sec=${PREFAULT_READY_TIMEOUT_SEC}"
		    echo "prefault_settle_reclaimd=${PREFAULT_SETTLE_RECLAIMD}"
		    echo "prefault_settle_timeout_sec=${PREFAULT_SETTLE_TIMEOUT_SEC}"
		    echo "prefault_settle_quiet_sec=${PREFAULT_SETTLE_QUIET_SEC}"
		    echo "numa_migration_stop_enabled=${NUMA_MIGRATION_STOP_ENABLED}"
			    echo "numa_pingpong_stat_enabled=${NUMA_PINGPONG_STAT_ENABLED}"
			    echo "numa_promote_sample_stat_enabled=${NUMA_PROMOTE_SAMPLE_STAT_ENABLED}"
			    echo "numa_promote_sample_rate=${NUMA_PROMOTE_SAMPLE_RATE}"
			    echo "numa_local_fault_on_tiering=${NUMA_LOCAL_FAULT_ON_TIERING}"
			    echo "numa_local_fault_refault_hit_ms=${NUMA_LOCAL_FAULT_REFAULT_HIT_MS}"
			    echo "lru_gen_enabled=$(read_optional /sys/kernel/mm/lru_gen/enabled || true)"
		    echo "lru_gen_min_ttl_ms=$(read_optional /sys/kernel/mm/lru_gen/min_ttl_ms || true)"
		    echo "kernel=$(uname -a)"
    echo "numactl_hardware_begin"
    numactl --hardware 2>/dev/null || true
    echo "numactl_hardware_end"
  } > "${RUN_ROOT}/run_meta.txt"
}

enable_mglru() {
  local path="/sys/kernel/mm/lru_gen/enabled"

  if [[ ! -e "${path}" ]]; then
    log "MGLRU control missing: ${path}"
    return 1
  fi

  if [[ "$(read_optional "${path}" | tr -d '\n')" != "${MGLRU_ENABLED_VALUE}" ]]; then
    write_optional "${path}" "${MGLRU_ENABLED_VALUE}"
  fi

  log "MGLRU enabled=$(read_optional "${path}" | tr -d '\n')"
}

main() {
  local rep policy candidate

  enable_controllers
  enable_mglru || true
  emit_run_meta

  IFS=',' read -r -a POLICY_LIST <<< "${POLICIES}"
  IFS=',' read -r -a CANDIDATE_LIST <<< "${CANDIDATES}"

  for rep in $(seq 1 "${REPS}"); do
    for candidate in "${CANDIDATE_LIST[@]}"; do
      for policy in "${POLICY_LIST[@]}"; do
        run_case "${candidate}" "${policy}" "${rep}"
      done
    done
  done

  python3 - "${RUN_ROOT}" > "${RUN_ROOT}/summary.jsonl" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
for path in sorted(root.glob("*__*__rep*/summary.json")):
    try:
        print(json.dumps(json.loads(path.read_text(encoding="utf-8")), sort_keys=True))
    except Exception:
        pass
PY
  log "artifacts ${RUN_ROOT}"
}

main "$@"
