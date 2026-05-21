#!/usr/bin/env bash
set -euo pipefail

OUTROOT="${OUTROOT:-/root/gapbs-placement-alllocal-allremote}"
RUNNER="${RUNNER:-/root/scripts/run_local_util_adapt_experiment.sh}"
GRAPH="${GRAPH:-/root/gapbs_graphs/kron_g28.sg}"
TRIALS="${TRIALS:-8}"
TIMEOUT_SEC="${TIMEOUT_SEC:-3600}"
OMP_THREADS="${OMP_THREADS:-32}"

mkdir -p "${OUTROOT}"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "${OUTROOT}/orchestrator.log"
}

require_file() {
  local path="$1"
  if [[ ! -e "${path}" ]]; then
    log "missing required file: ${path}"
    exit 1
  fi
}

require_file "${RUNNER}"
require_file /root/pr
require_file /root/bc
require_file "${GRAPH}"
chmod +x "${RUNNER}" /root/pr /root/bc

if [[ -e /sys/kernel/mm/lru_gen/enabled ]]; then
  echo 0x0007 > /sys/kernel/mm/lru_gen/enabled || true
fi
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true

{
  echo "uname=$(uname -a)"
  echo "lru_gen_enabled=$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || true)"
  echo "graph=${GRAPH}"
  echo "graph_size_bytes=$(stat -c %s "${GRAPH}")"
  echo "trials=${TRIALS}"
  echo "timeout_sec=${TIMEOUT_SEC}"
  echo "omp_threads=${OMP_THREADS}"
  echo "placement_baseline=cpuset.mems only"
  echo "policy=off"
  echo "capacity_pages=0"
  echo "node_balancing=0"
  echo "global_numa_balancing=0"
  echo "global_demotion_enabled=0"
  echo "kswapd_demotion=0"
  echo "local_fault=0"
} > "${OUTROOT}/experiment_config.txt"

workload_cmd() {
  local workload="$1"
  if [[ "${workload}" == "pr" ]]; then
    printf '%s\0' /root/pr -f "${GRAPH}" -i20 -t1e-4 -n "${TRIALS}"
  else
    printf '%s\0' /root/bc -f "${GRAPH}" -i1 -n "${TRIALS}"
  fi
}

run_case() {
  local workload="$1"
  local placement="$2"
  local mems="$3"
  local outdir="${OUTROOT}/${workload}/${placement}"
  local cmd=()

  mkdir -p "${outdir}"
  mapfile -d '' -t cmd < <(workload_cmd "${workload}")

  log "start workload=${workload} placement=${placement} cpuset.mems=${mems}"
  sync || true
  echo 3 > /proc/sys/vm/drop_caches || true

  set +e
  "${RUNNER}" \
    --outdir "${outdir}" \
    --run-id "${workload}-${placement}" \
    --cgroup-name "gapbs_place_${workload}_${placement}_$$" \
    --capacity-node 0 \
    --capacity-pages 0 \
    --node-balancing 0 \
    --scan-size-mb 256 \
    --scan-period-min-ms 1000 \
    --fast-scan 0 \
    --hot-threshold-ms 0 \
    --mglru 0x0007 \
    --cpuset-cpus 0-31 \
    --cpuset-mems "${mems}" \
    --omp-threads "${OMP_THREADS}" \
    --timeout-sec "${TIMEOUT_SEC}" \
    --policy off \
    --kswapd-demotion 0 \
    --global-numa-balancing 0 \
    --global-demotion-enabled 0 \
    --global-demotion-target "0 1" \
    -- \
    "${cmd[@]}"
  local rc=$?
  set -e

  log "done workload=${workload} placement=${placement} rc=${rc}"
}

for workload in pr bc; do
  run_case "${workload}" all-local 0
  run_case "${workload}" all-remote 1
done

python3 - <<'PY' "${OUTROOT}/summary.csv" "${OUTROOT}"
import csv
import re
import sys
from pathlib import Path

summary = Path(sys.argv[1])
root = Path(sys.argv[2])

def read_kv(path):
    data = {}
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                data[k.strip()] = v.strip()
    return data

def parse_stdout(path):
    read_s = ""
    avg_s = ""
    trials = []
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            m = re.search(r"Read Time:\s*([0-9.]+)", line)
            if m:
                read_s = m.group(1)
            m = re.search(r"Trial Time:\s*([0-9.]+)", line)
            if m:
                trials.append(m.group(1))
            m = re.search(r"Average Time:\s*([0-9.]+)", line)
            if m:
                avg_s = m.group(1)
    return read_s, avg_s, trials

def read_vm(path):
    data = {}
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            fields = line.split()
            if len(fields) >= 2:
                try:
                    data[fields[0]] = int(fields[1])
                except ValueError:
                    pass
    return data

def delta(case_dir, key):
    before = read_vm(case_dir / "vmstat.before")
    after = read_vm(case_dir / "vmstat.after")
    return after.get(key, 0) - before.get(key, 0)

def numa_max_kb(path, node):
    value = ""
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            if line.startswith("anon "):
                m = re.search(rf"N{node}=([0-9]+)", line)
                if m:
                    value = m.group(1)
    return value

rows = []
for workload_dir in sorted(p for p in root.iterdir() if p.is_dir()):
    workload = workload_dir.name
    if workload not in ("pr", "bc"):
        continue
    for case_dir in sorted(p for p in workload_dir.iterdir() if p.is_dir()):
        placement = case_dir.name
        status = read_kv(case_dir / "status.txt")
        cfg = read_kv(case_dir / "run_config.txt")
        read_s, avg_s, trials = parse_stdout(case_dir / "workload.stdout.log")
        row = {
            "workload": workload,
            "placement": placement,
            "returncode": status.get("returncode", ""),
            "elapsed_s": status.get("elapsed_s", ""),
            "read_s": read_s,
            "avg_trial_s": avg_s,
            "cpuset_mems": cfg.get("workload", ""),
            "capacity_pages": cfg.get("capacity_pages", ""),
            "numa_hint_faults": delta(case_dir, "numa_hint_faults"),
            "pgpromote_success": delta(case_dir, "pgpromote_success"),
            "pgdemote_kswapd": delta(case_dir, "pgdemote_kswapd"),
            "pgdemote_direct": delta(case_dir, "pgdemote_direct"),
            "anon_n0_before_kb": numa_max_kb(case_dir / "cgroup.before", 0),
            "anon_n1_before_kb": numa_max_kb(case_dir / "cgroup.before", 1),
            "anon_n0_after_kb": numa_max_kb(case_dir / "cgroup.after", 0),
            "anon_n1_after_kb": numa_max_kb(case_dir / "cgroup.after", 1),
        }
        for idx in range(8):
            row[f"trial{idx + 1}_s"] = trials[idx] if idx < len(trials) else ""
        rows.append(row)

fieldnames = [
    "workload", "placement", "returncode", "elapsed_s", "read_s",
    "avg_trial_s", "capacity_pages", "numa_hint_faults",
    "pgpromote_success", "pgdemote_kswapd", "pgdemote_direct",
    "anon_n0_before_kb", "anon_n1_before_kb", "anon_n0_after_kb",
    "anon_n1_after_kb",
] + [f"trial{i}_s" for i in range(1, 9)]
with summary.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    for row in rows:
        writer.writerow({k: row.get(k, "") for k in fieldnames})
PY

log "summary=${OUTROOT}/summary.csv"
