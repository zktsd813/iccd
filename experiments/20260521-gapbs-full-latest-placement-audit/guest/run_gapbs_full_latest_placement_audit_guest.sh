#!/usr/bin/env bash
set -euo pipefail

OUTROOT="${OUTROOT:-/root/gapbs-full-latest-placement-audit}"
RUNNER="${RUNNER:-/root/scripts/run_local_util_adapt_experiment.sh}"
TOGGLE_RUNNER="${TOGGLE_RUNNER:-/root/scripts/run_local_util_toggle_experiment.sh}"
GRAPH="${GRAPH:-/root/gapbs_graphs/kron_g28.sg}"
TRIALS="${TRIALS:-8}"
TIMEOUT_SEC="${TIMEOUT_SEC:-3600}"
OMP_THREADS="${OMP_THREADS:-32}"
MONITOR_SEC="${MONITOR_SEC:-5}"

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
require_file "${TOGGLE_RUNNER}"
require_file /root/pr
require_file /root/bc
require_file "${GRAPH}"
chmod +x "${RUNNER}" "${TOGGLE_RUNNER}" /root/pr /root/bc

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
  echo "monitor_sec=${MONITOR_SEC}"
  echo "scan_size_mb=256"
  echo "scan_period_min_ms=1000"
  echo "fast_scan=0"
  echo "hot_threshold_ms=0"
  echo "toggle_reenable_consecutive=2"
  echo "placement_note=policy experiments allow cpuset.mems=0,1; live monitor records actual anon/file placement"
} > "${OUTROOT}/experiment_config.txt"

workload_cmd() {
  local workload="$1"
  if [[ "${workload}" == "pr" ]]; then
    printf '%s\0' /root/pr -f "${GRAPH}" -i20 -t1e-4 -n "${TRIALS}"
  else
    printf '%s\0' /root/bc -f "${GRAPH}" -i1 -n "${TRIALS}"
  fi
}

field_value() {
  local line="$1"
  local node="$2"
  local value
  value="$(printf '%s\n' "${line}" | sed -n "s/.*N${node}=\\([0-9][0-9]*\\).*/\\1/p")"
  printf '%s' "${value:-0}"
}

stat_value() {
  local file="$1"
  local key="$2"
  awk -v key="${key}" '$1 == key { print $2; found=1; exit } END { if (!found) print 0 }' "${file}" 2>/dev/null
}

migrate_value() {
  local cg="$1"
  local key="$2"
  local file=""
  if [[ -e "${cg}/numa_migrate_state" ]]; then
    file="${cg}/numa_migrate_state"
  elif [[ -e "${cg}/memory.numa_migrate_state" ]]; then
    file="${cg}/memory.numa_migrate_state"
  fi
  if [[ -n "${file}" ]]; then
    awk -v key="${key}" '$1 == key { print $2; found=1; exit } END { if (!found) print 0 }' "${file}" 2>/dev/null
  else
    printf '0\n'
  fi
}

monitor_cgroup() {
  local cg="$1"
  local outfile="$2"
  local owner_pid="$3"
  local started
  started="$(date +%s)"
  printf 'timestamp,elapsed_s,node_balancing,memory_current,anon_n0,anon_n1,file_n0,file_n1,active_file_n0,active_file_n1,inactive_file_n0,inactive_file_n1,pagetables_n0,pagetables_n1,numa_hint_faults,numa_pages_migrated,pgpromote_success,pgdemote_kswapd,pgdemote_direct,local_pte_updates,local_refault,local_refault_hit,local_lost\n' > "${outfile}"

  while kill -0 "${owner_pid}" 2>/dev/null && [[ ! -d "${cg}" ]]; do
    sleep 0.1
  done

  while kill -0 "${owner_pid}" 2>/dev/null || [[ -d "${cg}" ]]; do
    [[ -d "${cg}" ]] || break
    local ts elapsed nb memcur stat tmp
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    elapsed="$(( $(date +%s) - started ))"
    nb="$(cat "${cg}/node_balancing" 2>/dev/null || cat "${cg}/memory.node_balancing" 2>/dev/null || true)"
    memcur="$(cat "${cg}/memory.current" 2>/dev/null || printf '0')"
    tmp="$(mktemp)"
    cat "${cg}/memory.numa_stat" > "${tmp}" 2>/dev/null || true
    local anon file active_file inactive_file pagetables
    anon="$(grep '^anon ' "${tmp}" || true)"
    file="$(grep '^file ' "${tmp}" || true)"
    active_file="$(grep '^active_file ' "${tmp}" || true)"
    inactive_file="$(grep '^inactive_file ' "${tmp}" || true)"
    pagetables="$(grep '^pagetables ' "${tmp}" || true)"
    local statfile
    statfile="${cg}/memory.stat"
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "${ts}" "${elapsed}" "${nb}" "${memcur}" \
      "$(field_value "${anon}" 0)" "$(field_value "${anon}" 1)" \
      "$(field_value "${file}" 0)" "$(field_value "${file}" 1)" \
      "$(field_value "${active_file}" 0)" "$(field_value "${active_file}" 1)" \
      "$(field_value "${inactive_file}" 0)" "$(field_value "${inactive_file}" 1)" \
      "$(field_value "${pagetables}" 0)" "$(field_value "${pagetables}" 1)" \
      "$(stat_value "${statfile}" numa_hint_faults)" \
      "$(stat_value "${statfile}" numa_pages_migrated)" \
      "$(stat_value "${statfile}" pgpromote_success)" \
      "$(stat_value "${statfile}" pgdemote_kswapd)" \
      "$(stat_value "${statfile}" pgdemote_direct)" \
      "$(migrate_value "${cg}" numa_local_fault_pte_updates)" \
      "$(migrate_value "${cg}" numa_local_fault_refault)" \
      "$(migrate_value "${cg}" numa_local_fault_refault_hit)" \
      "$(migrate_value "${cg}" numa_local_fault_lost)" \
      >> "${outfile}"
    rm -f "${tmp}"
    sleep "${MONITOR_SEC}"
  done
}

run_case() {
  local workload="$1"
  local cap_label="$2"
  local cap_pages="$3"
  local policy="$4"
  local window_sec="${5:-}"
  local case_label="${policy}"
  local cmd=()

  if [[ "${policy}" == "oneshot" || "${policy}" == "toggle" ]]; then
    case_label="${policy}-w${window_sec}"
  fi
  local outdir="${OUTROOT}/${workload}-${cap_label}/${case_label}"
  local cgname="gapbs_audit_${workload}_${cap_label}_${case_label//-/_}_$$"
  local cgpath="/sys/fs/cgroup/${cgname}"
  mkdir -p "${outdir}"

  if [[ -e "${outdir}/status.txt" ]] &&
     grep -qx 'returncode=0' "${outdir}/status.txt"; then
    log "skip workload=${workload} cap=${cap_label} case=${case_label} already complete"
    return 0
  fi

  mapfile -d '' -t cmd < <(workload_cmd "${workload}")
  log "start workload=${workload} cap=${cap_label} case=${case_label}"
  sync || true
  echo 3 > /proc/sys/vm/drop_caches || true

  local common=(
    --outdir "${outdir}"
    --run-id "${workload}-${cap_label}-${case_label}"
    --cgroup-name "${cgname}"
    --capacity-node 0
    --capacity-pages "${cap_pages}"
    --node-balancing 2
    --scan-size-mb 256
    --scan-period-min-ms 1000
    --fast-scan 0
    --hot-threshold-ms 0
    --mglru 0x0007
    --cpuset-cpus 0-31
    --cpuset-mems 0,1
    --omp-threads "${OMP_THREADS}"
    --timeout-sec "${TIMEOUT_SEC}"
  )

  set +e
  case "${policy}" in
    off)
      "${RUNNER}" \
        "${common[@]}" \
        --policy off \
        --kswapd-demotion 0 \
        --global-numa-balancing 0 \
        --global-demotion-enabled 0 \
        --global-demotion-target "0 1" \
        -- \
        "${cmd[@]}" &
      ;;
    on)
      "${RUNNER}" \
        "${common[@]}" \
        --policy on \
        --kswapd-demotion 1 \
        --global-numa-balancing 0 \
        --global-demotion-enabled 1 \
        --global-demotion-target "0 1" \
        -- \
        "${cmd[@]}" &
      ;;
    oneshot)
      "${RUNNER}" \
        "${common[@]}" \
        --policy ours \
        --kswapd-demotion 1 \
        --global-numa-balancing 0 \
        --global-demotion-enabled 1 \
        --global-demotion-target "0 1" \
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
        "${cmd[@]}" &
      ;;
    toggle)
      "${TOGGLE_RUNNER}" \
        "${common[@]}" \
        --policy ours \
        --kswapd-demotion 1 \
        --global-numa-balancing 0 \
        --global-demotion-enabled 1 \
        --global-demotion-target "0 1" \
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
        "${cmd[@]}" &
      ;;
    *)
      log "unknown policy ${policy}"
      exit 2
      ;;
  esac
  local runner_pid=$!
  monitor_cgroup "${cgpath}" "${outdir}/live_numa.csv" "${runner_pid}" &
  local monitor_pid=$!
  wait "${runner_pid}"
  local rc=$?
  wait "${monitor_pid}" 2>/dev/null || true
  set -e

  log "done workload=${workload} cap=${cap_label} case=${case_label} rc=${rc}"
}

for workload in pr bc; do
  for cap_spec in "8g:2097152" "16g:4194304"; do
    cap_label="${cap_spec%%:*}"
    cap_pages="${cap_spec##*:}"
    run_case "${workload}" "${cap_label}" "${cap_pages}" off
    run_case "${workload}" "${cap_label}" "${cap_pages}" on
    for window in 5 10 20; do
      run_case "${workload}" "${cap_label}" "${cap_pages}" oneshot "${window}"
      run_case "${workload}" "${cap_label}" "${cap_pages}" toggle "${window}"
    done
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
    first_reason = ""
    final_state = ""
    if path.exists():
        for row in csv.DictReader(path.open()):
            final_state = row.get("controller_state", final_state)
            if row.get("event") == "off":
                offs.append(row)
                first_reason = first_reason or row.get("stop_reason", "")
            elif row.get("event") == "on":
                ons.append(row)
    return offs, ons, first_reason, final_state

def live_peaks(path):
    peaks = {
        "anon_n0_peak": 0,
        "anon_n1_peak": 0,
        "file_n0_peak": 0,
        "file_n1_peak": 0,
        "memory_current_peak": 0,
        "samples": 0,
    }
    if path.exists():
        for row in csv.DictReader(path.open()):
            peaks["samples"] += 1
            for key in ("anon_n0", "anon_n1", "file_n0", "file_n1", "memory_current"):
                try:
                    peaks[f"{key}_peak"] = max(peaks[f"{key}_peak"], int(row.get(key) or 0))
                except ValueError:
                    pass
    return peaks

rows = []
for cap_dir in sorted(p for p in root.iterdir() if p.is_dir()):
    m = re.match(r"(pr|bc)-(8g|16g)$", cap_dir.name)
    if not m:
        continue
    workload, cap = m.groups()
    for case_dir in sorted(p for p in cap_dir.iterdir() if p.is_dir()):
        name = case_dir.name
        if name in ("off", "on"):
            policy = name
            window = ""
        else:
            m2 = re.match(r"(oneshot|toggle)-w([0-9]+)$", name)
            if not m2:
                continue
            policy, window = m2.groups()
        status = read_kv(case_dir / "status.txt")
        cfg = read_kv(case_dir / "run_config.txt")
        read_s, avg_s, trials = parse_stdout(case_dir / "workload.stdout.log")
        offs, ons, first_reason, final_state = events(case_dir / "controller.csv")
        peaks = live_peaks(case_dir / "live_numa.csv")
        row = {
            "workload": workload,
            "cap": cap,
            "policy": policy,
            "window_sec": window,
            "returncode": status.get("returncode", ""),
            "elapsed_s": status.get("elapsed_s", ""),
            "read_s": read_s,
            "avg_trial_s": avg_s,
            "off_count": len(offs),
            "on_count": len(ons),
            "first_off_ms": offs[0].get("elapsed_ms", "") if offs else "",
            "first_off_window": offs[0].get("window", "") if offs else "",
            "first_off_reason": first_reason,
            "first_on_ms": ons[0].get("elapsed_ms", "") if ons else "",
            "first_on_window": ons[0].get("window", "") if ons else "",
            "final_controller_state": final_state,
            "capacity_pages": cfg.get("capacity_pages", ""),
            "kswapd_demotion_on": cfg.get("kswapd_demotion_on", ""),
            "global_demotion_enabled": cfg.get("global_demotion_enabled", ""),
            "reenable_consecutive": cfg.get("reenable_consecutive", ""),
            "numa_hint_faults": delta(case_dir, "numa_hint_faults"),
            "pgpromote_success": delta(case_dir, "pgpromote_success"),
            "pgdemote_kswapd": delta(case_dir, "pgdemote_kswapd"),
            "pgdemote_direct": delta(case_dir, "pgdemote_direct"),
        }
        row.update(peaks)
        for idx in range(8):
            row[f"trial{idx + 1}_s"] = trials[idx] if idx < len(trials) else ""
        rows.append(row)

fieldnames = [
    "workload", "cap", "policy", "window_sec", "returncode", "elapsed_s",
    "read_s", "avg_trial_s", "off_count", "on_count", "first_off_ms",
    "first_off_window", "first_off_reason", "first_on_ms",
    "first_on_window", "final_controller_state", "capacity_pages",
    "kswapd_demotion_on", "global_demotion_enabled",
    "reenable_consecutive", "numa_hint_faults", "pgpromote_success",
    "pgdemote_kswapd", "pgdemote_direct", "samples",
    "anon_n0_peak", "anon_n1_peak", "file_n0_peak", "file_n1_peak",
    "memory_current_peak",
] + [f"trial{i}_s" for i in range(1, 9)]
with summary.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(rows)
PY

python3 - <<'PY' "${OUTROOT}/window_decisions.csv" "${OUTROOT}/toggle_events.csv" "${OUTROOT}"
import csv
import re
import sys
from pathlib import Path

window_out = Path(sys.argv[1])
toggle_out = Path(sys.argv[2])
root = Path(sys.argv[3])

window_rows = []
toggle_rows = []
for cap_dir in sorted(p for p in root.iterdir() if p.is_dir()):
    m = re.match(r"(pr|bc)-(8g|16g)$", cap_dir.name)
    if not m:
        continue
    workload, cap = m.groups()
    for case_dir in sorted(p for p in cap_dir.iterdir() if p.is_dir()):
        m2 = re.match(r"(oneshot|toggle)-w([0-9]+)$", case_dir.name)
        if not m2:
            continue
        policy, window_sec = m2.groups()
        ctl = case_dir / "controller.csv"
        if not ctl.exists():
            continue
        for row in csv.DictReader(ctl.open()):
            event = row.get("event", "")
            if event not in ("sample", "off", "on"):
                continue
            try:
                pte = int(float(row.get("pte_delta") or 0))
                hint = int(float(row.get("hint_fault_delta") or 0))
                access = float(row.get("access_pct") or 0)
                remote = float(row.get("remote_ratio_pct") or 0)
                min_pte = int(float(row.get("min_pte_updates") or 0))
                min_hint = int(float(row.get("min_hint_faults") or 0))
                threshold = float(row.get("threshold_pct") or 0)
                remote_threshold = float(row.get("remote_threshold_pct") or 0)
            except ValueError:
                continue
            local_pass = pte >= min_pte and access >= threshold
            remote_pass = hint >= min_hint and remote <= remote_threshold
            out = {
                "workload": workload,
                "cap": cap,
                "policy": policy,
                "window_sec": window_sec,
                "event": event,
                "elapsed_ms": row.get("elapsed_ms", ""),
                "window": row.get("window", ""),
                "window_seq": row.get("window_seq", ""),
                "controller_state": row.get("controller_state", ""),
                "node_balancing": row.get("node_balancing", ""),
                "pte_delta": row.get("pte_delta", ""),
                "refault_delta": row.get("refault_delta", ""),
                "hint_fault_delta": row.get("hint_fault_delta", ""),
                "access_pct": row.get("access_pct", ""),
                "remote_ratio_pct": row.get("remote_ratio_pct", ""),
                "local_consecutive": row.get("local_consecutive", ""),
                "remote_consecutive": row.get("remote_consecutive", ""),
                "reenable_consecutive": row.get("reenable_consecutive", ""),
                "local_pass": int(local_pass),
                "remote_pass": int(remote_pass),
                "stop_reason": row.get("stop_reason", ""),
            }
            window_rows.append(out)
            if policy == "toggle" and event in ("off", "on"):
                toggle_rows.append(out)

fields = [
    "workload", "cap", "policy", "window_sec", "event", "elapsed_ms",
    "window", "window_seq", "controller_state", "node_balancing",
    "pte_delta", "refault_delta", "hint_fault_delta", "access_pct",
    "remote_ratio_pct", "local_consecutive", "remote_consecutive",
    "reenable_consecutive", "local_pass", "remote_pass", "stop_reason",
]
with window_out.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fields)
    writer.writeheader()
    writer.writerows(window_rows)
with toggle_out.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fields)
    writer.writeheader()
    writer.writerows(toggle_rows)
PY

log "summary=${OUTROOT}/summary.csv"
log "window_decisions=${OUTROOT}/window_decisions.csv"
log "toggle_events=${OUTROOT}/toggle_events.csv"
