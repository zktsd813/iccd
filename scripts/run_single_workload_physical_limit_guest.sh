#!/usr/bin/env bash
set -euo pipefail

OUTROOT="${OUTROOT:-/root/single-physical-limit}"
BENCHMARK_DIR="${BENCHMARK_DIR:-/root/benchmark}"
GRAPH="${GRAPH:-/root/gapbs_graphs/kron_g28.sg}"
WORKLOADS="${WORKLOADS:-pr bc silo liblinear FT LU SP gups graph500 btree xsbench}"
POLICIES="${POLICIES:-off on}"
OMP_THREADS="${OMP_THREADS:-32}"
TRIALS="${TRIALS:-8}"
TIMEOUT_SEC="${TIMEOUT_SEC:-3600}"
GUPS_MEMORY_GB="${GUPS_MEMORY_GB:-64}"
GRAPH500_SCALE="${GRAPH500_SCALE:-28}"
XSBENCH_GRID="${XSBENCH_GRID:-130000}"
XSBENCH_PARTICLES="${XSBENCH_PARTICLES:-30000000}"
SILO_SCALE_FACTOR="${SILO_SCALE_FACTOR:-550000}"
SILO_OPS_PER_WORKER="${SILO_OPS_PER_WORKER:-200000000}"
CGROUP_ROOT="${CGROUP_ROOT:-/sys/fs/cgroup}"

mkdir -p "${OUTROOT}"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "${OUTROOT}/orchestrator.log"
}

resolve_existing_file() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    printf '%s\n' "${path}"
    return 0
  fi
  return 1
}

set_workload_cmd() {
  local workload="$1"
  CMD=()
  CMD_DISPLAY=""

  case "${workload}" in
    pr)
      local bin
      bin="$(resolve_existing_file /root/pr || resolve_existing_file "${BENCHMARK_DIR}/gapbs/pr")" || return 1
      [[ -f "${GRAPH}" ]] || return 1
      CMD=("${bin}" -f "${GRAPH}" -i20 -t1e-4 -n "${TRIALS}")
      ;;
    bc)
      local bin
      bin="$(resolve_existing_file /root/bc || resolve_existing_file "${BENCHMARK_DIR}/gapbs/bc")" || return 1
      [[ -f "${GRAPH}" ]] || return 1
      CMD=("${bin}" -f "${GRAPH}" -i1 -n "${TRIALS}")
      ;;
    silo)
      local bin
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/silo/out-perf.masstree/benchmarks/dbtest")" || return 1
      CMD=("${bin}" --verbose --num-threads "${OMP_THREADS}" --bench ycsb --scale-factor "${SILO_SCALE_FACTOR}" --ops-per-worker="${SILO_OPS_PER_WORKER}")
      ;;
    liblinear)
      local bin data
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/liblinear-multicore-2.47/train")" || return 1
      data="$(resolve_existing_file "${BENCHMARK_DIR}/liblinear-multicore-2.47/datasets/kdd12")" || return 1
      CMD=("${bin}" -s 6 -m "${OMP_THREADS}" "${data}")
      ;;
    FT|ft)
      local bin
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/NPB3.4.3/NPB3.4-OMP/bin/ft.H.x")" || return 1
      CMD=("${bin}")
      ;;
    LU|lu)
      local bin
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/NPB3.4.3/NPB3.4-OMP/bin/lu.H.x")" || return 1
      CMD=("${bin}")
      ;;
    SP|sp)
      local bin
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/NPB3.4.3/NPB3.4-OMP/bin/sp.H.x")" || return 1
      CMD=("${bin}")
      ;;
    gups)
      local bin
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_gups_mt")" || return 1
      CMD=("${bin}" "${GUPS_MEMORY_GB}")
      ;;
    graph500)
      local bin
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_graph500_mt")" || return 1
      CMD=("${bin}" -s "${GRAPH500_SCALE}")
      ;;
    btree)
      local bin
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_btree_mt")" || return 1
      CMD=("${bin}")
      ;;
    xsbench)
      local bin
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/XSBench/openmp-threading/XSBench")" || return 1
      CMD=("${bin}" -t "${OMP_THREADS}" -g "${XSBENCH_GRID}" -p "${XSBENCH_PARTICLES}")
      ;;
    *)
      return 1
      ;;
  esac

  printf -v CMD_DISPLAY '%q ' "${CMD[@]}"
}

drop_caches() {
  sync || true
  echo 3 > /proc/sys/vm/drop_caches || true
}

set_common_kernel_state() {
  if [[ -e /sys/kernel/mm/lru_gen/enabled ]]; then
    echo 0x0007 > /sys/kernel/mm/lru_gen/enabled || true
  fi
  mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
  [[ -e /sys/kernel/debug/sched/numa_balancing/scan_size_mb ]] && echo 256 > /sys/kernel/debug/sched/numa_balancing/scan_size_mb || true
  [[ -e /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms ]] && echo 1000 > /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms || true
  [[ -e /sys/kernel/debug/sched/numa_balancing/fast_scan ]] && echo 0 > /sys/kernel/debug/sched/numa_balancing/fast_scan || true
  [[ -e /sys/kernel/mm/numa/demotion_target ]] && echo "0 1" > /sys/kernel/mm/numa/demotion_target || true
}

set_policy_state() {
  local policy="$1"
  set_common_kernel_state
  case "${policy}" in
    off)
      echo 0 > /proc/sys/kernel/numa_balancing || true
      [[ -e /sys/kernel/mm/numa/demotion_enabled ]] && echo 0 > /sys/kernel/mm/numa/demotion_enabled || true
      ;;
    on)
      [[ -e /sys/kernel/mm/numa/demotion_enabled ]] && echo 1 > /sys/kernel/mm/numa/demotion_enabled || true
      [[ -e /sys/kernel/mm/numa/demotion_target ]] && echo "0 1" > /sys/kernel/mm/numa/demotion_target || true
      echo 2 > /proc/sys/kernel/numa_balancing || true
      ;;
    *)
      log "unknown policy=${policy}"
      return 1
      ;;
  esac
}

pick_knob_file() {
  local cg="$1"
  local knob="$2"
  if [[ -e "${cg}/${knob}" ]]; then
    printf '%s\n' "${cg}/${knob}"
  elif [[ -e "${cg}/memory.${knob}" ]]; then
    printf '%s\n' "${cg}/memory.${knob}"
  else
    return 1
  fi
}

write_cgroup_knob_required() {
  local cg="$1"
  local knob="$2"
  local value="$3"
  local file
  file="$(pick_knob_file "${cg}" "${knob}")" || {
    log "missing required cgroup knob: ${cg}/${knob}"
    return 1
  }
  printf '%s\n' "${value}" > "${file}"
}

write_cgroup_file_optional() {
  local file="$1"
  local value="$2"
  [[ -e "${file}" ]] || return 0
  printf '%s\n' "${value}" > "${file}" || true
}

snapshot_cgroup() {
  local cg="$1"
  local out="$2"
  {
    echo "cgroup=${cg}"
    echo "self_cgroup=$(cat /proc/self/cgroup 2>/dev/null || true)"
    for name in \
      node_balancing \
      node_capacity \
      kswapd_demotion_enabled \
      numa_local_fault_on_tiering \
      memory.current \
      memory.numa_stat; do
      if [[ -e "${cg}/${name}" ]]; then
        printf '### %s\n' "${name}"
        cat "${cg}/${name}" || true
      elif [[ -e "${cg}/memory.${name}" ]]; then
        printf '### memory.%s\n' "${name}"
        cat "${cg}/memory.${name}" || true
      fi
    done
  } > "${out}" 2>&1 || true
}

prepare_workload_cgroup() {
  local workload="$1"
  local policy="$2"
  local cg="${CGROUP_ROOT%/}/physlimit_${workload}_${policy}_$$"
  local mode=0

  mkdir -p "${cg}"
  write_cgroup_file_optional "${cg}/cpuset.cpus" "0-31"
  write_cgroup_file_optional "${cg}/cpuset.mems" "0,1"
  case "${policy}" in
    on) mode=2 ;;
    off) mode=0 ;;
  esac
  write_cgroup_knob_required "${cg}" node_balancing "${mode}"
  printf '%s\n' "${cg}"
}

vmstat_delta_summary() {
  python3 - <<'PY' "$1"
from pathlib import Path
import sys

case = Path(sys.argv[1])
def read(path):
    out = {}
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            parts = line.split()
            if len(parts) == 2:
                try:
                    out[parts[0]] = int(parts[1])
                except ValueError:
                    pass
    return out
before = read(case / "vmstat.before")
after = read(case / "vmstat.after")
keys = sorted(set(before) | set(after))
with (case / "vmstat.delta").open("w") as f:
    for k in keys:
        d = after.get(k, 0) - before.get(k, 0)
        if d:
            f.write(f"{k} {d}\n")
PY
}

run_policy() {
  local workload="$1"
  local policy="$2"
  local outdir="${OUTROOT}/${workload}/${policy}"
  local cg=""
  mkdir -p "${outdir}"
  set_policy_state "${policy}"
  cg="$(prepare_workload_cgroup "${workload}" "${policy}")"
  drop_caches
  cat /proc/vmstat > "${outdir}/vmstat.before" || true
  snapshot_cgroup "${cg}" "${outdir}/cgroup.before"
  {
    echo "workload=${workload}"
    echo "policy=${policy}"
    echo "placement=physical-node0-limit-default-firsttouch"
    echo "workload_cgroup=${cg}"
    echo "command=${CMD_DISPLAY}"
    echo "omp_threads=${OMP_THREADS}"
    echo "timeout_sec=${TIMEOUT_SEC}"
    echo "numa_balancing=$(cat /proc/sys/kernel/numa_balancing 2>/dev/null || true)"
    echo "demotion_enabled=$(cat /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true)"
    echo "demotion_target=$(cat /sys/kernel/mm/numa/demotion_target 2>/dev/null || true)"
    echo "scan_size_mb=$(cat /sys/kernel/debug/sched/numa_balancing/scan_size_mb 2>/dev/null || true)"
    echo "scan_period_min_ms=$(cat /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms 2>/dev/null || true)"
    echo "cgroup_node_balancing=$(cat "$(pick_knob_file "${cg}" node_balancing)" 2>/dev/null || true)"
    echo "cgroup_kswapd_demotion_enabled=$(cat "$(pick_knob_file "${cg}" kswapd_demotion_enabled)" 2>/dev/null || true)"
    echo "runner_self_cgroup=$(cat /proc/self/cgroup 2>/dev/null || true)"
    echo "uname=$(uname -a)"
    echo "lru_gen_enabled=$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || true)"
    numactl -H
    free -h
  } > "${outdir}/run_config.txt" 2>&1 || true

  log "start workload=${workload} policy=${policy}"
  set +e
  /usr/bin/time -f "execution time %e (s)" timeout "${TIMEOUT_SEC}" \
    bash -c 'echo $$ > "$1/cgroup.procs"; shift; exec "$@"' \
    _ "${cg}" \
    env OMP_NUM_THREADS="${OMP_THREADS}" OMP_PROC_BIND=true OMP_PLACES=cores \
    numactl --physcpubind=0-31 "${CMD[@]}" \
    > "${outdir}/workload.stdout.log" 2> "${outdir}/workload.stderr.log"
  local rc=$?
  set -e
  cat /proc/vmstat > "${outdir}/vmstat.after" || true
  snapshot_cgroup "${cg}" "${outdir}/cgroup.after"
  vmstat_delta_summary "${outdir}" || true
  rmdir "${cg}" 2>/dev/null || true
  {
    echo "returncode=${rc}"
    echo "policy=${policy}"
  } > "${outdir}/status.txt"
  log "done workload=${workload} policy=${policy} rc=${rc}"
}

summarize_results() {
  python3 - <<'PY' "${OUTROOT}"
import csv
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
out = root / "summary.csv"

def read_kv(path):
    data = {}
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                data[k] = v
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
            m = re.search(r"Time in seconds\s*=\s*([0-9.]+)", line)
            if m:
                avg_s = m.group(1)
    return read_s, avg_s, trials

def parse_stderr_time(path):
    if not path.exists():
        return ""
    text = path.read_text(errors="replace")
    matches = re.findall(r"execution time\s+([0-9.]+)", text)
    return matches[-1] if matches else ""

def vmstat_delta(case_dir, key):
    path = case_dir / "vmstat.delta"
    if not path.exists():
        return 0
    for line in path.read_text(errors="replace").splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] == key:
            try:
                return int(parts[1])
            except ValueError:
                return 0
    return 0

fields = [
    "workload", "policy", "returncode", "elapsed_s", "read_s",
    "avg_trial_s", "trial_count", "numa_hint_faults",
    "pgpromote_success", "pgdemote_kswapd", "pgdemote_direct",
] + [f"trial{i}_s" for i in range(1, 21)]

rows = []
for case_dir in sorted(p for p in root.glob("*/*") if p.is_dir()):
    workload = case_dir.parent.name
    policy = case_dir.name
    status = read_kv(case_dir / "status.txt")
    read_s, avg_s, trials = parse_stdout(case_dir / "workload.stdout.log")
    elapsed = parse_stderr_time(case_dir / "workload.stderr.log")
    if not avg_s:
        avg_s = elapsed
    row = {
        "workload": workload,
        "policy": policy,
        "returncode": status.get("returncode", ""),
        "elapsed_s": elapsed,
        "read_s": read_s,
        "avg_trial_s": avg_s,
        "trial_count": len(trials),
        "numa_hint_faults": vmstat_delta(case_dir, "numa_hint_faults"),
        "pgpromote_success": vmstat_delta(case_dir, "pgpromote_success"),
        "pgdemote_kswapd": vmstat_delta(case_dir, "pgdemote_kswapd"),
        "pgdemote_direct": vmstat_delta(case_dir, "pgdemote_direct"),
    }
    for i, value in enumerate(trials, 1):
        if i > 20:
            break
        row[f"trial{i}_s"] = value
    rows.append(row)

with out.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fields)
    writer.writeheader()
    writer.writerows(rows)
print(out)
PY
}

set_common_kernel_state
{
  echo "uname=$(uname -a)"
  echo "lru_gen_enabled=$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || true)"
  echo "workloads=${WORKLOADS}"
  echo "policies=${POLICIES}"
  echo "omp_threads=${OMP_THREADS}"
  echo "trials=${TRIALS}"
  echo "timeout_sec=${TIMEOUT_SEC}"
  echo "gups_memory_gb=${GUPS_MEMORY_GB}"
  echo "graph500_scale=${GRAPH500_SCALE}"
  echo "xsbench_grid=${XSBENCH_GRID}"
  echo "xsbench_particles=${XSBENCH_PARTICLES}"
  echo "silo_scale_factor=${SILO_SCALE_FACTOR}"
  echo "silo_ops_per_worker=${SILO_OPS_PER_WORKER}"
  numactl -H
} > "${OUTROOT}/experiment_config.txt" 2>&1

for workload in ${WORKLOADS}; do
  if ! set_workload_cmd "${workload}"; then
    log "skip workload=${workload}: missing binary/input"
    continue
  fi
  for policy in ${POLICIES}; do
    run_policy "${workload}" "${policy}"
    summarize_results
  done
done

summarize_results
log "summary=${OUTROOT}/summary.csv"
