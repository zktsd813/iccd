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
WINDOW_SIZE="${WINDOW_SIZE:-16G}"
WINDOW_OFFSET="${WINDOW_OFFSET:-0}"
HOTSET_PAGES="${HOTSET_PAGES:-4194304}"
SAMPLE_MS="${SAMPLE_MS:-1000}"
OPS_PER_PASS="${OPS_PER_PASS:-65536}"
PAUSE_NS="${PAUSE_NS:-100000}"
TIMEOUT_SEC="${TIMEOUT_SEC:-900}"
NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-4096}"
MGLRU_ENABLED_VALUE="${MGLRU_ENABLED_VALUE:-0x0007}"
NODE_BALANCING_ON="${NODE_BALANCING_ON:-2}"
KSWAPD_DEMOTION_ON="${KSWAPD_DEMOTION_ON:-1}"
PREFAULT_READY_TIMEOUT_SEC="${PREFAULT_READY_TIMEOUT_SEC:-300}"
MBENCH_FORCE_DURATION_MS="${MBENCH_FORCE_DURATION_MS:-60000}"
POLICY_LABEL="${POLICY_LABEL:-on}"

RUN_ROOT="${OUTDIR}/${RUN_ID}"
CASE_DIR="${RUN_ROOT}/skew_lf_hotremote_16g_fixed_physical_node16_nocg__${POLICY_LABEL}__rep1"
mkdir -p "${CASE_DIR}"

log() {
  printf '[physical-node16-hss16] %s\n' "$*"
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

snapshot_vmstat() {
  local out="$1"
  python3 > "${out}" <<'PY'
keys = {
    "numa_miss",
    "numa_other",
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

diff_vmstat() {
  local before="$1"
  local after="$2"
  local out="$3"
  python3 - "$before" "$after" > "$out" <<'PY'
import sys

def read(path):
    data = {}
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            parts = raw.split()
            if len(parts) == 2:
                data[parts[0]] = int(parts[1])
    return data

before = read(sys.argv[1])
after = read(sys.argv[2])
for key in sorted(set(before) | set(after)):
    print(f"{key} {after.get(key, 0) - before.get(key, 0)}")
PY
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
  python3 - "$in" > "$out" <<'PY'
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

sample_live() {
  local pid="$1"
  local out="$2"
  python3 - "$pid" "$out" <<'PY'
import csv
import os
import re
import sys
import time

pid = sys.argv[1]
out_path = sys.argv[2]
keys = [
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
fieldnames = ["sample", "elapsed_ms", "bench_alive", "proc_n0_bytes", "proc_n1_bytes"] + keys

def read_vmstat():
    data = {k: 0 for k in keys}
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

start = time.monotonic()
with open(out_path, "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    sample = 0
    while not os.path.exists(out_path + ".stop"):
        vm = read_vmstat()
        nodes = read_proc_nodes()
        row = {
            "sample": sample,
            "elapsed_ms": int((time.monotonic() - start) * 1000),
            "bench_alive": 1 if os.path.isdir(f"/proc/{pid}") else 0,
            "proc_n0_bytes": nodes.get(0, 0),
            "proc_n1_bytes": nodes.get(1, 0),
        }
        row.update(vm)
        writer.writerow(row)
        f.flush()
        sample += 1
        time.sleep(1)
PY
}

summarize_run() {
  local out_json="$1"
  python3 - "${CASE_DIR}" "${POLICY_LABEL}" "${HOTSET_PAGES}" > "${out_json}" <<'PY'
import csv
import json
import statistics
import sys
from pathlib import Path

case = Path(sys.argv[1])
policy = sys.argv[2]
hss_pages = int(sys.argv[3])

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

def read_float_kv(path):
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
        reader = csv.DictReader(f)
        for row in reader:
            try:
                if int(row.get("time_ms", "0")) > 0:
                    rates.append(float(row.get("ops_delta", "0")))
            except ValueError:
                pass

steady = rates[3:] if len(rates) > 3 else rates
vm = read_kv(case / "vmstat.diff")
before_numa = read_float_kv(case / "numa_maps.before.summary")
candidate = vm.get("pgpromote_candidate", 0)
promoted = vm.get("pgpromote_success", 0)
failed = vm.get("pgmigrate_fail", 0)

summary = {
    "candidate": "skew_lf_hotremote_16g_fixed_physical_node16_nocg",
    "policy": policy,
    "cgroup": "none",
    "physical_local_node_mem": "16G",
    "physical_remote_node_mem": "64G",
    "hotset_pages": hss_pages,
    "steady_mean_rate": statistics.mean(steady) if steady else 0.0,
    "steady_median_rate": statistics.median(steady) if steady else 0.0,
    "first10_mean_rate": statistics.mean(rates[:10]) if len(rates) >= 10 else (statistics.mean(rates) if rates else 0.0),
    "last10_mean_rate": statistics.mean(rates[-10:]) if len(rates) >= 10 else (statistics.mean(rates) if rates else 0.0),
    "hint_faults": vm.get("numa_hint_faults", 0),
    "candidate_pages": candidate,
    "candidate_over_hss": candidate / hss_pages if hss_pages else 0.0,
    "promote_pages": promoted,
    "promote_gib": promoted * 4096 / 1024**3,
    "promote_over_hss": promoted / hss_pages if hss_pages else 0.0,
    "promote_over_candidate": promoted / candidate if candidate else 0.0,
    "pgmigrate_fail": failed,
    "pgmigrate_fail_over_hss": failed / hss_pages if hss_pages else 0.0,
    "pgmigrate_success": vm.get("pgmigrate_success", 0),
    "demote_direct_pages": vm.get("pgdemote_direct", 0),
    "demote_kswapd_pages": vm.get("pgdemote_kswapd", 0),
    "demote_pages": vm.get("pgdemote_direct", 0) + vm.get("pgdemote_kswapd", 0),
    "demote_gib": (vm.get("pgdemote_direct", 0) + vm.get("pgdemote_kswapd", 0)) * 4096 / 1024**3,
    "initial_proc_n0_gib": before_numa.get("N0_gib", 0.0),
    "initial_proc_n1_gib": before_numa.get("N1_gib", 0.0),
}
for key, value in vm.items():
    summary[f"vmstat.{key}"] = value
print(json.dumps(summary, indent=2, sort_keys=True))
PY
}

ORIG_NUMA_BALANCING="$(read_optional /proc/sys/kernel/numa_balancing || true)"
ORIG_DEMOTION_ENABLED="$(read_optional /sys/kernel/mm/numa/demotion_enabled || true)"
ORIG_DEMOTION_TARGET="$(read_optional /sys/kernel/mm/numa/demotion_target || true)"
ORIG_LRU_GEN="$(read_optional /sys/kernel/mm/lru_gen/enabled || true)"
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
ORIG_SCAN_SIZE="$(read_optional /sys/kernel/debug/sched/numa_balancing/scan_size_mb || true)"

restore_globals() {
  [[ -n "${ORIG_NUMA_BALANCING}" ]] && write_optional /proc/sys/kernel/numa_balancing "${ORIG_NUMA_BALANCING}"
  [[ -n "${ORIG_DEMOTION_ENABLED}" ]] && write_optional /sys/kernel/mm/numa/demotion_enabled "${ORIG_DEMOTION_ENABLED}"
  [[ -n "${ORIG_DEMOTION_TARGET}" ]] && write_optional /sys/kernel/mm/numa/demotion_target "${ORIG_DEMOTION_TARGET%%$'\n'*}"
  [[ -n "${ORIG_LRU_GEN}" ]] && write_optional /sys/kernel/mm/lru_gen/enabled "${ORIG_LRU_GEN}"
  [[ -n "${ORIG_SCAN_SIZE}" ]] && write_optional /sys/kernel/debug/sched/numa_balancing/scan_size_mb "${ORIG_SCAN_SIZE}"
}
trap restore_globals EXIT

if [[ ! -x "${MBENCH}" ]]; then
  echo "mbench binary not executable: ${MBENCH}" >&2
  exit 1
fi

log "configuring global memory tiering knobs without a workload cgroup"
write_optional /sys/kernel/mm/lru_gen/enabled "${MGLRU_ENABLED_VALUE}"
write_optional /proc/sys/kernel/numa_balancing "${NODE_BALANCING_ON}"
write_optional /sys/kernel/mm/numa/demotion_enabled "${KSWAPD_DEMOTION_ON}"
write_optional /sys/kernel/mm/numa/demotion_target "${LOCAL_NODE} ${REMOTE_NODE}"
write_optional /sys/kernel/debug/sched/numa_balancing/scan_size_mb "${NUMA_SCAN_SIZE_MB}"

if [[ -w /sys/fs/cgroup/cgroup.procs ]]; then
  echo "$$" > /sys/fs/cgroup/cgroup.procs || true
fi

cat > "${RUN_ROOT}/run_meta.txt" <<EOF
run_id=${RUN_ID}
mode=physical_node16_no_cgroup
candidate=skew_lf_hotremote_16g_fixed_physical_node16_nocg
policy=${POLICY_LABEL}
cgroup=none
local_node=${LOCAL_NODE}
remote_node=${REMOTE_NODE}
physical_local_node_mem=16G
physical_remote_node_mem=64G
cpuset_cpus=${CPUSET_CPUS}
threads=${THREADS}
arena_size=${ARENA_SIZE}
window_size=${WINDOW_SIZE}
window_offset=${WINDOW_OFFSET}
hotset_pages=${HOTSET_PAGES}
duration_ms=${MBENCH_FORCE_DURATION_MS}
numa_scan_size_mb=${NUMA_SCAN_SIZE_MB}
node_balancing_on=${NODE_BALANCING_ON}
demotion_enabled=${KSWAPD_DEMOTION_ON}
mglru_requested=${MGLRU_ENABLED_VALUE}
EOF

{
  echo "uname=$(uname -a)"
  echo "runner_cgroup=$(cat /proc/$$/cgroup 2>/dev/null || true)"
  echo "numa_balancing=$(read_optional /proc/sys/kernel/numa_balancing || true)"
  echo "demotion_enabled=$(read_optional /sys/kernel/mm/numa/demotion_enabled || true)"
  echo "demotion_target=$(read_optional /sys/kernel/mm/numa/demotion_target || true)"
  echo "lru_gen_enabled=$(read_optional /sys/kernel/mm/lru_gen/enabled || true)"
  echo "scan_size_mb=$(read_optional /sys/kernel/debug/sched/numa_balancing/scan_size_mb || true)"
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
  --window-size "${WINDOW_SIZE}"
  --window-offset "${WINDOW_OFFSET}"
  --move-policy fixed
  --hotset-pages "${HOTSET_PAGES}"
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

log "starting mbench with prefault gate"
MBENCH_READY_FILE="${READY_FILE}" MBENCH_START_FILE="${START_FILE}" \
  taskset -c "${CPUSET_CPUS}" "${MBENCH}" "${MBENCH_ARGS[@]}" \
  > "${CASE_DIR}/mbench.stdout.csv" 2> "${CASE_DIR}/mbench.stderr.txt" &
bench_pid=$!
cat "/proc/${bench_pid}/cgroup" > "${CASE_DIR}/bench.cgroup" 2>/dev/null || true

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
  sleep 0.1
done

snapshot_vmstat "${CASE_DIR}/vmstat.before"
snapshot_numa_maps "${bench_pid}" "${CASE_DIR}/numa_maps.before"
summarize_numa_maps "${CASE_DIR}/numa_maps.before" "${CASE_DIR}/numa_maps.before.summary"

sample_live "${bench_pid}" "${CASE_DIR}/live.csv" &
sampler_pid=$!

touch "${START_FILE}"
set +e
wait "${bench_pid}"
ret=$?
set -e

touch "${CASE_DIR}/live.csv.stop"
wait "${sampler_pid}" 2>/dev/null || true
rm -f "${CASE_DIR}/live.csv.stop"

snapshot_vmstat "${CASE_DIR}/vmstat.after"
diff_vmstat "${CASE_DIR}/vmstat.before" "${CASE_DIR}/vmstat.after" "${CASE_DIR}/vmstat.diff"
summarize_run "${CASE_DIR}/summary.json"
cp "${CASE_DIR}/summary.json" "${RUN_ROOT}/summary.json"
cp "${CASE_DIR}/summary.json" "${RUN_ROOT}/summary.jsonl"

log "complete rc=${ret}; artifacts=${RUN_ROOT}"
exit "${ret}"
