#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ICCD_REPO_ROOT="${ICCD_REPO_ROOT:-${REPO_ROOT}}"
ICCD_DEFAULTS="${ICCD_DEFAULTS:-${REPO_ROOT}/scripts/iccd_experiment_defaults.sh}"
if [[ -r "${ICCD_DEFAULTS}" ]]; then
  # shellcheck source=scripts/iccd_experiment_defaults.sh
  source "${ICCD_DEFAULTS}"
fi
VM_DIR="${VM_DIR:-${REPO_ROOT}/VM}"
VMCTL="${VMCTL:-${ICCD_VMCTL:-${VM_DIR}/vmctl.sh}}"
VM_ACTION="${VM_ACTION:-stage}"
PORT="${PORT:-10030}"
HOST="${HOST:-127.0.0.1}"
SSH_KEY="${SSH_KEY:-}"
BENCHMARK_DIR="${BENCHMARK_DIR:-/Serverless/benchmark}"
WORKLOADS="${WORKLOADS:-core}"
CLEAN="${CLEAN:-0}"
CLEAN_SCRIPTS="${CLEAN_SCRIPTS:-1}"
STAGE_JDK="${STAGE_JDK:-auto}"
STAGE_JDK17="${STAGE_JDK17:-auto}"
STAGE_DOTNET="${STAGE_DOTNET:-auto}"
STAGE_DLRM_VENV="${STAGE_DLRM_VENV:-1}"
STAGE_FRAMEWORKS="${STAGE_FRAMEWORKS:-0}"
STAGE_GAPBS_GRAPH="${STAGE_GAPBS_GRAPH:-1}"
SSH_CONTROL_MASTER="${SSH_CONTROL_MASTER:-1}"
SSH_CONTROL_PATH="${SSH_CONTROL_PATH:-/tmp/iccd-realworld-${PORT}.sock}"

VM_NAME="${VM_NAME:-iccd-workload-vm}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
KERNEL="${KERNEL:-${ICCD_KERNEL:-}}"
INITRD="${INITRD:-}"
ROOTFS="${ROOTFS:-}"
ROOTFS_FORMAT="${ROOTFS_FORMAT:-raw}"
ROOT_DEVICE="${ROOT_DEVICE:-}"
ACCEL="${ACCEL:-kvm}"
HOST_CPUS="${HOST_CPUS:-${ICCD_HOST_CPUS:-0-31}}"
GUEST_CPUS="${GUEST_CPUS:-${ICCD_GUEST_CPUS:-32}}"
GUEST_NODE0_CPUS="${GUEST_NODE0_CPUS:-${ICCD_GUEST_NODE0_CPUS:-0-31}}"
FAST_HOST_NODE="${FAST_HOST_NODE:-${ICCD_FAST_HOST_NODE:-0}}"
SLOW_HOST_NODE="${SLOW_HOST_NODE:-${ICCD_SLOW_HOST_NODE:-2}}"
FAST_MEM="${FAST_MEM:-8G}"
SLOW_MEM="${SLOW_MEM:-160G}"
SLOW_MEMORY_MODE="${SLOW_MEMORY_MODE:-${ICCD_SLOW_MEMORY_MODE:-host-cxl}}"
HMAT_FAST_LATENCY_NS="${HMAT_FAST_LATENCY_NS:-${ICCD_HMAT_FAST_LATENCY_NS:-80}}"
HMAT_SLOW_LATENCY_NS="${HMAT_SLOW_LATENCY_NS:-${ICCD_HMAT_SLOW_LATENCY_NS:-250}}"
HMAT_FAST_BANDWIDTH="${HMAT_FAST_BANDWIDTH:-${ICCD_HMAT_FAST_BANDWIDTH:-40000M}}"
HMAT_SLOW_BANDWIDTH="${HMAT_SLOW_BANDWIDTH:-${ICCD_HMAT_SLOW_BANDWIDTH:-10000M}}"
VERIFY_PLACEMENT="${VERIFY_PLACEMENT:-1}"
STOP_VM_ON_SUCCESS="${STOP_VM_ON_SUCCESS:-0}"
GUEST_OUTROOT="${GUEST_OUTROOT:-/root/script-smoke-pr}"
GUEST_POLICIES="${GUEST_POLICIES:-off ours}"
GUEST_CAPS="${GUEST_CAPS:-physical:0}"
GUEST_MODE="${GUEST_MODE:-matrix}"
GUEST_TIMEOUT_SEC="${GUEST_TIMEOUT_SEC:-1200}"
GUEST_OMP_THREADS="${GUEST_OMP_THREADS:-32}"
PR_ITERATIONS="${PR_ITERATIONS:-1}"
PR_TRIALS="${PR_TRIALS:-1}"
GAPBS_GRAPH_SCALE="${GAPBS_GRAPH_SCALE:-29}"
GAPBS_GRAPH_NAME="${GAPBS_GRAPH_NAME:-kron_g${GAPBS_GRAPH_SCALE}.sg}"
GAPBS_GRAPH_HOST="${GAPBS_GRAPH_HOST:-${BENCHMARK_DIR}/gapbs/benchmark/graphs/${GAPBS_GRAPH_NAME}}"
GAPBS_GRAPH_GUEST="${GAPBS_GRAPH_GUEST:-/root/gapbs_graphs/${GAPBS_GRAPH_NAME}}"

SSH_OPTS=(-p "${PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
SCP_OPTS=(-P "${PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
if [[ -n "${SSH_KEY}" ]]; then
  SSH_OPTS+=(-i "${SSH_KEY}")
  SCP_OPTS+=(-i "${SSH_KEY}")
fi
if [[ "${SSH_CONTROL_MASTER}" == "1" ]]; then
  SSH_OPTS+=(
    -o LogLevel=ERROR
    -o ControlMaster=auto
    -o ControlPersist=600
    -o ControlPath="${SSH_CONTROL_PATH}"
  )
  SCP_OPTS+=(
    -o LogLevel=ERROR
    -o ControlMaster=auto
    -o ControlPersist=600
    -o ControlPath="${SSH_CONTROL_PATH}"
  )
  trap 'ssh -p "${PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ControlPath="${SSH_CONTROL_PATH}" -O exit "root@${HOST}" >/dev/null 2>&1 || true; rm -f "${SSH_CONTROL_PATH}"' EXIT
fi

die() {
  echo "error: $*" >&2
  exit 2
}

require_vm_submodule() {
  if [[ ! -x "${VMCTL}" ]]; then
    cat >&2 <<EOF
error: VM submodule is not initialized or vmctl.sh is not executable: ${VMCTL}

Run this from the iccd repo first:
  git submodule update --init VM

Or override VM_DIR/VMCTL explicitly.
EOF
    exit 2
  fi
}

vm_ssh_args() {
  VM_SSH_ARGS=(--ssh-port "${PORT}" --host "${HOST}" --name "${VM_NAME}")
  if [[ -n "${SSH_KEY}" ]]; then
    VM_SSH_ARGS+=(--ssh-key "${SSH_KEY}")
  fi
}

vmctl_cmd() {
  require_vm_submodule
  "${VMCTL}" "$@"
}

boot_vm_if_requested() {
  [[ "${VM_ACTION}" == "boot-stage" || "${VM_ACTION}" == "pr-smoke" ]] || return 0
  [[ -n "${KERNEL}" ]] || die "KERNEL is required when VM_ACTION=${VM_ACTION}"
  [[ -n "${ROOTFS}" ]] || die "ROOTFS is required when VM_ACTION=${VM_ACTION}"

  local -a args=(
    boot
    --qemu-bin "${QEMU_BIN}"
    --kernel "${KERNEL}"
    --rootfs "${ROOTFS}"
    --rootfs-format "${ROOTFS_FORMAT}"
    --ssh-port "${PORT}"
    --name "${VM_NAME}"
    --host-cpus "${HOST_CPUS}"
    --guest-cpus "${GUEST_CPUS}"
    --guest-node0-cpus "${GUEST_NODE0_CPUS}"
    --fast-host-node "${FAST_HOST_NODE}"
    --slow-host-node "${SLOW_HOST_NODE}"
    --fast-mem "${FAST_MEM}"
    --slow-mem "${SLOW_MEM}"
    --slow-memory-mode "${SLOW_MEMORY_MODE}"
    --accel "${ACCEL}"
  )
  [[ -z "${INITRD}" ]] || args+=(--initrd "${INITRD}")
  [[ -z "${ROOT_DEVICE}" ]] || args+=(--root-device "${ROOT_DEVICE}")
  args+=(--hmat-fast-latency-ns "${HMAT_FAST_LATENCY_NS}")
  args+=(--hmat-slow-latency-ns "${HMAT_SLOW_LATENCY_NS}")
  args+=(--hmat-fast-bandwidth "${HMAT_FAST_BANDWIDTH}")
  args+=(--hmat-slow-bandwidth "${HMAT_SLOW_BANDWIDTH}")
  [[ -z "${CXL_FMW_SIZE:-}" ]] || args+=(--cxl-fmw-size "${CXL_FMW_SIZE}")

  vmctl_cmd "${args[@]}"
  wait_for_vm_ssh
  if [[ "${VERIFY_PLACEMENT}" == "1" ]]; then
    verify_vm_placement
  fi
}

wait_for_vm_ssh() {
  vm_ssh_args
  vmctl_cmd wait-ssh "${VM_SSH_ARGS[@]}"
}

verify_vm_placement() {
  vm_ssh_args
  vmctl_cmd verify-placement "${VM_SSH_ARGS[@]}"
}

run_guest_suite() {
  vm_ssh_args
  local guest_cmd
  printf -v guest_cmd \
    'OUTROOT=%q WORKLOADS=%q POLICIES=%q CAPS=%q MODE=%q PR_ITERATIONS=%q PR_TRIALS=%q TIMEOUT_SEC=%q OMP_THREADS=%q WINDOW_SEC=2 MIN_ARM_WINDOWS=1 MAX_ARM_WINDOWS=2 OBSERVE_WINDOWS=1 /root/scripts/run_workload_suite_guest.sh' \
    "${GUEST_OUTROOT}" "${WORKLOADS}" "${GUEST_POLICIES}" "${GUEST_CAPS}" \
    "${GUEST_MODE}" "${PR_ITERATIONS}" "${PR_TRIALS}" \
    "${GUEST_TIMEOUT_SEC}" "${GUEST_OMP_THREADS}"
  vmctl_cmd ssh "${VM_SSH_ARGS[@]}" -- "${guest_cmd}"
  vmctl_cmd ssh "${VM_SSH_ARGS[@]}" -- "cat $(printf '%q' "${GUEST_OUTROOT}")/summary.csv"
}

stop_vm_if_requested() {
  [[ "${STOP_VM_ON_SUCCESS}" == "1" ]] || return 0
  vmctl_cmd stop --name "${VM_NAME}"
}

remote() {
  ssh "${SSH_OPTS[@]}" "root@${HOST}" "$@"
}

copy_file() {
  local src="$1"
  local dst="$2"
  if [[ ! -e "${src}" ]]; then
    echo "missing local file: ${src}" >&2
    return 1
  fi
  remote "mkdir -p '$(dirname "${dst}")'"
  scp "${SCP_OPTS[@]}" "${src}" "root@${HOST}:${dst}" >/dev/null
}

stream_dir() {
  local src="$1"
  local dst_parent="$2"
  if [[ ! -d "${src}" ]]; then
    echo "missing local directory: ${src}" >&2
    return 1
  fi
  remote "mkdir -p '${dst_parent}'"
  tar -C "$(dirname "${src}")" -czf - "$(basename "${src}")" | \
    ssh "${SSH_OPTS[@]}" "root@${HOST}" "tar -xzf - -C '${dst_parent}'"
}

stream_dir_filtered() {
  local src="$1"
  local dst_parent="$2"
  shift 2
  if [[ ! -d "${src}" ]]; then
    echo "missing local directory: ${src}" >&2
    return 1
  fi
  remote "mkdir -p '${dst_parent}'"
  local -a tar_args=(-C "$(dirname "${src}")")
  tar_args+=("$@")
  tar_args+=(-czf - "$(basename "${src}")")
  tar "${tar_args[@]}" | \
    ssh "${SSH_OPTS[@]}" "root@${HOST}" "tar --no-same-owner --no-same-permissions -xzf - -C '${dst_parent}'"
}

stream_files_from_benchmark() {
  remote "mkdir -p /root/benchmark"
  tar -C "${BENCHMARK_DIR}" -czf - "$@" | \
    ssh "${SSH_OPTS[@]}" "root@${HOST}" "tar -xzf - -C /root/benchmark"
}

stream_ycsb_binding() {
  local binding="$1"
  local tarball="${BENCHMARK_DIR}/YCSB/${binding}/target/ycsb-${binding}-binding-0.18.0-SNAPSHOT.tar.gz"
  local dst="/root/benchmark/ycsb-${binding}"
  if [[ "${binding}" == "memcached" ]]; then
    local jar="${BENCHMARK_DIR}/YCSB/memcached/target/memcached-binding-0.18.0-SNAPSHOT.jar"
    if [[ ! -f "${jar}" ]]; then
      echo "missing YCSB memcached jar: ${jar}" >&2
      return 1
    fi
    remote "rm -rf '${dst}' && mkdir -p '${dst}/memcached-binding/lib'"
    tar -C "${BENCHMARK_DIR}/YCSB" -czf - bin workloads LICENSE.txt NOTICE.txt | \
      ssh "${SSH_OPTS[@]}" "root@${HOST}" "tar -xzf - -C '${dst}'"
    tar -C "${BENCHMARK_DIR}/YCSB/memcached/target" -czf - \
      memcached-binding-0.18.0-SNAPSHOT.jar dependency | \
      ssh "${SSH_OPTS[@]}" "root@${HOST}" "\
        tmp=\$(mktemp -d) && \
        tar -xzf - -C \"\$tmp\" && \
        mv \"\$tmp\"/memcached-binding-0.18.0-SNAPSHOT.jar '${dst}/memcached-binding/lib/' && \
        find \"\$tmp\"/dependency -type f -name '*.jar' -exec mv {} '${dst}/memcached-binding/lib/' \\; && \
        rm -rf \"\$tmp\""
    remote "chmod +x '${dst}/bin/ycsb'"
    return 0
  fi
  if [[ ! -f "${tarball}" ]]; then
    echo "missing YCSB ${binding} tarball: ${tarball}" >&2
    return 1
  fi
  remote "rm -rf '${dst}' && mkdir -p '${dst}'"
  cat "${tarball}" | ssh "${SSH_OPTS[@]}" "root@${HOST}" \
    "tar -xzf - -C '${dst}' --strip-components=1 && chmod +x '${dst}/bin/ycsb'"
}

ensure_gapbs_graph_host() {
  if [[ -s "${GAPBS_GRAPH_HOST}" ]]; then
    return 0
  fi

  local converter="${BENCHMARK_DIR}/gapbs/converter"
  [[ -x "${converter}" ]] || die "missing GAPBS converter: ${converter}"
  mkdir -p "$(dirname -- "${GAPBS_GRAPH_HOST}")"
  echo "build GAPBS graph g${GAPBS_GRAPH_SCALE}: ${GAPBS_GRAPH_HOST}"
  (
    cd "${BENCHMARK_DIR}/gapbs"
    env OMP_NUM_THREADS="${GUEST_OMP_THREADS}" OMP_PROC_BIND=true OMP_PLACES=cores \
      "${converter}" -g"${GAPBS_GRAPH_SCALE}" -b "${GAPBS_GRAPH_HOST}"
  )
  [[ -s "${GAPBS_GRAPH_HOST}" ]] || die "GAPBS graph build did not create ${GAPBS_GRAPH_HOST}"
}

stage_gapbs_graph() {
  ensure_gapbs_graph_host
  local expected_size
  expected_size="$(stat -c '%s' "${GAPBS_GRAPH_HOST}")"

  if remote "actual=\$(stat -c '%s' '${GAPBS_GRAPH_GUEST}' 2>/dev/null || echo 0); test \"\$actual\" = '${expected_size}'"; then
    return 0
  fi

  remote "rm -f '${GAPBS_GRAPH_GUEST}'"
  copy_file "${GAPBS_GRAPH_HOST}" "${GAPBS_GRAPH_GUEST}"
  remote "actual=\$(stat -c '%s' '${GAPBS_GRAPH_GUEST}' 2>/dev/null || echo 0); test \"\$actual\" = '${expected_size}'" || {
    echo "GAPBS graph staging failed: expected ${expected_size} bytes at ${GAPBS_GRAPH_GUEST}" >&2
    return 1
  }
}

expand_workloads() {
  local out=()
  local w
  for w in "$@"; do
    case "${w}" in
      core)
        out+=(
          redis_uniform redis_ycsb_a rocksdb_ycsb_uniform memcached_ycsb_uniform
          faster_uniform faster_ycsb_a dlrm_synth npb_cg npb_mg npb_ua
          spec_bwaves canneal_synth
        )
        ;;
      scalable)
        out+=(
          redis_uniform redis_ycsb_a rocksdb_ycsb_uniform memcached_ycsb_uniform
          faster_uniform faster_ycsb_a dlrm_synth
        )
        ;;
      candidate|candidates)
        out+=(pr bc gups graph500 btree xsbench gapbs_bfs gapbs_cc gapbs_sssp)
        ;;
      all)
        out+=(
          redis_uniform redis_ycsb_a rocksdb_ycsb_uniform memcached_ycsb_uniform
          faster_uniform faster_ycsb_a dlrm_synth npb_cg npb_mg npb_ua
          spec_bwaves spec_fotonik3d spec_roms canneal_synth
          hibench_repartition hibench_sql_join cloudsuite_data_caching
          cloudsuite_web_search cloudsuite_als duckdb_tpch clickbench hnsw_faiss
          pr bc gups graph500 btree xsbench gapbs_bfs gapbs_cc gapbs_sssp
        )
        ;;
      *)
        out+=("${w}")
        ;;
    esac
  done
  printf '%s\n' "${out[@]}" | awk '!seen[$0]++'
}

needs_jdk() {
  local w="$1"
  case "${w}" in
    redis_ycsb_a|rocksdb_ycsb_uniform|memcached_ycsb_uniform|hibench_*|cloudsuite_als)
      return 0
      ;;
  esac
  return 1
}

needs_dotnet() {
  local w="$1"
  case "${w}" in
    faster_uniform|faster_ycsb_a)
      return 0
      ;;
  esac
  return 1
}

needs_jdk17() {
  local w="$1"
  case "${w}" in
    rocksdb_ycsb_uniform)
      return 0
      ;;
  esac
  return 1
}

stage_common_scripts() {
  remote "mkdir -p /root/scripts /root/benchmark /root/tools /root/realworld-work"
  if [[ "${CLEAN_SCRIPTS}" == "1" ]]; then
    remote "find /root/scripts -mindepth 1 -maxdepth 1 -type f -delete"
  fi
  copy_file "${SCRIPT_DIR}/run_ours_experiment.sh" \
    /root/scripts/run_ours_experiment.sh
  copy_file "${SCRIPT_DIR}/local_util_adapt_controller.py" \
    /root/scripts/local_util_adapt_controller.py
  copy_file "${SCRIPT_DIR}/iccd_experiment_defaults.sh" \
    /root/scripts/iccd_experiment_defaults.sh
  copy_file "${SCRIPT_DIR}/run_workload_suite_guest.sh" \
    /root/scripts/run_workload_suite_guest.sh
  copy_file "${SCRIPT_DIR}/run_workload_case_guest.sh" \
    /root/scripts/run_workload_case_guest.sh
  remote "chmod +x /root/scripts/run_ours_experiment.sh /root/scripts/local_util_adapt_controller.py /root/scripts/run_workload_suite_guest.sh /root/scripts/run_workload_case_guest.sh"
}

stage_jdk8() {
  if remote "test -x /root/tools/jdk8/bin/java"; then
    echo "skip existing /root/tools/jdk8"
    return 0
  fi
  echo "stage jdk8"
  stream_dir "${BENCHMARK_DIR}/HiBench/.tools/jdk8" /root/tools
}

stage_dotnet7() {
  if remote "test -x /root/tools/dotnet7/dotnet"; then
    echo "skip existing /root/tools/dotnet7"
    return 0
  fi
  echo "stage dotnet7"
  stream_dir "${BENCHMARK_DIR}/.tools/dotnet7" /root/tools
}

stage_jdk17() {
  if remote "test -x /root/tools/jdk17/bin/java"; then
    echo "skip existing /root/tools/jdk17"
    return 0
  fi
  echo "stage jdk17"
  stream_dir /usr/lib/jvm/java-17-openjdk-amd64 /root/tools
  stream_dir /etc/java-17-openjdk /etc
  remote "ln -sfn /root/tools/java-17-openjdk-amd64 /root/tools/jdk17"
}

stage_redis() {
  if remote "test -x /root/benchmark/redis/src/redis-server && test -x /root/benchmark/redis/src/redis-benchmark && test -x /root/benchmark/redis/src/redis-cli"; then
    echo "skip existing redis"
    return 0
  fi
  echo "stage redis source/binaries"
  stream_dir_filtered "${BENCHMARK_DIR}/redis" /root/benchmark \
    --exclude=redis/.git \
    --exclude=redis/.git/\*
  remote "cd /root/benchmark/redis && (make distclean || make clean || true); find src deps -type f \\( -name '*.o' -o -name '*.a' -o -name '*.so' \\) -delete; make -j\"\$(nproc)\" BUILD_TLS=no MALLOC=libc; test -x src/redis-server && test -x src/redis-benchmark && test -x src/redis-cli && chmod +x src/redis-server src/redis-benchmark src/redis-cli"
}

stage_memcached() {
  if remote "command -v memcached >/dev/null 2>&1 || test -x /root/benchmark/memcached/memcached"; then
    echo "skip existing memcached"
    return 0
  fi
  echo "stage memcached binary"
  copy_file /usr/bin/memcached /root/benchmark/memcached/memcached
  remote "chmod +x /root/benchmark/memcached/memcached"
}

stage_ycsb() {
  local binding="$1"
  echo "stage ycsb ${binding}"
  stream_ycsb_binding "${binding}"
}

stage_faster() {
  if remote "test -f /root/benchmark/FASTER/cs/benchmark/bin/x64/Release/net7.0/FASTER.benchmark.dll"; then
    echo "skip existing FASTER benchmark"
    return 0
  fi
  echo "stage FASTER source/binaries"
  stream_dir_filtered "${BENCHMARK_DIR}/FASTER" /root/benchmark \
    --exclude=FASTER/.git \
    --exclude=FASTER/.git/\*
  remote "test -f /root/benchmark/FASTER/cs/benchmark/bin/x64/Release/net7.0/FASTER.benchmark.dll && chmod +x /root/benchmark/FASTER/cs/benchmark/bin/x64/Release/net7.0/FASTER.benchmark 2>/dev/null || true"
}

stage_dlrm() {
  echo "stage DLRM source"
  remote "rm -rf /root/benchmark/DLRM"
  stream_dir "${BENCHMARK_DIR}/DLRM" /root/benchmark
  if [[ "${STAGE_DLRM_VENV}" == "1" ]]; then
    echo "stage DLRM Python venv"
    copy_file /usr/bin/python3.10 /usr/bin/python3.10
    stream_dir /usr/lib/python3.10 /usr/lib
    stream_dir "${BENCHMARK_DIR}/.tools/dlrm-venv" /root/tools
    remote "ln -sfn /usr/bin/python3.10 /root/tools/dlrm-venv/bin/python3 && ln -sfn python3 /root/tools/dlrm-venv/bin/python && ln -sfn python3 /root/tools/dlrm-venv/bin/python3.10"
  else
    echo "skip DLRM venv because STAGE_DLRM_VENV=0"
  fi
}

stage_npb_extra() {
  echo "stage NPB CG/MG/UA"
  stream_files_from_benchmark \
    NPB3.4.3/NPB3.4-OMP/bin/cg.D.x \
    NPB3.4.3/NPB3.4-OMP/bin/mg.D.x \
    NPB3.4.3/NPB3.4-OMP/bin/ua.D.x
  remote "chmod +x /root/benchmark/NPB3.4.3/NPB3.4-OMP/bin/cg.D.x /root/benchmark/NPB3.4.3/NPB3.4-OMP/bin/mg.D.x /root/benchmark/NPB3.4.3/NPB3.4-OMP/bin/ua.D.x"
}

stage_spec() {
  local spec="$1"
  case "${spec}" in
    spec_bwaves)
      echo "stage SPEC 603.bwaves_s runnable refspeed directory"
      remote "mkdir -p /root/benchmark/spec/603.bwaves_s/run"
      stream_dir "${BENCHMARK_DIR}/spec/benchspec/CPU/603.bwaves_s/run/run_base_refspeed_mytest-m64.0000" \
        /root/benchmark/spec/603.bwaves_s/run
      ;;
    spec_fotonik3d)
      echo "stage SPEC 649.fotonik3d_s binary/source snapshot; ref input is not present locally"
      remote "mkdir -p /root/benchmark/spec"
      stream_dir "${BENCHMARK_DIR}/spec/benchspec/CPU/649.fotonik3d_s" /root/benchmark/spec
      ;;
    spec_roms)
      echo "stage SPEC 654.roms_s binary/source snapshot; complete ref run directory is not present locally"
      remote "mkdir -p /root/benchmark/spec"
      stream_dir "${BENCHMARK_DIR}/spec/benchspec/CPU/654.roms_s" /root/benchmark/spec
      ;;
  esac
}

stage_canneal() {
  echo "stage canneal binary"
  stream_files_from_benchmark vmitosis-workloads/bin/bench_canneal_mt
  remote "chmod +x /root/benchmark/vmitosis-workloads/bin/bench_canneal_mt"
}

stage_gapbs_source() {
  if remote "test -x /root/benchmark/gapbs/pr && test -x /root/benchmark/gapbs/bc"; then
    echo "skip existing GAPBS pr/bc"
    return 0
  fi
  echo "stage GAPBS source/binaries without graph cache"
  stream_dir_filtered "${BENCHMARK_DIR}/gapbs" /root/benchmark \
    --exclude=gapbs/.git \
    --exclude=gapbs/.git/\* \
    --exclude=gapbs/benchmark/graphs \
    --exclude=gapbs/benchmark/graphs/\*
  remote "cd /root/benchmark/gapbs && (make -j\"\$(nproc)\" pr bc || true); test -x pr && test -x bc && chmod +x pr bc"
}

stage_vmitosis_workloads() {
  if remote "test -x /root/benchmark/vmitosis-workloads/bin/bench_gups_mt && test -x /root/benchmark/vmitosis-workloads/bin/bench_graph500_mt && test -x /root/benchmark/vmitosis-workloads/bin/bench_btree_mt"; then
    echo "skip existing vmitosis microbench binaries"
    return 0
  fi
  echo "stage vmitosis-workloads source/binaries"
  stream_dir_filtered "${BENCHMARK_DIR}/vmitosis-workloads" /root/benchmark \
    --exclude=vmitosis-workloads/.git \
    --exclude=vmitosis-workloads/.git/\*
  remote "cd /root/benchmark/vmitosis-workloads && (make -j\"\$(nproc)\" gups graph500 btree || true); test -x bin/bench_gups_mt && test -x bin/bench_graph500_mt && test -x bin/bench_btree_mt && chmod +x bin/bench_gups_mt bin/bench_graph500_mt bin/bench_btree_mt"
}

stage_silo() {
  echo "stage Silo source/binaries"
  remote "if test -f /usr/lib/x86_64-linux-gnu/liblz4.so.1 && ! test -e /usr/lib/x86_64-linux-gnu/liblz4.so; then ln -s liblz4.so.1 /usr/lib/x86_64-linux-gnu/liblz4.so; fi"
  if remote "test -x /root/benchmark/silo/out-perf.masstree/benchmarks/dbtest && ldd /root/benchmark/silo/out-perf.masstree/benchmarks/dbtest >/dev/null 2>&1"; then
    echo "skip existing Silo dbtest"
    return 0
  fi
  if ! remote "test -d /root/benchmark/silo && test -f /root/benchmark/silo/Makefile"; then
    stream_dir_filtered "${BENCHMARK_DIR}/silo" /root/benchmark \
      --exclude=silo/.git \
      --exclude=silo/.git/\*
  fi
  remote "if ! test -e /usr/lib/x86_64-linux-gnu/liblz4.so && test -f /root/benchmark/silo/third-party/lz4/liblz4.so; then cp /root/benchmark/silo/third-party/lz4/liblz4.so /usr/local/lib/liblz4.so && ldconfig; fi"
  if remote "test -x /root/benchmark/silo/out-perf.masstree/benchmarks/dbtest && ldd /root/benchmark/silo/out-perf.masstree/benchmarks/dbtest >/dev/null 2>&1"; then
    echo "skip existing Silo dbtest after loader repair"
    return 0
  fi
  remote "cd /root/benchmark/silo && rm -rf out-perf.masstree && make -j\"\$(nproc)\" dbtest MYSQL=0 USE_MALLOC_MODE=0; test -x out-perf.masstree/benchmarks/dbtest && ldd out-perf.masstree/benchmarks/dbtest >/dev/null 2>&1 && chmod +x out-perf.masstree/benchmarks/dbtest"
}

stage_liblinear() {
  local dataset_host="${BENCHMARK_DIR}/liblinear-multicore-2.47/datasets/${LIBLINEAR_DATASET:-kdd12}"
  local dataset_guest="/root/benchmark/liblinear-multicore-2.47/datasets/${LIBLINEAR_DATASET:-kdd12}"

  if ! remote "test -x /root/benchmark/liblinear-multicore-2.47/train"; then
    echo "stage Liblinear source/binaries without datasets"
    stream_dir_filtered "${BENCHMARK_DIR}/liblinear-multicore-2.47" /root/benchmark \
      --exclude=liblinear-multicore-2.47/.git \
      --exclude=liblinear-multicore-2.47/.git/\* \
      --exclude=liblinear-multicore-2.47/datasets \
      --exclude=liblinear-multicore-2.47/datasets/\*
    remote "cd /root/benchmark/liblinear-multicore-2.47 && (make -j\"\$(nproc)\" train || true); test -x train && chmod +x train"
  else
    echo "skip existing Liblinear train"
  fi

  [[ -f "${dataset_host}" ]] || {
    echo "missing Liblinear dataset: ${dataset_host}" >&2
    return 1
  }
  local expected_size
  expected_size="$(stat -c '%s' "${dataset_host}")"
  if remote "actual=\$(stat -c '%s' '${dataset_guest}' 2>/dev/null || echo 0); test \"\$actual\" = '${expected_size}'"; then
    echo "skip existing Liblinear dataset ${LIBLINEAR_DATASET:-kdd12}"
    return 0
  fi
  echo "stage Liblinear dataset ${LIBLINEAR_DATASET:-kdd12}"
  remote "mkdir -p /root/benchmark/liblinear-multicore-2.47/datasets"
  copy_file "${dataset_host}" "${dataset_guest}"
  remote "actual=\$(stat -c '%s' '${dataset_guest}' 2>/dev/null || echo 0); test \"\$actual\" = '${expected_size}'"
}

stage_candidate_microbench() {
  local w="$1"
  remote "mkdir -p /root/benchmark/vmitosis-workloads/bin /root/benchmark/XSBench/openmp-threading /root/benchmark/gapbs /root/gapbs_graphs"
  case "${w}" in
    pr|bc)
      stage_gapbs_source
      if [[ "${STAGE_GAPBS_GRAPH}" == "1" ]]; then
        stage_gapbs_graph
      else
        echo "skip GAPBS graph staging; guest graph path is external: ${GAPBS_GRAPH_GUEST}"
      fi
      ;;
    gups|graph500|btree)
      stage_vmitosis_workloads
      ;;
    xsbench)
      copy_file "${BENCHMARK_DIR}/XSBench/openmp-threading/XSBench" \
        /root/benchmark/XSBench/openmp-threading/XSBench
      remote "chmod +x /root/benchmark/XSBench/openmp-threading/XSBench"
      ;;
    gapbs_bfs|gapbs_cc|gapbs_sssp)
      stage_gapbs_source
      remote "cd /root/benchmark/gapbs && (make -j\"\$(nproc)\" '${w#gapbs_}' || true); test -x '${w#gapbs_}' && chmod +x '${w#gapbs_}'"
      if [[ "${STAGE_GAPBS_GRAPH}" == "1" ]]; then
        stage_gapbs_graph
      else
        echo "skip GAPBS graph staging; guest graph path is external: ${GAPBS_GRAPH_GUEST}"
      fi
      ;;
  esac
}

stage_framework_placeholder() {
  local w="$1"
  if [[ "${STAGE_FRAMEWORKS}" != "1" ]]; then
    echo "skip ${w}: framework/data staging disabled; runner will report rc=77"
    return 0
  fi
  case "${w}" in
    hibench_repartition|hibench_sql_join)
      echo "stage HiBench tree"
      stream_dir "${BENCHMARK_DIR}/HiBench" /root/benchmark
      ;;
    cloudsuite_data_caching|cloudsuite_web_search|cloudsuite_als)
      echo "stage CloudSuite scripts only; Docker images/datasets still need explicit preparation"
      stream_dir "${BENCHMARK_DIR}/cloudsuite" /root/benchmark
      ;;
  esac
}

stage_workload() {
  local w="$1"
  case "${w}" in
    redis_uniform)
      stage_redis
      ;;
    redis_ycsb_a)
      stage_redis
      stage_ycsb redis
      ;;
    rocksdb_ycsb_uniform)
      stage_ycsb rocksdb
      ;;
    memcached_ycsb_uniform)
      stage_memcached
      stage_ycsb memcached
      ;;
    faster_uniform|faster_ycsb_a)
      stage_faster
      ;;
    dlrm_synth)
      stage_dlrm
      ;;
    npb_cg|npb_mg|npb_ua)
      stage_npb_extra
      ;;
    spec_bwaves|spec_fotonik3d|spec_roms)
      stage_spec "${w}"
      ;;
    canneal_synth)
      stage_canneal
      ;;
    silo)
      stage_silo
      ;;
    liblinear)
      stage_liblinear
      ;;
    pr|bc|gups|graph500|btree|xsbench|gapbs_bfs|gapbs_cc|gapbs_sssp)
      stage_candidate_microbench "${w}"
      ;;
    hibench_repartition|hibench_sql_join|cloudsuite_data_caching|cloudsuite_web_search|cloudsuite_als)
      stage_framework_placeholder "${w}"
      ;;
    duckdb_tpch|clickbench|hnsw_faiss)
      echo "skip ${w}: external install/data recipe only; runner will report rc=77"
      ;;
    *)
      echo "unknown workload: ${w}" >&2
      return 1
      ;;
  esac
}

stage_selected_workloads() {
  if [[ "${CLEAN}" == "1" ]]; then
    remote "rm -rf /root/benchmark /root/tools/dotnet7 /root/tools/dlrm-venv /root/realworld-work && mkdir -p /root/benchmark /root/tools /root/realworld-work"
  fi

  mapfile -t workload_list < <(expand_workloads ${WORKLOADS})

  stage_common_scripts

  for w in "${workload_list[@]}"; do
    if needs_jdk "${w}"; then
      if [[ "${STAGE_JDK}" == "1" || "${STAGE_JDK}" == "auto" ]]; then
        stage_jdk8
      fi
    fi
    if needs_dotnet "${w}"; then
      if [[ "${STAGE_DOTNET}" == "1" || "${STAGE_DOTNET}" == "auto" ]]; then
        stage_dotnet7
      fi
    fi
    if needs_jdk17 "${w}"; then
      if [[ "${STAGE_JDK17}" == "1" || "${STAGE_JDK17}" == "auto" ]]; then
        stage_jdk17
      fi
    fi
    stage_workload "${w}"
  done

  remote "rm -f /etc/ld.so.conf.d/iccd-realworld-deps.conf 2>/dev/null || true"

  remote "df -h / /root 2>/dev/null || true; du -sh /root/benchmark /root/tools /root/realworld-work 2>/dev/null || true; find /root/scripts -maxdepth 1 -type f -printf '%p\n' | sort"
}

case "${VM_ACTION}" in
  stage|boot-stage|pr-smoke)
    boot_vm_if_requested
    if [[ "${VM_ACTION}" == "stage" && "${VERIFY_PLACEMENT}" == "1" && -x "${VMCTL}" ]]; then
      verify_vm_placement || true
    fi
    stage_selected_workloads
    if [[ "${VM_ACTION}" == "pr-smoke" ]]; then
      run_guest_suite
      stop_vm_if_requested
    fi
    ;;
  wait)
    wait_for_vm_ssh
    ;;
  verify)
    verify_vm_placement
    ;;
  stop)
    vmctl_cmd stop --name "${VM_NAME}"
    ;;
  *)
    die "unknown VM_ACTION=${VM_ACTION}; expected stage, boot-stage, pr-smoke, wait, verify, or stop"
    ;;
esac
