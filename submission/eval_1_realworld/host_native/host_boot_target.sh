#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"
REPO_ROOT="${REPO_ROOT:-/Serverless/iccd-git}"

STATE_ROOT="${STATE_ROOT:-/var/lib/iccd/eval1-host-native}"
LOG_ROOT="${LOG_ROOT:-/var/log/iccd/eval1-host-native}"
GRUB_DROPIN="${GRUB_DROPIN:-/etc/default/grub.d/99-iccd-eval1-host-native.cfg}"
STATE_FILE="${STATE_FILE:-${STATE_ROOT}/state.env}"
LOCK_FILE="${LOCK_FILE:-${STATE_ROOT}/host_boot_target.lock}"

LOCAL_NODE="${LOCAL_NODE:-0}"
KEEP_MEMORY_NODES="${KEEP_MEMORY_NODES:-2}"
OFFLINE_CPU_NODE="${OFFLINE_CPU_NODE:-1}"
TARGET_TOLERANCE_GIB="${TARGET_TOLERANCE_GIB:-1}"
NODE0_BOOT_OVERHEAD_GIB="${NODE0_BOOT_OVERHEAD_GIB:-8}"
MAX_REBOOTS="${MAX_REBOOTS:-4}"
DROP_CACHES_BEFORE_VERIFY="${DROP_CACHES_BEFORE_VERIFY:-1}"
MIN_KEEP_NODE_TOTAL_GIB="${MIN_KEEP_NODE_TOTAL_GIB:-128}"
ONLINE_KEEP_MEMORY_NODES_AFTER_BOOT="${ONLINE_KEEP_MEMORY_NODES_AFTER_BOOT:-1}"
CXL_ONLINE_RETRIES="${CXL_ONLINE_RETRIES:-60}"
CXL_ONLINE_RETRY_INTERVAL_SEC="${CXL_ONLINE_RETRY_INTERVAL_SEC:-2}"
VERIFY_DELAY_AFTER_REBOOT_SEC="${VERIFY_DELAY_AFTER_REBOOT_SEC:-30}"
VERIFY_WARMUP_PR_AFTER_REBOOT="${VERIFY_WARMUP_PR_AFTER_REBOOT:-1}"
VERIFY_WARMUP_PR_BIN="${VERIFY_WARMUP_PR_BIN:-/Serverless/benchmark/gapbs/pr}"
VERIFY_WARMUP_PR_GRAPH="${VERIFY_WARMUP_PR_GRAPH:-/Serverless/benchmark/gapbs/benchmark/graphs/kron_g29.sg}"
VERIFY_WARMUP_PR_SCALE="${VERIFY_WARMUP_PR_SCALE:-29}"
VERIFY_WARMUP_PR_ITERATIONS="${VERIFY_WARMUP_PR_ITERATIONS:-20}"
VERIFY_WARMUP_PR_TOLERANCE="${VERIFY_WARMUP_PR_TOLERANCE:-1e-4}"
VERIFY_WARMUP_PR_TRIALS="${VERIFY_WARMUP_PR_TRIALS:-1}"
VERIFY_WARMUP_PR_THREADS="${VERIFY_WARMUP_PR_THREADS:-32}"
VERIFY_WARMUP_CPU_NODE="${VERIFY_WARMUP_CPU_NODE:-0}"
ICCD_FROM_REBOOT_HOOK="${ICCD_FROM_REBOOT_HOOK:-0}"
CPU_BOOT_MODE="${CPU_BOOT_MODE:-maxcpus}"
ENABLE_NOSMT="${ENABLE_NOSMT:-1}"
MEMHP_DEFAULT_STATE="${MEMHP_DEFAULT_STATE:-online}"
BOOT_CMDLINE_OVERRIDE="${BOOT_CMDLINE_OVERRIDE:-}"

APPLY=0
REBOOT=0
TARGET_GIB=""
NODE0_ONLINE_GIB=""

usage() {
  cat <<'EOF'
Usage:
  host_boot_target.sh status
  host_boot_target.sh plan    --target-gib 16 [--node0-online-gib 24]
  host_boot_target.sh apply   --target-gib 16 [--node0-online-gib 24] --apply [--reboot]
  host_boot_target.sh verify  --target-gib 16
  host_boot_target.sh converge --target-gib 16 --apply --reboot
  host_boot_target.sh restore --apply [--reboot]

Purpose:
  Prepare host-native eval_1 boots without the VM.  The generated GRUB
  drop-in reserves all memory outside LOCAL_NODE plus KEEP_MEMORY_NODES, and
  reserves excess LOCAL_NODE memory so node0 free memory converges to
  TARGET_GIB after reboot.  On the current host this keeps node0 + node2 and
  removes node1 memory; node1 CPUs are excluded with maxcpus=32.

Safety:
  - plan/status/verify do not modify GRUB.
  - apply/restore require --apply.
  - reboot only happens when --reboot is also present.

Important environment defaults:
  LOCAL_NODE=0
  KEEP_MEMORY_NODES="2"
  OFFLINE_CPU_NODE=1
  TARGET_TOLERANCE_GIB=1
  NODE0_BOOT_OVERHEAD_GIB=8
  MAX_REBOOTS=4
  ONLINE_KEEP_MEMORY_NODES_AFTER_BOOT=1
  VERIFY_DELAY_AFTER_REBOOT_SEC=30
  VERIFY_WARMUP_PR_AFTER_REBOOT=1
  VERIFY_WARMUP_PR_GRAPH=/Serverless/benchmark/gapbs/benchmark/graphs/kron_g29.sg

Advanced:
  BOOT_CMDLINE_OVERRIDE may be set by the sweep runner to apply a known-good
  current-host cmdline for a target without regenerating a plan from a
  memmap-limited boot.
EOF
}

log() {
  printf '[host-boot-target] %s\n' "$*" >&2
  if [[ -d "${LOG_ROOT}" ]] || mkdir -p "${LOG_ROOT}" 2>/dev/null; then
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${LOG_ROOT}/host_boot_target.log" 2>/dev/null || true
  fi
}

die() {
  log "error: $*"
  exit 2
}

need_root_for_apply() {
  [[ "${EUID}" == "0" ]] || die "this command requires root"
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --target-gib) TARGET_GIB="${2:?missing value}"; shift 2 ;;
      --node0-online-gib|--local-online-gib) NODE0_ONLINE_GIB="${2:?missing value}"; shift 2 ;;
      --apply) APPLY=1; shift ;;
      --reboot) REBOOT=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
}

require_target() {
  [[ "${TARGET_GIB}" =~ ^[0-9]+$ ]] || die "--target-gib must be an integer GiB"
}

default_online_gib() {
  require_target
  local online_mib=$(((TARGET_GIB + NODE0_BOOT_OVERHEAD_GIB) * 1024))
  local block_mib
  block_mib="$(memory_block_mib)"
  if (( online_mib % block_mib != 0 )); then
    online_mib=$(( ((online_mib + block_mib - 1) / block_mib) * block_mib ))
  fi
  printf '%s\n' $(((online_mib + 1023) / 1024))
}

memory_block_mib() {
  local raw
  raw="$(cat /sys/devices/system/memory/block_size_bytes)"
  raw="${raw#0x}"
  printf '%d\n' $((16#${raw} / 1024 / 1024))
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

node_memtotal_mib() {
  local node="$1"
  awk -v node="${node}" '
    $1 == "Node" && $2 == node && $3 == "MemTotal:" {
      print int($4 / 1024); found = 1
    }
    END { if (!found) print 0 }
  ' "/sys/devices/system/node/node${node}/meminfo" 2>/dev/null || printf '0\n'
}

set_auto_online_blocks() {
  [[ "${ONLINE_KEEP_MEMORY_NODES_AFTER_BOOT}" == "1" ]] || return 0
  [[ "${EUID}" == "0" ]] || {
    log "not root; skip setting auto_online_blocks=online"
    return 0
  }
  if [[ -w /sys/devices/system/memory/auto_online_blocks ]]; then
    printf 'online\n' > /sys/devices/system/memory/auto_online_blocks || true
  fi
}

online_dax_memory_for_node() {
  local node="$1"
  [[ "${ONLINE_KEEP_MEMORY_NODES_AFTER_BOOT}" == "1" ]] || return 0
  [[ "${EUID}" == "0" ]] || return 0
  command -v daxctl >/dev/null 2>&1 || return 0

  local -a devs=()
  mapfile -t devs < <(
    daxctl list 2>/dev/null | python3 -c '
import json
import sys

want = int(sys.argv[1])
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
for dev in data:
    try:
        target = int(dev.get("target_node", -1))
    except Exception:
        target = -1
    if target == want and dev.get("mode") == "system-ram" and dev.get("chardev"):
        print(dev["chardev"])
' "${node}"
  )
  ((${#devs[@]} > 0)) || return 0
  log "online CXL/DAX memory for node${node}: ${devs[*]}"
  daxctl online-memory "${devs[@]}" >> "${LOG_ROOT}/daxctl-online-memory.log" 2>&1 || true
}

online_node_memory_blocks() {
  local node="$1"
  [[ "${ONLINE_KEEP_MEMORY_NODES_AFTER_BOOT}" == "1" ]] || return 0
  [[ "${EUID}" == "0" ]] || return 0

  local block online changed=0 failed=0
  for block in "/sys/devices/system/node/node${node}"/memory[0-9]*; do
    [[ -d "${block}" ]] || continue
    online="$(cat "${block}/online" 2>/dev/null || printf '1')"
    [[ "${online}" == "0" ]] || continue
    if printf 'online\n' > "${block}/state" 2>> "${LOG_ROOT}/memory-block-online.log" || \
        printf '1\n' > "${block}/online" 2>> "${LOG_ROOT}/memory-block-online.log"; then
      changed=$((changed + 1))
    else
      failed=$((failed + 1))
    fi
  done
  if (( changed > 0 || failed > 0 )); then
    log "node${node} memory block online attempt changed=${changed} failed=${failed}"
  fi
  (( failed == 0 ))
}

online_keep_memory_nodes_after_boot() {
  [[ "${ONLINE_KEEP_MEMORY_NODES_AFTER_BOOT}" == "1" ]] || return 0
  set_auto_online_blocks

  local node attempt total_mib
  for node in ${KEEP_MEMORY_NODES}; do
    for ((attempt=1; attempt<=CXL_ONLINE_RETRIES; attempt++)); do
      online_dax_memory_for_node "${node}"
      online_node_memory_blocks "${node}" || true
      total_mib="$(node_memtotal_mib "${node}")"
      if (( total_mib >= MIN_KEEP_NODE_TOTAL_GIB * 1024 )); then
        log "node${node} memory online: total=${total_mib}MiB"
        break
      fi
      log "node${node} memory not online yet: total=${total_mib}MiB attempt=${attempt}/${CXL_ONLINE_RETRIES}"
      (( attempt < CXL_ONLINE_RETRIES )) && sleep "${CXL_ONLINE_RETRY_INTERVAL_SEC}"
    done
  done
}

drop_caches_for_verify() {
  [[ "${DROP_CACHES_BEFORE_VERIFY}" == "1" ]] || return 0
  sync || true
  if [[ -w /proc/sys/vm/drop_caches ]]; then
    printf '3\n' > /proc/sys/vm/drop_caches || true
  fi
}

run_pr_warmup_for_verify() {
  [[ "${VERIFY_WARMUP_PR_AFTER_REBOOT}" == "1" ]] || return 0
  [[ "${ICCD_FROM_REBOOT_HOOK}" == "1" ]] || return 0

  local log_file="${LOG_ROOT}/pr-warmup-$(date -u +%Y%m%dT%H%M%SZ).log"
  mkdir -p "${LOG_ROOT}" 2>/dev/null || true

  if [[ ! -x "${VERIFY_WARMUP_PR_BIN}" ]]; then
    log "PR warmup skipped; binary not executable: ${VERIFY_WARMUP_PR_BIN}"
    return 0
  fi
  if [[ ! -r "${VERIFY_WARMUP_PR_GRAPH}" ]]; then
    log "PR warmup skipped; graph not readable: ${VERIFY_WARMUP_PR_GRAPH}"
    return 0
  fi
  if ! command -v numactl >/dev/null 2>&1; then
    log "PR warmup skipped; numactl not found"
    return 0
  fi

  if [[ -w /proc/sys/kernel/numa_balancing ]]; then
    printf '2\n' > /proc/sys/kernel/numa_balancing || true
  else
    log "PR warmup could not set numa_balancing=2"
  fi

  log "running PR warmup before final verify; log=${log_file}"
  local rc=0
  {
    printf 'started_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'graph_mode=prebuilt\n'
    printf 'graph_path=%s\n' "${VERIFY_WARMUP_PR_GRAPH}"
    printf 'numa_balancing_before=%s\n' "$(cat /proc/sys/kernel/numa_balancing 2>/dev/null || true)"
    printf 'node0_memfree_mib_before=%s\n' "$(node_memfree_mib "${LOCAL_NODE}" 2>/dev/null || true)"
    set +e
    /usr/bin/time -v \
      numactl --cpunodebind="${VERIFY_WARMUP_CPU_NODE}" \
      env OMP_NUM_THREADS="${VERIFY_WARMUP_PR_THREADS}" OMP_PROC_BIND=true OMP_PLACES=cores \
      "${VERIFY_WARMUP_PR_BIN}" \
      -f "${VERIFY_WARMUP_PR_GRAPH}" \
      -i "${VERIFY_WARMUP_PR_ITERATIONS}" \
      -t "${VERIFY_WARMUP_PR_TOLERANCE}" \
      -n "${VERIFY_WARMUP_PR_TRIALS}"
    rc=$?
    set -e
    printf 'rc=%s\n' "${rc}"
    printf 'node0_memfree_mib_after_pr=%s\n' "$(node_memfree_mib "${LOCAL_NODE}" 2>/dev/null || true)"
    printf 'finished_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${log_file}" 2>&1
  if (( rc != 0 )); then
    log "PR warmup failed with rc=${rc}; continuing to final verify"
  fi

  drop_caches_for_verify
  log "dropped caches after PR warmup"
}

generate_plan() {
  require_target
  local online_gib="${NODE0_ONLINE_GIB:-}"
  [[ -n "${online_gib}" ]] || online_gib="$(default_online_gib)"
  [[ "${online_gib}" =~ ^[0-9]+$ ]] || die "--node0-online-gib must be an integer GiB"

  if [[ -n "${BOOT_CMDLINE_OVERRIDE}" ]]; then
    printf 'target_gib=%s\n' "${TARGET_GIB}"
    printf 'node0_online_gib=%s\n' "${online_gib}"
    printf 'block_mib=%s\n' "$(memory_block_mib)"
    printf 'local_node=%s\n' "${LOCAL_NODE}"
    printf 'keep_memory_nodes=%s\n' "${KEEP_MEMORY_NODES}"
    printf 'excluded_ranges_count=override\n'
    printf 'excluded_ranges=override\n'
    printf 'kept_ranges=override\n'
    printf 'offline_cpu_node=%s\n' "${OFFLINE_CPU_NODE}"
    printf 'offline_cpu_count=override\n'
    printf 'cmdline=%s\n' "${BOOT_CMDLINE_OVERRIDE}"
    return 0
  fi

  local preserve_cmdline=""
  if [[ "${ICCD_FROM_REBOOT_HOOK}" == "1" && -r "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}" || true
    preserve_cmdline="${cmdline:-}"
  fi

  TARGET_GIB="${TARGET_GIB}" \
  NODE0_ONLINE_GIB="${online_gib}" \
  LOCAL_NODE="${LOCAL_NODE}" \
  KEEP_MEMORY_NODES="${KEEP_MEMORY_NODES}" \
  OFFLINE_CPU_NODE="${OFFLINE_CPU_NODE}" \
  CPU_BOOT_MODE="${CPU_BOOT_MODE}" \
  ENABLE_NOSMT="${ENABLE_NOSMT}" \
  MEMHP_DEFAULT_STATE="${MEMHP_DEFAULT_STATE}" \
  PRESERVE_CMDLINE_MEMMAPS="${preserve_cmdline}" \
  python3 - <<'PY'
import math
import os
import re
from pathlib import Path

GiB = 1024 ** 3
target_gib = int(os.environ["TARGET_GIB"])
online_gib = int(os.environ["NODE0_ONLINE_GIB"])
local_node = int(os.environ["LOCAL_NODE"])
keep_nodes = {int(x) for x in os.environ.get("KEEP_MEMORY_NODES", "").split() if x}
offline_cpu_node = int(os.environ["OFFLINE_CPU_NODE"])
cpu_boot_mode = os.environ.get("CPU_BOOT_MODE", "maxcpus")
enable_nosmt = os.environ.get("ENABLE_NOSMT", "1") == "1"
memhp_default_state = os.environ.get("MEMHP_DEFAULT_STATE", "online")
preserve_cmdline = os.environ.get("PRESERVE_CMDLINE_MEMMAPS", "")

block_size = int(Path("/sys/devices/system/memory/block_size_bytes").read_text().strip(), 16)
MiB = 1024 ** 2
block_mib = block_size // MiB
if block_size % MiB:
    raise SystemExit("memory block size is not MiB aligned")
online_bytes = online_gib * GiB
if online_bytes % block_size:
    online_bytes = math.ceil(online_bytes / block_size) * block_size
online_gib = math.ceil(online_bytes / GiB)

def parse_cpulist(text):
    out = []
    for part in text.strip().replace(",", " ").split():
        if "-" in part:
            a, b = [int(x) for x in part.split("-", 1)]
            out.extend(range(a, b + 1))
        elif part:
            out.append(int(part))
    return sorted(set(out))

def node_blocks(node):
    base = Path(f"/sys/devices/system/node/node{node}")
    blocks = []
    if not base.exists():
        return blocks
    for p in base.glob("memory[0-9]*"):
        try:
            phys_index = int((p / "phys_index").read_text().strip(), 16)
        except Exception:
            continue
        start = phys_index * block_size
        blocks.append((start, start + block_size, p.name))
    return sorted(blocks)

nodes = []
for p in Path("/sys/devices/system/node").glob("node[0-9]*"):
    nodes.append(int(p.name[4:]))
nodes.sort()

local_blocks = node_blocks(local_node)
if not local_blocks:
    raise SystemExit(f"local node{local_node} has no memory blocks")
keep_count = online_bytes // block_size
if keep_count <= 0:
    raise SystemExit("node0 online GiB would keep no local memory")
if keep_count > len(local_blocks):
    raise SystemExit(
        f"node{local_node} online GiB {online_gib} exceeds node capacity "
        f"{len(local_blocks) * block_size // GiB}G"
    )

excluded = []
kept = []
for node in nodes:
    blocks = node_blocks(node)
    if node == local_node:
        kept.extend((node, *b) for b in blocks[:keep_count])
        excluded.extend((node, *b) for b in blocks[keep_count:])
    elif node in keep_nodes:
        kept.extend((node, *b) for b in blocks)
    else:
        excluded.extend((node, *b) for b in blocks)

def parse_memmap_size(value, unit):
    return int(value) * {
        "": 1,
        "K": 1024,
        "M": MiB,
        "G": GiB,
    }[unit]

for m in re.finditer(r"(?:^|\s)memmap=([0-9]+)([KMG]?)\$0x([0-9a-fA-F]+)", preserve_cmdline):
    size = parse_memmap_size(m.group(1), m.group(2))
    start = int(m.group(3), 16)
    excluded.append((-1, start, start + size, "preserved"))

def merge_ranges(items):
    ranges = []
    for _node, start, end, _name in sorted(items, key=lambda x: x[1]):
        if ranges and ranges[-1][1] == start:
            ranges[-1] = (ranges[-1][0], end)
        else:
            ranges.append((start, end))
    return ranges

exclude_ranges = merge_ranges(excluded)
keep_ranges = merge_ranges(kept)

cmd = []
if cpu_boot_mode == "maxcpus":
    cpus = parse_cpulist((Path(f"/sys/devices/system/node/node{local_node}") / "cpulist").read_text())
    if cpus != list(range(len(cpus))):
        raise SystemExit(
            f"node{local_node} CPUs are not contiguous from CPU0; refusing maxcpus plan: {cpus}"
        )
    cmd.append(f"maxcpus={len(cpus)}")
elif cpu_boot_mode != "none":
    raise SystemExit(f"unknown CPU_BOOT_MODE={cpu_boot_mode}")
if enable_nosmt:
    cmd.append("nosmt")
if memhp_default_state:
    cmd.append(f"memhp_default_state={memhp_default_state}")
for start, end in exclude_ranges:
    size = end - start
    if size % GiB == 0:
        size_s = f"{size // GiB}G"
    elif size % MiB == 0:
        size_s = f"{size // MiB}M"
    else:
        size_s = f"{size}"
    cmd.append(f"memmap={size_s}$0x{start:x}")

offline_cpus = []
off_cpu_path = Path(f"/sys/devices/system/node/node{offline_cpu_node}/cpulist")
if off_cpu_path.exists():
    offline_cpus = parse_cpulist(off_cpu_path.read_text())

print(f"target_gib={target_gib}")
print(f"node0_online_gib={online_gib}")
print(f"block_mib={block_mib}")
print(f"local_node={local_node}")
print(f"keep_memory_nodes={' '.join(str(x) for x in sorted(keep_nodes))}")
print(f"excluded_ranges_count={len(exclude_ranges)}")
def fmt_range(start, end):
    size = end - start
    if size % GiB == 0:
        return f"{size // GiB}G@0x{start:x}"
    if size % MiB == 0:
        return f"{size // MiB}M@0x{start:x}"
    return f"{size}@0x{start:x}"
print("excluded_ranges=" + " ".join(fmt_range(s, e) for s, e in exclude_ranges))
print("kept_ranges=" + " ".join(fmt_range(s, e) for s, e in keep_ranges))
print(f"offline_cpu_node={offline_cpu_node}")
print(f"offline_cpu_count={len(offline_cpus)}")
print("cmdline=" + " ".join(cmd))
PY
}

plan_cmdline() {
  generate_plan | awk -F= '$1 == "cmdline" {sub(/^cmdline=/, ""); print; exit}'
}

write_state() {
  local cmdline="$1" online_gib="$2" mode="$3"
  mkdir -p "${STATE_ROOT}" "${LOG_ROOT}"
  {
    printf 'updated_utc=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'mode=%q\n' "${mode}"
    printf 'target_gib=%q\n' "${TARGET_GIB:-}"
    printf 'node0_online_gib=%q\n' "${online_gib}"
    printf 'target_tolerance_gib=%q\n' "${TARGET_TOLERANCE_GIB}"
    printf 'local_node=%q\n' "${LOCAL_NODE}"
    printf 'keep_memory_nodes=%q\n' "${KEEP_MEMORY_NODES}"
    printf 'offline_cpu_node=%q\n' "${OFFLINE_CPU_NODE}"
    printf 'max_reboots=%q\n' "${MAX_REBOOTS}"
    printf 'online_keep_memory_nodes_after_boot=%q\n' "${ONLINE_KEEP_MEMORY_NODES_AFTER_BOOT}"
    printf 'cxl_online_retries=%q\n' "${CXL_ONLINE_RETRIES}"
    printf 'cxl_online_retry_interval_sec=%q\n' "${CXL_ONLINE_RETRY_INTERVAL_SEC}"
    printf 'verify_delay_after_reboot_sec=%q\n' "${VERIFY_DELAY_AFTER_REBOOT_SEC}"
    printf 'verify_warmup_pr_after_reboot=%q\n' "${VERIFY_WARMUP_PR_AFTER_REBOOT}"
    printf 'verify_warmup_pr_bin=%q\n' "${VERIFY_WARMUP_PR_BIN}"
    printf 'verify_warmup_pr_graph=%q\n' "${VERIFY_WARMUP_PR_GRAPH}"
    printf 'verify_warmup_pr_scale=%q\n' "${VERIFY_WARMUP_PR_SCALE}"
    printf 'verify_warmup_pr_iterations=%q\n' "${VERIFY_WARMUP_PR_ITERATIONS}"
    printf 'verify_warmup_pr_trials=%q\n' "${VERIFY_WARMUP_PR_TRIALS}"
    printf 'verify_warmup_pr_threads=%q\n' "${VERIFY_WARMUP_PR_THREADS}"
    printf 'cmdline=%q\n' "${cmdline}"
  } > "${STATE_FILE}"
}

current_reboots() {
  local f="${STATE_ROOT}/reboot.count"
  [[ -f "${f}" ]] && cat "${f}" || printf '0\n'
}

set_reboots() {
  mkdir -p "${STATE_ROOT}"
  printf '%s\n' "$1" > "${STATE_ROOT}/reboot.count"
}

grub_escape_cmdline() {
  local value="$1"
  printf '%s\n' "${value//\$/\\\$}"
}

write_grub_dropin() {
  local cmdline="$1"
  local grub_cmdline
  grub_cmdline="$(grub_escape_cmdline "${cmdline}")"
  [[ "${grub_cmdline}" != *"'"* ]] || die "cmdline contains unsupported single quote"
  need_root_for_apply
  mkdir -p "$(dirname -- "${GRUB_DROPIN}")" "${STATE_ROOT}" "${LOG_ROOT}"
  if [[ -e "${GRUB_DROPIN}" && ! -e "${STATE_ROOT}/original-dropin.cfg" ]]; then
    cp -a "${GRUB_DROPIN}" "${STATE_ROOT}/original-dropin.cfg"
  fi
  cat > "${GRUB_DROPIN}" <<EOF
# Generated by ${BASH_SOURCE[0]}.
# Remove with:
#   ${SCRIPT_PATH} restore --apply
# Raw kernel cmdline before GRUB escaping:
#   ${cmdline}
ICCD_EVAL1_HOST_NATIVE_CMDLINE='${grub_cmdline}'
GRUB_CMDLINE_LINUX="\${GRUB_CMDLINE_LINUX:-} \${ICCD_EVAL1_HOST_NATIVE_CMDLINE}"
EOF
  update_grub
}

update_grub() {
  need_root_for_apply
  if command -v update-grub >/dev/null 2>&1; then
    update-grub
  elif command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg
  else
    die "neither update-grub nor grub-mkconfig is available"
  fi
}

install_reboot_hook() {
  need_root_for_apply
  mkdir -p "${STATE_ROOT}" "${LOG_ROOT}"
  local marker_begin="# ICCD_EVAL1_HOST_NATIVE_REBOOT_BEGIN"
  local marker_end="# ICCD_EVAL1_HOST_NATIVE_REBOOT_END"
  local cmd
  cmd="cd ${REPO_ROOT@Q} && TARGET_GIB=${TARGET_GIB@Q} LOCAL_NODE=${LOCAL_NODE@Q} KEEP_MEMORY_NODES=${KEEP_MEMORY_NODES@Q} OFFLINE_CPU_NODE=${OFFLINE_CPU_NODE@Q} TARGET_TOLERANCE_GIB=${TARGET_TOLERANCE_GIB@Q} NODE0_BOOT_OVERHEAD_GIB=${NODE0_BOOT_OVERHEAD_GIB@Q} MAX_REBOOTS=${MAX_REBOOTS@Q} ONLINE_KEEP_MEMORY_NODES_AFTER_BOOT=${ONLINE_KEEP_MEMORY_NODES_AFTER_BOOT@Q} CXL_ONLINE_RETRIES=${CXL_ONLINE_RETRIES@Q} CXL_ONLINE_RETRY_INTERVAL_SEC=${CXL_ONLINE_RETRY_INTERVAL_SEC@Q} VERIFY_DELAY_AFTER_REBOOT_SEC=${VERIFY_DELAY_AFTER_REBOOT_SEC@Q} VERIFY_WARMUP_PR_AFTER_REBOOT=${VERIFY_WARMUP_PR_AFTER_REBOOT@Q} VERIFY_WARMUP_PR_BIN=${VERIFY_WARMUP_PR_BIN@Q} VERIFY_WARMUP_PR_GRAPH=${VERIFY_WARMUP_PR_GRAPH@Q} VERIFY_WARMUP_PR_SCALE=${VERIFY_WARMUP_PR_SCALE@Q} VERIFY_WARMUP_PR_ITERATIONS=${VERIFY_WARMUP_PR_ITERATIONS@Q} VERIFY_WARMUP_PR_TOLERANCE=${VERIFY_WARMUP_PR_TOLERANCE@Q} VERIFY_WARMUP_PR_TRIALS=${VERIFY_WARMUP_PR_TRIALS@Q} VERIFY_WARMUP_PR_THREADS=${VERIFY_WARMUP_PR_THREADS@Q} VERIFY_WARMUP_CPU_NODE=${VERIFY_WARMUP_CPU_NODE@Q} ICCD_FROM_REBOOT_HOOK=1 exec ${SCRIPT_PATH@Q} converge --target-gib ${TARGET_GIB@Q} --apply --reboot >> ${LOG_ROOT@Q}/reboot-hook.log 2>&1"
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
  log "installed @reboot converge hook"
}

remove_reboot_hook() {
  [[ "${EUID}" == "0" ]] || return 0
  local marker_begin="# ICCD_EVAL1_HOST_NATIVE_REBOOT_BEGIN"
  local marker_end="# ICCD_EVAL1_HOST_NATIVE_REBOOT_END"
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | awk -v begin="${marker_begin}" -v end="${marker_end}" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' > "${tmp}"
  crontab "${tmp}" || true
  rm -f "${tmp}"
  log "removed @reboot converge hook"
}

do_reboot() {
  sync || true
  if [[ "${REBOOT}" == "1" ]]; then
    log "rebooting host"
    systemctl reboot --message "iccd eval1 host native memory target ${TARGET_GIB}G" || reboot
  else
    log "GRUB updated; reboot not requested"
  fi
}

restore_full_boot_for_converge() {
  need_root_for_apply
  install_reboot_hook
  if [[ -e "${GRUB_DROPIN}" ]]; then
    rm -f "${GRUB_DROPIN}"
    update_grub
  fi
  write_state "" "" "restore-for-converge"
  log "restoring unrestricted boot first; convergence will continue after reboot"
  do_reboot
}

cmd_status() {
  printf 'cmdline=%s\n' "$(cat /proc/cmdline)"
  printf 'cpu_online=%s\n' "$(cat /sys/devices/system/cpu/online 2>/dev/null || true)"
  printf 'cpu_offline=%s\n' "$(cat /sys/devices/system/cpu/offline 2>/dev/null || true)"
  printf 'auto_online_blocks=%s\n' "$(cat /sys/devices/system/memory/auto_online_blocks 2>/dev/null || true)"
  printf 'block_size_bytes=%s\n' "$(cat /sys/devices/system/memory/block_size_bytes 2>/dev/null || true)"
  local node
  for node in /sys/devices/system/node/node*; do
    [[ -d "${node}" ]] || continue
    node="${node##*/node}"
    printf 'node%s_cpulist=%s\n' "${node}" "$(cat "/sys/devices/system/node/node${node}/cpulist" 2>/dev/null || true)"
    printf 'node%s_memtotal_mib=%s\n' "${node}" "$(node_memtotal_mib "${node}")"
    printf 'node%s_memfree_mib=%s\n' "${node}" "$(node_memfree_mib "${node}" 2>/dev/null || printf 0)"
  done
  if [[ -f "${GRUB_DROPIN}" ]]; then
    printf 'grub_dropin=%s\n' "${GRUB_DROPIN}"
    sed -n '1,40p' "${GRUB_DROPIN}"
  else
    printf 'grub_dropin_absent=%s\n' "${GRUB_DROPIN}"
  fi
}

cmd_plan() {
  generate_plan
}

cmd_apply() {
  require_target
  [[ "${APPLY}" == "1" ]] || die "apply requires --apply"
  need_root_for_apply
  local plan cmdline online_gib
  plan="$(generate_plan)"
  printf '%s\n' "${plan}"
  cmdline="$(printf '%s\n' "${plan}" | awk -F= '$1 == "cmdline" {sub(/^cmdline=/, ""); print; exit}')"
  online_gib="$(printf '%s\n' "${plan}" | awk -F= '$1 == "node0_online_gib" {print $2; exit}')"
  write_grub_dropin "${cmdline}"
  write_state "${cmdline}" "${online_gib}" "apply"
  [[ "${REBOOT}" == "1" ]] && install_reboot_hook
  do_reboot
}

cmd_verify() {
  require_target
  online_keep_memory_nodes_after_boot
  drop_caches_for_verify
  local free_mib lower upper node1_total keep_node keep_total failed=0
  lower=$(((TARGET_GIB - TARGET_TOLERANCE_GIB) * 1024))
  upper=$(((TARGET_GIB + TARGET_TOLERANCE_GIB) * 1024))
  free_mib="$(node_memfree_mib "${LOCAL_NODE}")"
  node1_total="$(node_memtotal_mib "${OFFLINE_CPU_NODE}")"
  printf 'target_gib=%s\n' "${TARGET_GIB}"
  printf 'target_window_mib=%s-%s\n' "${lower}" "${upper}"
  printf 'node%s_free_mib=%s\n' "${LOCAL_NODE}" "${free_mib}"
  printf 'node%s_memtotal_mib=%s\n' "${OFFLINE_CPU_NODE}" "${node1_total}"
  if (( free_mib < lower || free_mib > upper )); then
    printf 'target_ok=0\n'
    failed=1
  else
    printf 'target_ok=1\n'
  fi
  if (( node1_total > 0 )); then
    printf 'offline_memory_node_ok=0\n'
    failed=1
  else
    printf 'offline_memory_node_ok=1\n'
  fi
  local online_list
  online_list="$(cat /sys/devices/system/cpu/online 2>/dev/null || true)"
  printf 'cpu_online=%s\n' "${online_list}"
  if python3 - "${OFFLINE_CPU_NODE}" <<'PY'
import sys
from pathlib import Path
want = int(sys.argv[1])
def expand(s):
    out = set()
    for part in s.strip().replace(',', ' ').split():
        if '-' in part:
            a,b = [int(x) for x in part.split('-', 1)]
            out.update(range(a,b+1))
        elif part:
            out.add(int(part))
    return out
online = expand(Path('/sys/devices/system/cpu/online').read_text())
cpulist = Path(f'/sys/devices/system/node/node{want}/cpulist')
node_cpus = expand(cpulist.read_text()) if cpulist.exists() else set()
bad = sorted(online & node_cpus)
if bad:
    print('offline_cpu_node_ok=0')
    print('online_offline_node_cpus=' + ','.join(map(str,bad)))
    sys.exit(1)
print('offline_cpu_node_ok=1')
PY
  then
    :
  else
    failed=1
  fi
  for keep_node in ${KEEP_MEMORY_NODES}; do
    keep_total="$(node_memtotal_mib "${keep_node}")"
    printf 'node%s_memtotal_mib=%s\n' "${keep_node}" "${keep_total}"
    if (( keep_total < MIN_KEEP_NODE_TOTAL_GIB * 1024 )); then
      printf 'keep_node%s_ok=0\n' "${keep_node}"
      failed=1
    else
      printf 'keep_node%s_ok=1\n' "${keep_node}"
    fi
  done
  return "${failed}"
}

adjust_online_gib() {
  require_target
  local current_online="${NODE0_ONLINE_GIB:-}"
  if [[ -z "${current_online}" && -r "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}" || true
    current_online="${node0_online_gib:-}"
  fi
  [[ -n "${current_online}" ]] || current_online="$(default_online_gib)"

  drop_caches_for_verify
  local free_mib lower upper block_mib step_mib delta_mib delta_steps next_online_mib
  free_mib="$(node_memfree_mib "${LOCAL_NODE}")"
  lower=$(((TARGET_GIB - TARGET_TOLERANCE_GIB) * 1024))
  upper=$(((TARGET_GIB + TARGET_TOLERANCE_GIB) * 1024))
  block_mib="$(memory_block_mib)"
  step_mib="${block_mib}"
  (( step_mib < 1024 )) && step_mib=1024
  next_online_mib=$((current_online * 1024))
  if (( free_mib < lower )); then
    delta_mib=$((lower - free_mib))
    delta_steps=$(((delta_mib + step_mib - 1) / step_mib))
    (( delta_steps < 1 )) && delta_steps=1
    next_online_mib=$((next_online_mib + delta_steps * step_mib))
  elif (( free_mib > upper )); then
    delta_mib=$((free_mib - upper))
    delta_steps=$(((delta_mib + step_mib - 1) / step_mib))
    (( delta_steps < 1 )) && delta_steps=1
    next_online_mib=$((next_online_mib - delta_steps * step_mib))
  fi
  (( next_online_mib < step_mib )) && next_online_mib="${step_mib}"
  printf '%s\n' $(((next_online_mib + 1023) / 1024))
}

cmd_converge() {
  require_target
  [[ "${APPLY}" == "1" ]] || die "converge requires --apply"
  need_root_for_apply

  local previous_mode=""
  if [[ "${ICCD_FROM_REBOOT_HOOK}" == "1" && -r "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}" || true
    previous_mode="${mode:-}"
  fi
  if [[ "${REBOOT}" == "1" &&
        "${ICCD_FROM_REBOOT_HOOK}" == "1" &&
        "${previous_mode}" == "restore-for-converge" ]]; then
    [[ -n "${NODE0_ONLINE_GIB}" ]] || NODE0_ONLINE_GIB="$(default_online_gib)"
    log "unrestricted boot restored; applying initial node0_online_gib=${NODE0_ONLINE_GIB} and rebooting"
    cmd_apply
    return 0
  fi

  if [[ "${REBOOT}" == "1" && "${ICCD_FROM_REBOOT_HOOK}" != "1" ]]; then
    set_reboots 0
    [[ -n "${NODE0_ONLINE_GIB}" ]] || NODE0_ONLINE_GIB="$(default_online_gib)"
    local plan_err
    plan_err="$(mktemp)"
    if ! generate_plan > /dev/null 2> "${plan_err}"; then
      while IFS= read -r line; do
        [[ -n "${line}" ]] && log "initial plan failed: ${line}"
      done < "${plan_err}"
      rm -f "${plan_err}"
      restore_full_boot_for_converge
      return 0
    fi
    rm -f "${plan_err}"
    log "starting convergence for ${TARGET_GIB}G; applying initial node0_online_gib=${NODE0_ONLINE_GIB} and rebooting"
    cmd_apply
    return 0
  fi

  if [[ "${ICCD_FROM_REBOOT_HOOK}" == "1" &&
        "${VERIFY_DELAY_AFTER_REBOOT_SEC}" =~ ^[0-9]+$ &&
        "${VERIFY_DELAY_AFTER_REBOOT_SEC}" -gt 0 ]]; then
    log "waiting ${VERIFY_DELAY_AFTER_REBOOT_SEC}s after reboot before verify"
    sleep "${VERIFY_DELAY_AFTER_REBOOT_SEC}"
  fi

  run_pr_warmup_for_verify

  if cmd_verify; then
    log "target reached for ${TARGET_GIB}G"
    set_reboots 0
    remove_reboot_hook
    return 0
  fi

  local count next_online
  count="$(current_reboots)"
  if (( count >= MAX_REBOOTS )); then
    remove_reboot_hook
    die "target not reached after ${count}/${MAX_REBOOTS} reboots"
  fi
  count=$((count + 1))
  set_reboots "${count}"
  next_online="$(adjust_online_gib)"
  NODE0_ONLINE_GIB="${next_online}"
  log "target not reached; adjusting node0_online_gib=${next_online} and rebooting (${count}/${MAX_REBOOTS})"
  cmd_apply
}

cmd_restore() {
  [[ "${APPLY}" == "1" ]] || die "restore requires --apply"
  need_root_for_apply
  if [[ -e "${GRUB_DROPIN}" ]]; then
    rm -f "${GRUB_DROPIN}"
    update_grub
  fi
  remove_reboot_hook
  set_reboots 0
  write_state "" "" "restore"
  do_reboot
}

main() {
  local cmd="${1:-}"
  shift || true
  parse_args "$@"
  if ! mkdir -p "${STATE_ROOT}" "${LOG_ROOT}" 2>/dev/null; then
    LOCK_FILE="/tmp/iccd-eval1-host-native-${UID}.lock"
  fi
  if ! { : > "${LOCK_FILE}"; } 2>/dev/null; then
    LOCK_FILE="/tmp/iccd-eval1-host-native-${UID}.lock"
  fi
  exec 9>"${LOCK_FILE}"
  flock 9
  case "${cmd}" in
    status) cmd_status ;;
    plan) cmd_plan ;;
    apply) cmd_apply ;;
    verify) cmd_verify ;;
    converge) cmd_converge ;;
    restore) cmd_restore ;;
    -h|--help|"") usage ;;
    *) die "unknown command: ${cmd}" ;;
  esac
}

main "$@"
