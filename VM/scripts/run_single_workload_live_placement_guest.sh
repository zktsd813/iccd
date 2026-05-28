#!/usr/bin/env bash
set -euo pipefail

OUTROOT="${OUTROOT:-/root/single-live-placement}"
BENCHMARK_DIR="${BENCHMARK_DIR:-/root/benchmark}"
GRAPH="${GRAPH:-/root/gapbs_graphs/kron_g28.sg}"
WORKLOADS="${WORKLOADS:-pr bc FT LU SP gups graph500 btree xsbench silo}"
CAPS="${CAPS:-8g:2097152 16g:4194304}"
TRIALS="${TRIALS:-8}"
OMP_THREADS="${OMP_THREADS:-32}"
TIMEOUT_SEC="${TIMEOUT_SEC:-1800}"
SAMPLE_SEC="${SAMPLE_SEC:-1}"

mkdir -p "${OUTROOT}"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "${OUTROOT}/orchestrator.log"
}

write_optional() {
  local path="$1"
  local value="$2"
  [[ -e "${path}" ]] || return 0
  printf '%s\n' "${value}" > "${path}" || true
}

pick_knob() {
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

write_knob() {
  local cg="$1"
  local knob="$2"
  local value="$3"
  local file
  file="$(pick_knob "${cg}" "${knob}")"
  printf '%s\n' "${value}" > "${file}"
}

write_knob_optional() {
  local cg="$1"
  local knob="$2"
  local value="$3"
  local file
  file="$(pick_knob "${cg}" "${knob}" 2>/dev/null)" || return 0
  printf '%s\n' "${value}" > "${file}" || true
}

numa_value() {
  local stat="$1"
  local key="$2"
  local node="$3"
  awk -v key="${key}" -v node="${node}" '
    $1 == key {
      for (i = 2; i <= NF; i++) {
        split($i, a, "=");
        if (a[1] == node) {
          print a[2];
          found = 1;
          exit;
        }
      }
    }
    END { if (!found) print 0; }
  ' "${stat}"
}

sample_one_numa_maps() {
  local pid="$1"
  local out="$2"
  if [[ ! -r "/proc/${pid}/numa_maps" ]]; then
    printf '0,0,0,0,0,0,0,0,0,0,0\n' > "${out}"
    return 0
  fi
  awk '
    {
      n0 = 0; n1 = 0; anon = 0;
      for (i = 1; i <= NF; i++) {
        split($i, a, "=");
        if (a[1] == "N0") n0 = a[2];
        else if (a[1] == "N1") n1 = a[2];
        else if (a[1] == "anon") anon = a[2];
      }
      total_n0 += n0;
      total_n1 += n1;
      if (anon > 0) {
        anon_n0 += n0;
        anon_n1 += n1;
      } else {
        file_n0 += n0;
        file_n1 += n1;
      }
      if ($0 ~ /heap/) {
        heap_n0 += n0;
        heap_n1 += n1;
      }
      if ($0 ~ /stack/) {
        stack_n0 += n0;
        stack_n1 += n1;
      }
    }
    END {
      printf "%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n",
        total_n0, total_n1, anon_n0, anon_n1, file_n0, file_n1,
        heap_n0, heap_n1, stack_n0, stack_n1, NR;
    }
  ' "/proc/${pid}/numa_maps" > "${out}"
}

sample_cgroup_numa_maps() {
  local cg="$1"
  local out="$2"
  local tmp="${out}.one"
  local total_n0=0 total_n1=0 anon_n0=0 anon_n1=0 file_n0=0 file_n1=0
  local heap_n0=0 heap_n1=0 stack_n0=0 stack_n1=0 map_lines=0
  local pid

  while read -r pid; do
    [[ -n "${pid}" ]] || continue
    sample_one_numa_maps "${pid}" "${tmp}"
    IFS=, read -r pt0 pt1 pa0 pa1 pf0 pf1 ph0 ph1 ps0 ps1 pml < "${tmp}"
    total_n0=$((total_n0 + pt0))
    total_n1=$((total_n1 + pt1))
    anon_n0=$((anon_n0 + pa0))
    anon_n1=$((anon_n1 + pa1))
    file_n0=$((file_n0 + pf0))
    file_n1=$((file_n1 + pf1))
    heap_n0=$((heap_n0 + ph0))
    heap_n1=$((heap_n1 + ph1))
    stack_n0=$((stack_n0 + ps0))
    stack_n1=$((stack_n1 + ps1))
    map_lines=$((map_lines + pml))
  done < "${cg}/cgroup.procs"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${total_n0}" "${total_n1}" "${anon_n0}" "${anon_n1}" \
    "${file_n0}" "${file_n1}" "${heap_n0}" "${heap_n1}" \
    "${stack_n0}" "${stack_n1}" "${map_lines}" > "${out}"
  rm -f "${tmp}"
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
      CMD=("${bin}")
      ;;
    graph500)
      local bin
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_graph500_mt")" || return 1
      CMD=("${bin}" -s 28)
      ;;
    btree)
      local bin
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_btree_mt")" || return 1
      CMD=("${bin}")
      ;;
    xsbench)
      local bin
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/XSBench/openmp-threading/XSBench")" || return 1
      CMD=("${bin}" -t "${OMP_THREADS}" -g 130000 -p 30000000)
      ;;
    silo)
      local bin
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/silo/out-perf.masstree/benchmarks/dbtest")" || return 1
      CMD=("${bin}" --verbose --num-threads "${OMP_THREADS}" --bench ycsb --scale-factor 550000 --ops-per-worker=200000000)
      ;;
    *)
      return 1
      ;;
  esac

  printf -v CMD_DISPLAY '%q ' "${CMD[@]}"
}

run_case() {
  local workload="$1"
  local cap_label="$2"
  local cap_pages="$3"
  local outdir="${OUTROOT}/${workload}-${cap_label}-off-live"
  local cg="/sys/fs/cgroup/single_live_${workload}_${cap_label}_$$"
  local samples="${outdir}/samples.csv"
  local maps_tmp="${outdir}/numa_maps.tmp"
  local stat_tmp="${outdir}/numa_stat.tmp"
  local stdout_log="${outdir}/workload.stdout.log"
  local stderr_log="${outdir}/workload.stderr.log"
  local status_file="${outdir}/status.txt"

  rm -rf "${outdir}"
  mkdir -p "${outdir}"

  if ! set_workload_cmd "${workload}"; then
    log "skip workload=${workload} cap=${cap_label}: missing binary/input"
    {
      echo "returncode=skip"
      echo "reason=missing binary/input"
      echo "workload=${workload}"
      echo "cap=${cap_label}"
    } > "${status_file}"
    return 0
  fi

  mkdir -p "${cg}"
  if [[ -e "${cg}/cpuset.cpus" ]]; then echo 0-31 > "${cg}/cpuset.cpus"; fi
  if [[ -e "${cg}/cpuset.mems" ]]; then echo 0,1 > "${cg}/cpuset.mems"; fi

  echo 0 > /proc/sys/kernel/numa_balancing
  write_optional /sys/kernel/mm/numa/demotion_enabled 0
  write_optional /sys/kernel/mm/numa/demotion_target "0 1"
  write_optional /sys/kernel/debug/sched/numa_balancing/scan_size_mb 256
  write_optional /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms 1000
  write_knob "${cg}" node_capacity "0 ${cap_pages}"
  write_knob "${cg}" node_balancing 0
  write_knob "${cg}" kswapd_demotion_enabled 0
  write_knob_optional "${cg}" numa_local_fault_on_tiering 0
  write_knob_optional "${cg}" numa_migration_stop_enabled 0
  write_knob_optional "${cg}" numa_pingpong_stat_enabled 0

  {
    echo "run_id=${workload}-${cap_label}-off-live"
    echo "uname=$(uname -a)"
    echo "lru_gen_enabled=$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || true)"
    echo "cgroup=${cg}"
    echo "workload=${workload}"
    echo "capacity_pages=${cap_pages}"
    echo "capacity_gib=$(awk -v p="${cap_pages}" 'BEGIN { printf "%.2f", p * 4096 / 1024 / 1024 / 1024 }')"
    echo "command=${CMD_DISPLAY}"
    echo "sample_sec=${SAMPLE_SEC}"
    echo "omp_threads=${OMP_THREADS}"
    echo "timeout_sec=${TIMEOUT_SEC}"
  } > "${outdir}/run_config.txt"

  sync || true
  echo 3 > /proc/sys/vm/drop_caches || true
  cat /proc/vmstat > "${outdir}/vmstat.before" || true

  printf 'elapsed_ms,phase,pid_alive,mem_current,anon_n0,anon_n1,file_n0,file_n1,file_thp_n0,file_thp_n1,inactive_file_n0,inactive_file_n1,active_file_n0,active_file_n1,proc_total_n0_pages,proc_total_n1_pages,proc_anon_n0_pages,proc_anon_n1_pages,proc_file_n0_pages,proc_file_n1_pages,proc_heap_n0_pages,proc_heap_n1_pages,proc_stack_n0_pages,proc_stack_n1_pages,proc_map_lines\n' > "${samples}"

  local start_ns
  start_ns="$(date +%s%N)"

  log "start workload=${workload} cap=${cap_label} capacity_pages=${cap_pages}"
  set +e
  timeout "${TIMEOUT_SEC}" bash -c \
    'echo $$ > "$1/cgroup.procs"; shift; exec "$@"' \
    _ "${cg}" env OMP_NUM_THREADS="${OMP_THREADS}" OMP_PROC_BIND=true OMP_PLACES=cores \
    "${CMD[@]}" \
    > "${stdout_log}" 2> "${stderr_log}" &
  local pid="$!"

  local rc=0
  while kill -0 "${pid}" 2>/dev/null; do
    local now_ns elapsed_ms phase mem_current
    now_ns="$(date +%s%N)"
    elapsed_ms=$(( (now_ns - start_ns) / 1000000 ))
    phase="run"
    if grep -q "Trial Time:" "${stdout_log}" 2>/dev/null; then
      phase="trial"
    elif grep -q "Graph has" "${stdout_log}" 2>/dev/null; then
      phase="loaded"
    elif grep -q "Read Time:" "${stdout_log}" 2>/dev/null; then
      phase="read-done"
    fi
    mem_current="$(cat "${cg}/memory.current" 2>/dev/null || echo 0)"
    cat "${cg}/memory.numa_stat" > "${stat_tmp}" 2>/dev/null || true
    sample_cgroup_numa_maps "${cg}" "${maps_tmp}"
    IFS=, read -r pt0 pt1 pa0 pa1 pf0 pf1 ph0 ph1 ps0 ps1 pml < "${maps_tmp}"
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "${elapsed_ms}" "${phase}" 1 "${mem_current}" \
      "$(numa_value "${stat_tmp}" anon N0)" "$(numa_value "${stat_tmp}" anon N1)" \
      "$(numa_value "${stat_tmp}" file N0)" "$(numa_value "${stat_tmp}" file N1)" \
      "$(numa_value "${stat_tmp}" file_thp N0)" "$(numa_value "${stat_tmp}" file_thp N1)" \
      "$(numa_value "${stat_tmp}" inactive_file N0)" "$(numa_value "${stat_tmp}" inactive_file N1)" \
      "$(numa_value "${stat_tmp}" active_file N0)" "$(numa_value "${stat_tmp}" active_file N1)" \
      "${pt0}" "${pt1}" "${pa0}" "${pa1}" "${pf0}" "${pf1}" "${ph0}" "${ph1}" "${ps0}" "${ps1}" "${pml}" \
      >> "${samples}"
    sleep "${SAMPLE_SEC}"
  done
  wait "${pid}"
  rc="$?"
  set -e

  local end_ns elapsed_s
  end_ns="$(date +%s%N)"
  elapsed_s=$(( (end_ns - start_ns) / 1000000000 ))
  cat /proc/vmstat > "${outdir}/vmstat.after" || true
  cat "${cg}/memory.numa_stat" > "${outdir}/cgroup.numa_stat.after" || true
  cat "${cg}/memory.current" > "${outdir}/memory.current.after" || true
  {
    echo "returncode=${rc}"
    echo "elapsed_s=${elapsed_s}"
    echo "pid=${pid}"
    echo "samples=${samples}"
    echo "stdout=${stdout_log}"
    echo "stderr=${stderr_log}"
  } > "${status_file}"
  rmdir "${cg}" 2>/dev/null || true
  log "done workload=${workload} cap=${cap_label} rc=${rc} elapsed_s=${elapsed_s}"
}

summarize_results() {
  python3 - <<'PY' "${OUTROOT}"
import csv
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
out = root / "summary.csv"
page = 4096

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
            m = re.search(r"execution time\s+([0-9.]+)", line)
            if m and not avg_s:
                avg_s = m.group(1)
    return read_s, avg_s, trials

def sample_stats(path):
    if not path.exists():
        return {}
    rows = list(csv.DictReader(path.open()))
    if not rows:
        return {}
    def iv(row, field):
        return int(row[field])
    peak_cg_n0 = max(rows, key=lambda r: iv(r, "anon_n0") + iv(r, "file_n0"))
    peak_proc_n0 = max(rows, key=lambda r: iv(r, "proc_anon_n0_pages") + iv(r, "proc_file_n0_pages"))
    return {
        "sample_count": len(rows),
        "max_mem_current": max(iv(r, "mem_current") for r in rows),
        "cg_node0_row_peak": iv(peak_cg_n0, "anon_n0") + iv(peak_cg_n0, "file_n0"),
        "cg_node1_at_node0_peak": iv(peak_cg_n0, "anon_n1") + iv(peak_cg_n0, "file_n1"),
        "cg_anon_n0_at_node0_peak": iv(peak_cg_n0, "anon_n0"),
        "cg_file_n0_at_node0_peak": iv(peak_cg_n0, "file_n0"),
        "proc_node0_row_peak_pages": iv(peak_proc_n0, "proc_anon_n0_pages") + iv(peak_proc_n0, "proc_file_n0_pages"),
        "proc_node1_at_proc_peak_pages": iv(peak_proc_n0, "proc_anon_n1_pages") + iv(peak_proc_n0, "proc_file_n1_pages"),
        "proc_anon_n0_peak_pages": max(iv(r, "proc_anon_n0_pages") for r in rows),
        "proc_anon_n1_peak_pages": max(iv(r, "proc_anon_n1_pages") for r in rows),
    }

fields = [
    "workload", "cap", "capacity_pages", "capacity_gib", "returncode",
    "elapsed_s", "read_s", "avg_trial_or_elapsed_s", "sample_count",
    "max_mem_current", "cg_node0_row_peak", "cg_node1_at_node0_peak",
    "cg_anon_n0_at_node0_peak", "cg_file_n0_at_node0_peak",
    "proc_node0_row_peak_pages", "proc_node1_at_proc_peak_pages",
    "proc_anon_n0_peak_pages", "proc_anon_n1_peak_pages",
] + [f"trial{i}_s" for i in range(1, 21)]

rows = []
for case_dir in sorted(root.glob("*-*-off-live")):
    m = re.fullmatch(r"(.+)-(8g|16g)-off-live", case_dir.name)
    if not m:
        continue
    workload, cap = m.groups()
    cfg = read_kv(case_dir / "run_config.txt")
    status = read_kv(case_dir / "status.txt")
    read_s, avg_s, trials = parse_stdout(case_dir / "workload.stdout.log")
    if not avg_s:
        avg_s = status.get("elapsed_s", "")
    row = {
        "workload": workload,
        "cap": cap,
        "capacity_pages": cfg.get("capacity_pages", ""),
        "capacity_gib": cfg.get("capacity_gib", ""),
        "returncode": status.get("returncode", ""),
        "elapsed_s": status.get("elapsed_s", ""),
        "read_s": read_s,
        "avg_trial_or_elapsed_s": avg_s,
        **sample_stats(case_dir / "samples.csv"),
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

{
  echo "uname=$(uname -a)"
  echo "lru_gen_enabled=$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || true)"
  echo "benchmark_dir=${BENCHMARK_DIR}"
  echo "graph=${GRAPH}"
  echo "workloads=${WORKLOADS}"
  echo "caps=${CAPS}"
  echo "trials=${TRIALS}"
  echo "omp_threads=${OMP_THREADS}"
  echo "timeout_sec=${TIMEOUT_SEC}"
  echo "sample_sec=${SAMPLE_SEC}"
} > "${OUTROOT}/experiment_config.txt"

if [[ -e /sys/kernel/mm/lru_gen/enabled ]]; then
  echo 0x0007 > /sys/kernel/mm/lru_gen/enabled || true
fi
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true

for workload in ${WORKLOADS}; do
  for cap in ${CAPS}; do
    IFS=: read -r cap_label cap_pages <<< "${cap}"
    run_case "${workload}" "${cap_label}" "${cap_pages}"
  done
done

summarize_results
log "summary=${OUTROOT}/summary.csv"
