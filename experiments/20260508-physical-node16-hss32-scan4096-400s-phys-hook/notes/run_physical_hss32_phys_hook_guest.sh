#!/usr/bin/env bash
set -euo pipefail

MBENCH="${MBENCH:-/root/mbench}"
OUTDIR="${OUTDIR:-/tmp/phase_candidate_microbench}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"

LOCAL_NODE="${LOCAL_NODE:-0}"
REMOTE_NODE="${REMOTE_NODE:-1}"
CPUSET_CPUS="${CPUSET_CPUS:-0-31}"
THREADS="${THREADS:-32}"
ARENA_SIZE="${ARENA_SIZE:-64G}"
SAMPLE_MS="${SAMPLE_MS:-1000}"
OPS_PER_PASS="${OPS_PER_PASS:-65536}"
PAUSE_NS="${PAUSE_NS:-100000}"
TIMEOUT_SEC="${TIMEOUT_SEC:-900}"
NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-4096}"
SCAN_PERIOD_SCALE="${SCAN_PERIOD_SCALE:-100}"
HOT_THRESHOLD_MS="${HOT_THRESHOLD_MS:-0}"
MGLRU_ENABLED_VALUE="${MGLRU_ENABLED_VALUE:-0x0007}"
NODE_BALANCING_ON="${NODE_BALANCING_ON:-2}"
KSWAPD_DEMOTION_ON="${KSWAPD_DEMOTION_ON:-1}"
NUMA_MIGRATION_STOP_ENABLED="${NUMA_MIGRATION_STOP_ENABLED:-0}"
NUMA_PINGPONG_STAT_ENABLED="${NUMA_PINGPONG_STAT_ENABLED:-0}"
NUMA_PROMOTE_SAMPLE_STAT_ENABLED="${NUMA_PROMOTE_SAMPLE_STAT_ENABLED:-0}"
NUMA_PROMOTE_SAMPLE_RATE="${NUMA_PROMOTE_SAMPLE_RATE:-0}"
PREFAULT_READY_TIMEOUT_SEC="${PREFAULT_READY_TIMEOUT_SEC:-300}"
MBENCH_FORCE_DURATION_MS="${MBENCH_FORCE_DURATION_MS:-180000}"
LIVE_SAMPLE_SEC="${LIVE_SAMPLE_SEC:-10}"
POLICY_LABEL="${POLICY_LABEL:-${POLICIES:-on}}"

RUN_ROOT="${OUTDIR}/${RUN_ID}"
CASE_DIR="${RUN_ROOT}/skew_lf_hotremote_32g_fixed_physical_node16_nocg__${POLICY_LABEL}__rep1"
mkdir -p "${CASE_DIR}"

log() {
  printf '[physical-hss32-phys-hook] %s\n' "$*"
}

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

pick_cg_knob() {
  local name="$1"
  local candidate

  for candidate in "/sys/fs/cgroup/${name}" "/sys/fs/cgroup/memory.${name}"; do
    if [[ -f "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

write_root_cg_optional() {
  local name="$1"
  local value="$2"
  local knob

  knob="$(pick_cg_knob "${name}")" || return 0
  write_optional "${knob}" "${value}"
}

snapshot_vmstat() {
  local out="$1"
  python3 > "${out}" <<'PY'
keys = {
    "numa_hint_faults",
    "numa_hint_faults_local",
    "numa_pages_migrated",
    "pgdemote_direct",
    "pgdemote_kswapd",
    "pgmigrate_fail",
    "pgmigrate_success",
    "pgscan_direct",
    "pgscan_kswapd",
    "pgsteal_direct",
    "pgsteal_kswapd",
    "pgpromote_candidate",
    "pgpromote_candidate_demoted",
    "pgpromote_candidate_nrl",
    "pgpromote_sampled",
    "pgpromote_sampled_pte_updates",
    "pgpromote_sampled_refault",
    "pgpromote_sampled_lost",
    "pgpromote_success",
}
with open("/proc/vmstat", "r", encoding="utf-8") as f:
    for raw in f:
        parts = raw.split()
        if len(parts) == 2 and parts[0] in keys:
            print(f"{parts[0]} {parts[1]}")
PY
}

diff_kv() {
  local before="$1"
  local after="$2"
  local out="$3"
  python3 - "$before" "$after" > "${out}" <<'PY'
import sys

def read(path):
    data = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for raw in f:
                parts = raw.split()
                if len(parts) == 2:
                    try:
                        data[parts[0]] = int(parts[1])
                    except ValueError:
                        pass
    except FileNotFoundError:
        pass
    return data

before = read(sys.argv[1])
after = read(sys.argv[2])
for key in sorted(set(before) | set(after)):
    print(f"{key} {after.get(key, 0) - before.get(key, 0)}")
PY
}

snapshot_phys_debug() {
  local out="$1"
  if [[ -f /sys/kernel/debug/phys_reclaim_debug ]]; then
    cat /sys/kernel/debug/phys_reclaim_debug > "${out}" || true
  else
    : > "${out}"
  fi
}

snapshot_numa_maps() {
  local pid="$1"
  local out="$2"
  if [[ -d "/proc/${pid}" ]]; then
    cp "/proc/${pid}/numa_maps" "${out}" 2>/dev/null || true
  fi
}

summarize_numa_maps() {
  local in="$1"
  local out="$2"
  python3 - "$in" > "${out}" <<'PY'
import re
import sys

nodes = {}
try:
    with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            for node, pages in re.findall(r"\bN(\d+)=(\d+)\b", raw):
                nodes[int(node)] = nodes.get(int(node), 0) + int(pages)
except FileNotFoundError:
    pass
for node in sorted(nodes):
    pages = nodes[node]
    print(f"N{node}_pages {pages}")
    print(f"N{node}_bytes {pages * 4096}")
    print(f"N{node}_gib {pages * 4096 / (1024**3):.6f}")
PY
}

snapshot_numa_global() {
  local out="$1"
  {
    echo "numastat:"
    numastat 2>/dev/null || true
    echo "node0_meminfo:"
    cat /sys/devices/system/node/node0/meminfo 2>/dev/null || true
    echo "node1_meminfo:"
    cat /sys/devices/system/node/node1/meminfo 2>/dev/null || true
    echo "zoneinfo_node0:"
    awk '/^Node 0, zone/{p=1} /^Node 1, zone/{p=0} p{print}' /proc/zoneinfo 2>/dev/null || true
    echo "zoneinfo_node1:"
    awk '/^Node 1, zone/{p=1} p{print}' /proc/zoneinfo 2>/dev/null || true
  } > "${out}"
}

sample_live() {
  local pid="$1"
  local csv_path="$2"
  local out="$3"
  local interval="$4"

  python3 - "$pid" "$csv_path" "$out" "$interval" <<'PY'
import csv
import os
import re
import sys
import time

pid, mbench_csv, out_path, interval_s = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
vm_keys = [
    "numa_hint_faults",
    "numa_hint_faults_local",
    "numa_pages_migrated",
    "pgpromote_candidate",
    "pgpromote_candidate_nrl",
    "pgpromote_success",
    "pgmigrate_success",
    "pgmigrate_fail",
    "pgdemote_direct",
    "pgdemote_kswapd",
    "pgscan_direct",
    "pgscan_kswapd",
    "pgsteal_direct",
    "pgsteal_kswapd",
]
hook_keys = [
    "wake_attempts",
    "wake_no_waitq",
    "wake_skip_balanced",
    "wake_sent",
    "balance_runs",
    "kswapd_shrink",
    "kswapd_scanned_last",
    "kswapd_reclaimed_last",
    "kswapd_nr_to_reclaim_last",
    "try_shrink_calls",
    "get_scan_calls",
    "get_scan_below_min",
    "get_scan_aging",
    "get_scan_no_aging",
    "get_scan_return_neg",
    "get_scan_return_zero",
    "get_scan_raw_last",
    "get_scan_protected_last",
    "get_scan_return_last",
    "evict_calls",
    "evict_zero",
    "evict_delta_pages",
    "can_demote_true",
    "can_demote_false",
    "sort_promoted",
    "sort_protected",
    "sort_ineligible",
    "sort_writeback",
    "sort_cold",
    "scan_folios_scanned",
    "scan_folios_sorted",
    "scan_folios_isolated",
    "scan_folios_skipped",
    "scan_folios_ret_zero",
]
node_mem_keys = [
    "node0_MemFree_kB",
    "node0_Active_anon_kB",
    "node0_Inactive_anon_kB",
    "node0_Active_file_kB",
    "node0_Inactive_file_kB",
    "node1_MemFree_kB",
    "node1_Active_anon_kB",
    "node1_Inactive_anon_kB",
    "node1_Active_file_kB",
    "node1_Inactive_file_kB",
]
fieldnames = [
    "sample",
    "elapsed_ms",
    "bench_alive",
    "proc_n0_bytes",
    "proc_n1_bytes",
    "mbench_time_ms",
    "mbench_ops_delta",
] + vm_keys + node_mem_keys
for node in (0, 1):
    fieldnames.extend(f"phys_node{node}_{key}" for key in hook_keys)

def read_vmstat():
    data = {k: 0 for k in vm_keys}
    try:
        with open("/proc/vmstat", "r", encoding="utf-8") as f:
            for raw in f:
                parts = raw.split()
                if len(parts) == 2 and parts[0] in data:
                    data[parts[0]] = int(parts[1])
    except FileNotFoundError:
        pass
    return data

def read_proc_nodes():
    nodes = {0: 0, 1: 0}
    try:
        with open(f"/proc/{pid}/numa_maps", "r", encoding="utf-8", errors="replace") as f:
            for raw in f:
                for node, pages in re.findall(r"\bN(\d+)=(\d+)\b", raw):
                    node_i = int(node)
                    if node_i in nodes:
                        nodes[node_i] += int(pages) * 4096
    except FileNotFoundError:
        pass
    return nodes

def read_node_meminfo():
    data = {k: 0 for k in node_mem_keys}
    names = {
        "MemFree": "MemFree",
        "Active(anon)": "Active_anon",
        "Inactive(anon)": "Inactive_anon",
        "Active(file)": "Active_file",
        "Inactive(file)": "Inactive_file",
    }
    for node in (0, 1):
        path = f"/sys/devices/system/node/node{node}/meminfo"
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                for raw in f:
                    m = re.match(rf"Node\s+{node},\s+([^:]+):\s+(\d+)\s+kB", raw)
                    if not m:
                        continue
                    label = names.get(m.group(1).strip())
                    if label:
                        data[f"node{node}_{label}_kB"] = int(m.group(2))
        except FileNotFoundError:
            pass
    return data

def read_phys_debug():
    data = {f"phys_node{node}_{key}": 0 for node in (0, 1) for key in hook_keys}
    try:
        with open("/sys/kernel/debug/phys_reclaim_debug", "r", encoding="utf-8", errors="replace") as f:
            for raw in f:
                parts = raw.split()
                if len(parts) != 2:
                    continue
                m = re.match(r"node(\d+)_(.+)", parts[0])
                if not m:
                    continue
                node = int(m.group(1))
                key = m.group(2)
                if node in (0, 1) and key in hook_keys:
                    data[f"phys_node{node}_{key}"] = int(parts[1])
    except FileNotFoundError:
        pass
    return data

def read_last_mbench_row():
    result = {"mbench_time_ms": 0, "mbench_ops_delta": 0}
    try:
        with open(mbench_csv, "r", encoding="utf-8", errors="replace", newline="") as f:
            rows = [row for row in csv.DictReader(f) if row]
        if rows:
            row = rows[-1]
            result["mbench_time_ms"] = int(float(row.get("time_ms", "0") or 0))
            result["mbench_ops_delta"] = int(float(row.get("ops_delta", "0") or 0))
    except (FileNotFoundError, ValueError):
        pass
    return result

start = time.monotonic()
with open(out_path, "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    sample = 0
    while not os.path.exists(out_path + ".stop"):
        now = time.monotonic()
        nodes = read_proc_nodes()
        row = {
            "sample": sample,
            "elapsed_ms": int((now - start) * 1000),
            "bench_alive": 1 if os.path.isdir(f"/proc/{pid}") else 0,
            "proc_n0_bytes": nodes.get(0, 0),
            "proc_n1_bytes": nodes.get(1, 0),
        }
        row.update(read_last_mbench_row())
        row.update(read_vmstat())
        row.update(read_node_meminfo())
        row.update(read_phys_debug())
        writer.writerow(row)
        f.flush()
        sample += 1
        time.sleep(interval_s)
PY
}

summarize_run() {
  local out_json="$1"
  python3 - "${CASE_DIR}" "${POLICY_LABEL}" "${SAMPLE_MS}" "${MBENCH_FORCE_DURATION_MS}" > "${out_json}" <<'PY'
import csv
import json
import statistics
import sys
from pathlib import Path

case = Path(sys.argv[1])
policy = sys.argv[2]
sample_ms = int(sys.argv[3])
duration_ms = int(sys.argv[4])

def read_kv(path):
    data = {}
    if not path.exists():
        return data
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = raw.split()
        if len(parts) == 2:
            try:
                data[parts[0]] = int(parts[1])
            except ValueError:
                pass
    return data

def read_numa_summary(path):
    data = {}
    if not path.exists():
        return data
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = raw.split()
        if len(parts) == 2:
            try:
                data[parts[0]] = float(parts[1])
            except ValueError:
                pass
    return data

rates = []
csv_path = case / "mbench.stdout.csv"
if csv_path.exists():
    with csv_path.open("r", encoding="utf-8", errors="replace", newline="") as f:
        for row in csv.DictReader(f):
            try:
                ops_delta = int(float(row.get("ops_delta", "0") or 0))
            except ValueError:
                continue
            rates.append(ops_delta / (sample_ms / 1000.0))

steady = rates[3:] if len(rates) > 3 else rates
vm = read_kv(case / "vmstat.diff")
hook = read_kv(case / "phys_reclaim_debug.diff")
before_numa = read_numa_summary(case / "numa_maps.before.summary")
summary = {
    "candidate": "skew_lf_hotremote_32g_fixed_rss16g_mulshift_persistent",
    "policy": policy,
    "cgroup": "none/root",
    "physical_local_node_mem": "16G",
    "physical_remote_node_mem": "64G",
    "duration_ms": duration_ms,
    "numa_scan_size_mb": 4096,
    "sample_ms": sample_ms,
    "rate_samples": len(rates),
    "steady_mean_mops": (statistics.mean(steady) / 1e6) if steady else 0.0,
    "steady_median_mops": (statistics.median(steady) / 1e6) if steady else 0.0,
    "first10_mean_mops": (statistics.mean(rates[:10]) / 1e6) if len(rates) >= 10 else ((statistics.mean(rates) / 1e6) if rates else 0.0),
    "last10_mean_mops": (statistics.mean(rates[-10:]) / 1e6) if len(rates) >= 10 else ((statistics.mean(rates) / 1e6) if rates else 0.0),
    "promote_pages": vm.get("pgpromote_success", 0),
    "promote_gib": vm.get("pgpromote_success", 0) * 4096 / 1024**3,
    "demote_direct_pages": vm.get("pgdemote_direct", 0),
    "demote_kswapd_pages": vm.get("pgdemote_kswapd", 0),
    "demote_pages": vm.get("pgdemote_direct", 0) + vm.get("pgdemote_kswapd", 0),
    "demote_gib": (vm.get("pgdemote_direct", 0) + vm.get("pgdemote_kswapd", 0)) * 4096 / 1024**3,
    "promote_candidates": vm.get("pgpromote_candidate", 0),
    "migration_fail": vm.get("pgmigrate_fail", 0),
    "initial_proc_n0_gib": before_numa.get("N0_gib", 0.0),
    "initial_proc_n1_gib": before_numa.get("N1_gib", 0.0),
    "vmstat": vm,
    "phys_reclaim_debug": hook,
}
print(json.dumps(summary, indent=2, sort_keys=True))
PY
}

if [[ ! -x "${MBENCH}" ]]; then
  echo "mbench binary not executable: ${MBENCH}" >&2
  exit 1
fi

mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true

ORIG_NUMA_BALANCING="$(read_optional /proc/sys/kernel/numa_balancing || true)"
ORIG_DEMOTION_ENABLED="$(read_optional /sys/kernel/mm/numa/demotion_enabled || true)"
ORIG_DEMOTION_TARGET="$(read_optional /sys/kernel/mm/numa/demotion_target || true)"
ORIG_LRU_GEN="$(read_optional /sys/kernel/mm/lru_gen/enabled || true)"
ORIG_SCAN_SIZE="$(read_optional /sys/kernel/debug/sched/numa_balancing/scan_size_mb || true)"
ORIG_CG_SCAN_SCALE="$(read_optional "$(pick_cg_knob numa_balancing_scan_period_scale 2>/dev/null || true)" || true)"
ORIG_CG_STOP="$(read_optional "$(pick_cg_knob numa_migration_stop_enabled 2>/dev/null || true)" || true)"
ORIG_CG_PINGPONG="$(read_optional "$(pick_cg_knob numa_pingpong_stat_enabled 2>/dev/null || true)" || true)"
ORIG_CG_SAMPLE="$(read_optional "$(pick_cg_knob numa_promote_sample_stat_enabled 2>/dev/null || true)" || true)"
ORIG_CG_SAMPLE_RATE="$(read_optional "$(pick_cg_knob numa_promote_sample_rate 2>/dev/null || true)" || true)"

restore_globals() {
  [[ -n "${ORIG_NUMA_BALANCING}" ]] && write_optional /proc/sys/kernel/numa_balancing "${ORIG_NUMA_BALANCING}"
  [[ -n "${ORIG_DEMOTION_ENABLED}" ]] && write_optional /sys/kernel/mm/numa/demotion_enabled "${ORIG_DEMOTION_ENABLED}"
  [[ -n "${ORIG_DEMOTION_TARGET}" ]] && write_optional /sys/kernel/mm/numa/demotion_target "${ORIG_DEMOTION_TARGET%%$'\n'*}"
  [[ -n "${ORIG_LRU_GEN}" ]] && write_optional /sys/kernel/mm/lru_gen/enabled "${ORIG_LRU_GEN}"
  [[ -n "${ORIG_SCAN_SIZE}" ]] && write_optional /sys/kernel/debug/sched/numa_balancing/scan_size_mb "${ORIG_SCAN_SIZE}"
  [[ -n "${ORIG_CG_SCAN_SCALE}" ]] && write_root_cg_optional numa_balancing_scan_period_scale "${ORIG_CG_SCAN_SCALE}"
  [[ -n "${ORIG_CG_STOP}" ]] && write_root_cg_optional numa_migration_stop_enabled "${ORIG_CG_STOP}"
  [[ -n "${ORIG_CG_PINGPONG}" ]] && write_root_cg_optional numa_pingpong_stat_enabled "${ORIG_CG_PINGPONG}"
  [[ -n "${ORIG_CG_SAMPLE}" ]] && write_root_cg_optional numa_promote_sample_stat_enabled "${ORIG_CG_SAMPLE}"
  [[ -n "${ORIG_CG_SAMPLE_RATE}" ]] && write_root_cg_optional numa_promote_sample_rate "${ORIG_CG_SAMPLE_RATE}"
}
trap restore_globals EXIT

log "configuring physical-limit run without a workload cgroup"
write_optional /sys/kernel/mm/lru_gen/enabled "${MGLRU_ENABLED_VALUE}"
write_optional /proc/sys/kernel/numa_balancing "${NODE_BALANCING_ON}"
write_optional /sys/kernel/mm/numa/demotion_enabled "${KSWAPD_DEMOTION_ON}"
write_optional /sys/kernel/mm/numa/demotion_target "${LOCAL_NODE} ${REMOTE_NODE}"
write_optional /sys/kernel/debug/sched/numa_balancing/scan_size_mb "${NUMA_SCAN_SIZE_MB}"
write_root_cg_optional numa_balancing_scan_period_scale "${SCAN_PERIOD_SCALE}"
write_root_cg_optional numa_migration_stop_enabled "${NUMA_MIGRATION_STOP_ENABLED}"
write_root_cg_optional numa_pingpong_stat_enabled "${NUMA_PINGPONG_STAT_ENABLED}"
write_root_cg_optional numa_promote_sample_stat_enabled "${NUMA_PROMOTE_SAMPLE_STAT_ENABLED}"
write_root_cg_optional numa_promote_sample_rate "${NUMA_PROMOTE_SAMPLE_RATE}"

if [[ -w /sys/fs/cgroup/cgroup.procs ]]; then
  echo "$$" > /sys/fs/cgroup/cgroup.procs || true
fi

cat > "${RUN_ROOT}/run_meta.txt" <<EOF
run_id=${RUN_ID}
mode=physical_node16_no_cgroup
candidate=skew_lf_hotremote_32g_fixed_rss16g_mulshift_persistent
policy=${POLICY_LABEL}
cgroup=none/root
local_node=${LOCAL_NODE}
remote_node=${REMOTE_NODE}
cpuset_cpus=${CPUSET_CPUS}
threads=${THREADS}
arena_size=${ARENA_SIZE}
duration_ms=${MBENCH_FORCE_DURATION_MS}
numa_scan_size_mb=${NUMA_SCAN_SIZE_MB}
scan_period_scale=${SCAN_PERIOD_SCALE}
hot_threshold_ms=${HOT_THRESHOLD_MS}
node_balancing_on=${NODE_BALANCING_ON}
demotion_enabled=${KSWAPD_DEMOTION_ON}
mglru_requested=${MGLRU_ENABLED_VALUE}
numa_migration_stop_enabled=${NUMA_MIGRATION_STOP_ENABLED}
numa_pingpong_stat_enabled=${NUMA_PINGPONG_STAT_ENABLED}
numa_promote_sample_stat_enabled=${NUMA_PROMOTE_SAMPLE_STAT_ENABLED}
numa_promote_sample_rate=${NUMA_PROMOTE_SAMPLE_RATE}
live_sample_sec=${LIVE_SAMPLE_SEC}
EOF

{
  echo "uname=$(uname -a)"
  echo "runner_cgroup=$(cat /proc/$$/cgroup 2>/dev/null || true)"
  echo "numa_balancing=$(read_optional /proc/sys/kernel/numa_balancing || true)"
  echo "demotion_enabled=$(read_optional /sys/kernel/mm/numa/demotion_enabled || true)"
  echo "demotion_target=$(read_optional /sys/kernel/mm/numa/demotion_target || true)"
  echo "lru_gen_enabled=$(read_optional /sys/kernel/mm/lru_gen/enabled || true)"
  echo "scan_size_mb=$(read_optional /sys/kernel/debug/sched/numa_balancing/scan_size_mb || true)"
  echo "rootcg_scan_period_scale=$(read_optional "$(pick_cg_knob numa_balancing_scan_period_scale 2>/dev/null || true)" || true)"
  echo "rootcg_migration_stop=$(read_optional "$(pick_cg_knob numa_migration_stop_enabled 2>/dev/null || true)" || true)"
  echo "rootcg_pingpong_stat=$(read_optional "$(pick_cg_knob numa_pingpong_stat_enabled 2>/dev/null || true)" || true)"
  echo "rootcg_promote_sample_stat=$(read_optional "$(pick_cg_knob numa_promote_sample_stat_enabled 2>/dev/null || true)" || true)"
  echo "rootcg_promote_sample_rate=$(read_optional "$(pick_cg_knob numa_promote_sample_rate 2>/dev/null || true)" || true)"
  echo "phys_reclaim_debug_exists=$([[ -f /sys/kernel/debug/phys_reclaim_debug ]] && echo 1 || echo 0)"
  echo "meminfo:"
  cat /proc/meminfo
  echo "numa:"
  numactl --hardware 2>/dev/null || true
} > "${RUN_ROOT}/guest_state.before.txt"

READY_FILE="${CASE_DIR}/mbench.prefault.ready"
START_FILE="${CASE_DIR}/mbench.start"

MBENCH_ARGS=(
  --csv
  --quiet
  --sample-ms "${SAMPLE_MS}"
  --ops-per-pass "${OPS_PER_PASS}"
  --pause-ns "${PAUSE_NS}"
  --arena-size "${ARENA_SIZE}"
  --mode skewed-hotset
  --window-size 32G
  --window-offset 0
  --move-policy fixed
  --hotset-pages 8388608
  --hot-prob-pct 100
  --hotset-read-pct 100
  --hotset-write-pct 0
  --hotset-rmw-pct 0
  --hotset-index-mode mulshift
  --hotset-prefault-node "${REMOTE_NODE}"
  --threads "${THREADS}"
  --duration-ms "${MBENCH_FORCE_DURATION_MS}"
)

printf '%q ' taskset -c "${CPUSET_CPUS}" "${MBENCH}" "${MBENCH_ARGS[@]}" > "${CASE_DIR}/cmd.txt"
printf '\n' >> "${CASE_DIR}/cmd.txt"

snapshot_vmstat "${CASE_DIR}/vmstat.preprefault"
snapshot_phys_debug "${CASE_DIR}/phys_reclaim_debug.preprefault"
snapshot_numa_global "${CASE_DIR}/numa_global.preprefault.txt"

log "starting mbench with prefault gate"
MBENCH_READY_FILE="${READY_FILE}" MBENCH_START_FILE="${START_FILE}" \
  taskset -c "${CPUSET_CPUS}" "${MBENCH}" "${MBENCH_ARGS[@]}" \
  > "${CASE_DIR}/mbench.stdout.csv" 2> "${CASE_DIR}/mbench.stderr.txt" &
bench_pid=$!
cat "/proc/${bench_pid}/cgroup" > "${CASE_DIR}/bench.cgroup" 2>/dev/null || true

watchdog_pid=""
(
  sleep "${TIMEOUT_SEC}" &
  sleep_pid=$!
  trap 'kill "${sleep_pid}" 2>/dev/null || true; exit 0' TERM INT
  wait "${sleep_pid}" || exit 0
  if kill -0 "${bench_pid}" 2>/dev/null; then
    echo "watchdog timeout after ${TIMEOUT_SEC}s" >> "${CASE_DIR}/mbench.stderr.txt"
    kill -TERM "${bench_pid}" 2>/dev/null || true
  fi
) &
watchdog_pid=$!

deadline=$((SECONDS + PREFAULT_READY_TIMEOUT_SEC))
while [[ ! -f "${READY_FILE}" ]]; do
  if ! kill -0 "${bench_pid}" 2>/dev/null; then
    echo "mbench exited before prefault ready" >&2
    wait "${bench_pid}" || true
    exit 1
  fi
  if (( SECONDS >= deadline )); then
    echo "timed out waiting for mbench prefault ready" >&2
    kill -TERM "${bench_pid}" 2>/dev/null || true
    wait "${bench_pid}" || true
    exit 1
  fi
  sleep 1
done

snapshot_vmstat "${CASE_DIR}/vmstat.before"
snapshot_phys_debug "${CASE_DIR}/phys_reclaim_debug.before"
snapshot_numa_global "${CASE_DIR}/numa_global.before.txt"
snapshot_numa_maps "${bench_pid}" "${CASE_DIR}/numa_maps.before"
summarize_numa_maps "${CASE_DIR}/numa_maps.before" "${CASE_DIR}/numa_maps.before.summary"

sample_live "${bench_pid}" "${CASE_DIR}/mbench.stdout.csv" "${CASE_DIR}/live.csv" "${LIVE_SAMPLE_SEC}" &
sampler_pid=$!

touch "${START_FILE}"
set +e
wait "${bench_pid}"
bench_rc=$?
set -e

touch "${CASE_DIR}/live.csv.stop"
wait "${sampler_pid}" 2>/dev/null || true
if [[ -n "${watchdog_pid}" ]]; then
  kill "${watchdog_pid}" 2>/dev/null || true
  wait "${watchdog_pid}" 2>/dev/null || true
fi

snapshot_vmstat "${CASE_DIR}/vmstat.after"
snapshot_phys_debug "${CASE_DIR}/phys_reclaim_debug.after"
snapshot_numa_global "${CASE_DIR}/numa_global.after.txt"
diff_kv "${CASE_DIR}/vmstat.before" "${CASE_DIR}/vmstat.after" "${CASE_DIR}/vmstat.diff"
diff_kv "${CASE_DIR}/phys_reclaim_debug.before" "${CASE_DIR}/phys_reclaim_debug.after" "${CASE_DIR}/phys_reclaim_debug.diff"

{
  echo "returncode=${bench_rc}"
  echo "numa_balancing=$(read_optional /proc/sys/kernel/numa_balancing || true)"
  echo "demotion_enabled=$(read_optional /sys/kernel/mm/numa/demotion_enabled || true)"
  echo "demotion_target=$(read_optional /sys/kernel/mm/numa/demotion_target || true)"
  echo "lru_gen_enabled=$(read_optional /sys/kernel/mm/lru_gen/enabled || true)"
  echo "scan_size_mb=$(read_optional /sys/kernel/debug/sched/numa_balancing/scan_size_mb || true)"
  echo "rootcg_scan_period_scale=$(read_optional "$(pick_cg_knob numa_balancing_scan_period_scale 2>/dev/null || true)" || true)"
  echo "rootcg_migration_stop=$(read_optional "$(pick_cg_knob numa_migration_stop_enabled 2>/dev/null || true)" || true)"
  echo "rootcg_pingpong_stat=$(read_optional "$(pick_cg_knob numa_pingpong_stat_enabled 2>/dev/null || true)" || true)"
  echo "rootcg_promote_sample_stat=$(read_optional "$(pick_cg_knob numa_promote_sample_stat_enabled 2>/dev/null || true)" || true)"
  echo "rootcg_promote_sample_rate=$(read_optional "$(pick_cg_knob numa_promote_sample_rate 2>/dev/null || true)" || true)"
} > "${CASE_DIR}/status.after.txt"

summarize_run "${CASE_DIR}/summary.json"
cp "${CASE_DIR}/summary.json" "${RUN_ROOT}/summary.json"
cat "${CASE_DIR}/summary.json" >> "${RUN_ROOT}/summary.jsonl"

log "complete rc=${bench_rc}; artifacts=${RUN_ROOT}"
exit "${bench_rc}"
