#!/usr/bin/env bash
set -euo pipefail

OUTROOT="${OUTROOT:-/root/gapbs-toggle-ours-window-sweep}"
RUNNER="${RUNNER:-/root/scripts/run_local_util_toggle_experiment.sh}"
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
  echo "policy=toggle_ours"
  echo "scan_size_mb=256"
  echo "scan_period_min_ms=1000"
  echo "fast_scan=0"
  echo "hot_threshold_ms=0"
  echo "reenable_consecutive=2"
} > "${OUTROOT}/experiment_config.txt"

run_toggle() {
  local workload="$1"
  local cap_label="$2"
  local cap_pages="$3"
  local window_sec="$4"
  local outdir="${OUTROOT}/${workload}-${cap_label}-w${window_sec}/toggle"
  local workload_cmd=()

  mkdir -p "${outdir}"
  case "${workload}" in
    pr)
      workload_cmd=(/root/pr -f "${GRAPH}" -i20 -t1e-4 -n "${TRIALS}")
      ;;
    bc)
      workload_cmd=(/root/bc -f "${GRAPH}" -i1 -n "${TRIALS}")
      ;;
    *)
      log "unknown workload ${workload}"
      exit 2
      ;;
  esac

  log "start workload=${workload} cap=${cap_label} window=${window_sec}s policy=toggle"
  sync || true
  echo 3 > /proc/sys/vm/drop_caches || true

  "${RUNNER}" \
    --outdir "${outdir}" \
    --run-id "${workload}-${cap_label}-w${window_sec}-toggle" \
    --cgroup-name "gapbs_toggle_${workload}_${cap_label}_w${window_sec}_$$" \
    --policy ours \
    --capacity-node 0 \
    --capacity-pages "${cap_pages}" \
    --node-balancing 2 \
    --kswapd-demotion 1 \
    --global-numa-balancing 0 \
    --global-demotion-enabled 1 \
    --global-demotion-target "0 1" \
    --scan-size-mb 256 \
    --scan-period-min-ms 1000 \
    --fast-scan 0 \
    --hot-threshold-ms 0 \
    --mglru 0x0007 \
    --cpuset-cpus 0-31 \
    --cpuset-mems 0,1 \
    --omp-threads "${OMP_THREADS}" \
    --timeout-sec "${TIMEOUT_SEC}" \
    --window-sec "${window_sec}" \
    --threshold-pct 80 \
    --consecutive 3 \
    --min-pte-updates 1000 \
    --remote-threshold-pct 20 \
    --remote-consecutive 3 \
    --min-hint-faults 1000 \
    --local-fault-sample-pct 10 \
    --eval-lag prev \
    -- \
    "${workload_cmd[@]}"

  log "done workload=${workload} cap=${cap_label} window=${window_sec}s policy=toggle"
}

for workload in pr bc; do
  for window in 5 10 20; do
    run_toggle "${workload}" 8g 2097152 "${window}"
    run_toggle "${workload}" 16g 4194304 "${window}"
  done
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

def events(path):
    offs = []
    ons = []
    final_state = ""
    if path.exists():
        with path.open(newline="") as handle:
            for row in csv.DictReader(handle):
                event = row.get("event")
                final_state = row.get("controller_state", final_state)
                if event == "off":
                    offs.append(row)
                elif event == "on":
                    ons.append(row)
    return offs, ons, final_state

rows = []
for case_dir in sorted(root.glob("*-*g-w*/toggle")):
    name = case_dir.parent.name
    m = re.fullmatch(r"(pr|bc)-(8g|16g)-w([0-9]+)", name)
    if not m:
        continue
    workload, cap, window_sec = m.groups()
    cfg = read_kv(case_dir / "run_config.txt")
    status = read_kv(case_dir / "status.txt")
    read_s, avg_s, trials = parse_stdout(case_dir / "workload.stdout.log")
    offs, ons, final_state = events(case_dir / "controller.csv")
    first_off = offs[0] if offs else {}
    first_on = ons[0] if ons else {}
    row = {
        "workload": workload,
        "cap": cap,
        "window_sec": window_sec,
        "policy": "toggle",
        "returncode": status.get("returncode", ""),
        "elapsed_s": status.get("elapsed_s", ""),
        "read_s": read_s,
        "avg_trial_s": avg_s,
        "off_count": len(offs),
        "on_count": len(ons),
        "first_off_ms": first_off.get("elapsed_ms", ""),
        "first_off_window": first_off.get("window", ""),
        "first_off_reason": first_off.get("stop_reason", ""),
        "first_on_ms": first_on.get("elapsed_ms", ""),
        "first_on_window": first_on.get("window", ""),
        "final_controller_state": final_state,
        "capacity_pages": cfg.get("capacity_pages", ""),
        "reenable_consecutive": cfg.get("reenable_consecutive", ""),
        "numa_hint_faults": delta(case_dir, "numa_hint_faults"),
        "pgpromote_success": delta(case_dir, "pgpromote_success"),
        "pgdemote_kswapd": delta(case_dir, "pgdemote_kswapd"),
        "pgdemote_direct": delta(case_dir, "pgdemote_direct"),
    }
    for idx, value in enumerate(trials, 1):
        row[f"trial{idx}_s"] = value
    rows.append(row)

fields = [
    "workload", "cap", "window_sec", "policy", "returncode", "elapsed_s",
    "read_s", "avg_trial_s", "off_count", "on_count", "first_off_ms",
    "first_off_window", "first_off_reason", "first_on_ms", "first_on_window",
    "final_controller_state", "capacity_pages", "reenable_consecutive",
    "numa_hint_faults", "pgpromote_success", "pgdemote_kswapd",
    "pgdemote_direct",
] + [f"trial{i}_s" for i in range(1, 9)]

summary.parent.mkdir(parents=True, exist_ok=True)
with summary.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fields)
    writer.writeheader()
    writer.writerows(rows)
PY

log "all toggle cases complete; summary=${OUTROOT}/summary.csv"
