#!/usr/bin/env bash
set -euo pipefail

WORKLOAD="${1:-}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BENCHMARK_DIR="${BENCHMARK_DIR:-/root/benchmark}"
TOOLS_DIR="${TOOLS_DIR:-/root/tools}"
BENCH_TOOLS_DIR="${BENCH_TOOLS_DIR:-${BENCHMARK_DIR}/.tools}"
WORKDIR="${WORKDIR:-/root/realworld-work}"
OMP_THREADS="${OMP_THREADS:-32}"

realworld_apply_rss60_profile() {
  local workload="$1"

  case "${workload}" in
    redis_uniform)
      : "${REDIS_KEYSPACE:=2000000}"
      : "${REDIS_LOAD_REQUESTS:=5000000}"
      : "${REDIS_RUN_REQUESTS:=1000000}"
      : "${REDIS_VALUE_SIZE:=32768}"
      : "${REDIS_CLIENTS:=128}"
      : "${REDIS_TESTS:=get,set}"
      export REDIS_KEYSPACE REDIS_LOAD_REQUESTS REDIS_RUN_REQUESTS
      export REDIS_VALUE_SIZE REDIS_CLIENTS REDIS_TESTS
      ;;
    redis_ycsb_a)
      : "${YCSB_RECORDCOUNT:=1600000}"
      : "${YCSB_OPERATIONCOUNT:=7000000}"
      : "${YCSB_FIELDCOUNT:=10}"
      : "${YCSB_FIELDLENGTH:=4096}"
      : "${YCSB_HEAP:=8g}"
      : "${YCSB_WORKLOAD:=workloada}"
      : "${YCSB_DISTRIBUTION:=uniform}"
      export YCSB_RECORDCOUNT YCSB_OPERATIONCOUNT YCSB_FIELDCOUNT
      export YCSB_FIELDLENGTH YCSB_HEAP YCSB_WORKLOAD YCSB_DISTRIBUTION
      ;;
    rocksdb_ycsb_uniform)
      : "${YCSB_RECORDCOUNT:=1600000}"
      : "${YCSB_OPERATIONCOUNT:=500000}"
      : "${YCSB_FIELDCOUNT:=10}"
      : "${YCSB_FIELDLENGTH:=4096}"
      : "${YCSB_HEAP:=8g}"
      : "${YCSB_WORKLOAD:=workloadc}"
      : "${ROCKSDB_DIR:=/dev/shm/rocksdb-data-rss60}"
      : "${ROCKSDB_SHM_SIZE:=96G}"
      export YCSB_RECORDCOUNT YCSB_OPERATIONCOUNT YCSB_FIELDCOUNT
      export YCSB_FIELDLENGTH YCSB_HEAP YCSB_WORKLOAD ROCKSDB_DIR
      export ROCKSDB_SHM_SIZE
      ;;
    memcached_ycsb_uniform)
      : "${MEMCACHED_MEMORY_MB:=73728}"
      : "${YCSB_RECORDCOUNT:=1600000}"
      : "${YCSB_OPERATIONCOUNT:=2000000}"
      : "${YCSB_FIELDCOUNT:=10}"
      : "${YCSB_FIELDLENGTH:=4096}"
      : "${YCSB_HEAP:=8g}"
      : "${YCSB_WORKLOAD:=workloada}"
      export MEMCACHED_MEMORY_MB YCSB_RECORDCOUNT YCSB_OPERATIONCOUNT
      export YCSB_FIELDCOUNT YCSB_FIELDLENGTH YCSB_HEAP YCSB_WORKLOAD
      ;;
    faster_uniform|faster_ycsb_a)
      : "${FASTER_RUNSEC:=210}"
      : "${FASTER_ITERATIONS:=1}"
      : "${FASTER_DISTRIBUTION:=uniform}"
      export FASTER_RUNSEC FASTER_ITERATIONS FASTER_DISTRIBUTION
      ;;
    dlrm_synth)
      : "${DLRM_TABLES:=8}"
      : "${DLRM_ROWS_PER_TABLE:=42000000}"
      : "${DLRM_SPARSE_FEATURE:=64}"
      : "${DLRM_MINI_BATCH:=16}"
      : "${DLRM_NUM_BATCHES:=2}"
      : "${DLRM_INDICES_PER_LOOKUP:=100}"
      export DLRM_TABLES DLRM_ROWS_PER_TABLE DLRM_SPARSE_FEATURE
      export DLRM_MINI_BATCH DLRM_NUM_BATCHES DLRM_INDICES_PER_LOOKUP
      ;;
    canneal_synth)
      : "${CANNEAL_ELEMENTS:=5000000}"
      : "${CANNEAL_GRID_X:=4096}"
      : "${CANNEAL_GRID_Y:=4096}"
      : "${CANNEAL_FANIN:=4}"
      : "${CANNEAL_SWAPS:=1000000}"
      export CANNEAL_ELEMENTS CANNEAL_GRID_X CANNEAL_GRID_Y
      export CANNEAL_FANIN CANNEAL_SWAPS
      ;;
  esac
}

realworld_dump_profile_env() {
  env | LC_ALL=C sort | grep -E '^(REDIS_|YCSB_|MEMCACHED_|FASTER_|DLRM_|CANNEAL_|ROCKSDB_|SPEC2017_)' || true
}

if [[ "${REALWORLD_SIZE_PROFILE:-}" == "rss60" ]]; then
  realworld_apply_rss60_profile "${WORKLOAD}"
fi

mkdir -p "${WORKDIR}"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

if [[ "${REALWORLD_SIZE_PROFILE:-}" == "rss60" ]]; then
  log "realworld rss60 profile env"
  realworld_dump_profile_env >&2
fi

need_exec() {
  local path="$1"
  if [[ ! -x "${path}" ]]; then
    echo "missing executable: ${path}" >&2
    exit 77
  fi
}

need_file() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    echo "missing file: ${path}" >&2
    exit 77
  fi
}

resolve_exec() {
  local label="$1"
  shift
  local path
  for path in "$@"; do
    if [[ -n "${path}" && -x "${path}" ]]; then
      printf '%s\n' "${path}"
      return 0
    fi
  done
  if command -v "${label}" >/dev/null 2>&1; then
    command -v "${label}"
    return 0
  fi
  echo "missing executable for ${label}: $*" >&2
  exit 77
}

resolve_file() {
  local label="$1"
  shift
  local path
  for path in "$@"; do
    if [[ -n "${path}" && -f "${path}" ]]; then
      printf '%s\n' "${path}"
      return 0
    fi
  done
  echo "missing file for ${label}: $*" >&2
  exit 77
}

resolve_dir() {
  local label="$1"
  shift
  local path
  for path in "$@"; do
    if [[ -n "${path}" && -d "${path}" ]]; then
      printf '%s\n' "${path}"
      return 0
    fi
  done
  echo "missing directory for ${label}: $*" >&2
  exit 77
}

wait_tcp() {
  local port="$1"
  local deadline=$((SECONDS + 60))
  until bash -c ":</dev/tcp/127.0.0.1/${port}" >/dev/null 2>&1; do
    if (( SECONDS > deadline )); then
      echo "timeout waiting for 127.0.0.1:${port}" >&2
      return 1
    fi
    sleep 1
  done
}

start_redis() {
  REDIS_PORT="${REDIS_PORT:-6380}"
  REDIS_DIR="${WORKDIR}/redis-${REDIS_PORT}"
  REDIS_PIDFILE="${REDIS_DIR}/redis.pid"
  mkdir -p "${REDIS_DIR}"
  local redis_server
  redis_server="$(resolve_exec redis-server "${REDIS_SERVER_BIN:-}" "${BENCHMARK_DIR}/redis/src/redis-server")"
  "${redis_server}" \
    --bind 127.0.0.1 \
    --protected-mode no \
    --port "${REDIS_PORT}" \
    --save "" \
    --appendonly no \
    --daemonize yes \
    --pidfile "${REDIS_PIDFILE}" \
    --dir "${REDIS_DIR}" \
    --dbfilename dump.rdb \
    --logfile "${REDIS_DIR}/redis.log" \
    --maxmemory 0 \
    --io-threads "${REDIS_IO_THREADS:-1}"
  wait_tcp "${REDIS_PORT}"
}

stop_redis() {
  local redis_cli="${REDIS_CLI_BIN:-${BENCHMARK_DIR}/redis/src/redis-cli}"
  if [[ ! -x "${redis_cli}" ]]; then
    redis_cli="$(command -v redis-cli || true)"
  fi
  if [[ -n "${REDIS_PORT:-}" && -x "${redis_cli}" ]]; then
    "${redis_cli}" -p "${REDIS_PORT}" shutdown nosave >/dev/null 2>&1 || true
  fi
  if [[ -n "${REDIS_PIDFILE:-}" && -f "${REDIS_PIDFILE}" ]]; then
    kill "$(cat "${REDIS_PIDFILE}")" >/dev/null 2>&1 || true
  fi
}

start_memcached() {
  MEMCACHED_PORT="${MEMCACHED_PORT:-11211}"
  MEMCACHED_MEMORY_MB="${MEMCACHED_MEMORY_MB:-49152}"
  MEMCACHED_PIDFILE="${WORKDIR}/memcached-${MEMCACHED_PORT}.pid"
  local memcached
  memcached="$(resolve_exec memcached "${MEMCACHED_BIN:-}" "${BENCHMARK_DIR}/memcached/memcached" /usr/bin/memcached)"
  "${memcached}" \
    -u root \
    -l 127.0.0.1 \
    -p "${MEMCACHED_PORT}" \
    -m "${MEMCACHED_MEMORY_MB}" \
    -t "${MEMCACHED_THREADS:-${OMP_THREADS}}" \
    -I "${MEMCACHED_ITEM_MAX:-32m}" \
    -P "${MEMCACHED_PIDFILE}" \
    -d
  wait_tcp "${MEMCACHED_PORT}"
}

stop_memcached() {
  if [[ -n "${MEMCACHED_PIDFILE:-}" && -f "${MEMCACHED_PIDFILE}" ]]; then
    local pid
    pid="$(cat "${MEMCACHED_PIDFILE}")"
    kill "${pid}" >/dev/null 2>&1 || true
    for _ in {1..20}; do
      if ! kill -0 "${pid}" >/dev/null 2>&1; then
        return 0
      fi
      sleep 0.1
    done
    kill -9 "${pid}" >/dev/null 2>&1 || true
  fi
}

ycsb_bin() {
  local binding="$1"
  local root
  root="$(ycsb_root "${binding}")"
  printf '%s\n' "${root}/bin/ycsb"
}

ycsb_root() {
  local binding="$1"
  local dir
  for dir in "${YCSB_ROOT:-}" "${BENCHMARK_DIR}/ycsb-${binding}" "${BENCHMARK_DIR}/YCSB"; do
    if [[ -n "${dir}" && -x "${dir}/bin/ycsb" ]]; then
      if [[ "${dir}" == "${BENCHMARK_DIR}/YCSB" && ! -d "${dir}/${binding}" ]]; then
        continue
      fi
      printf '%s\n' "${dir}"
      return 0
    fi
  done
  echo "missing YCSB ${binding} runner under ${BENCHMARK_DIR}/ycsb-${binding} or ${BENCHMARK_DIR}/YCSB" >&2
  exit 77
}

ycsb_workload_file() {
  local binding="$1" workload="$2" root path
  root="$(ycsb_root "${binding}")"
  path="${root}/workloads/${workload}"
  need_file "${path}"
  printf '%s\n' "${path}"
}

ycsb_db_class() {
  case "$1" in
    redis) printf '%s\n' site.ycsb.db.RedisClient ;;
    rocksdb) printf '%s\n' site.ycsb.db.rocksdb.RocksDBClient ;;
    memcached) printf '%s\n' site.ycsb.db.MemcachedClient ;;
    *) echo "unsupported direct YCSB binding: $1" >&2; exit 77 ;;
  esac
}

ycsb_source_classpath() {
  local root="$1" binding="$2" path
  local -a cp_items=()
  cp_items+=("${root}/${binding}/conf" "${root}/core/conf")
  for path in \
    "${root}/core/target"/core-*.jar \
    "${root}/${binding}/target/${binding}-binding-"*.jar \
    "${root}/core/target/dependency/"*.jar \
    "${root}/${binding}/target/dependency/"*.jar
  do
    [[ -e "${path}" ]] && cp_items+=("${path}")
  done
  if (( ${#cp_items[@]} <= 2 )); then
    echo "missing built YCSB jars for ${binding} under ${root}" >&2
    exit 77
  fi
  (IFS=:; printf '%s\n' "${cp_items[*]}")
}

run_ycsb_checked() {
  local binding="$1" phase="$2"
  shift 2
  local errlog rc
  errlog="$(mktemp "${WORKDIR}/ycsb-${binding}-${phase}.stderr.XXXXXX")"

  set +e
  "$@" 2> >(tee "${errlog}" >&2)
  rc=$?
  set -e

  if grep -Eq 'Exception in thread|NoSuchMethodError|RocksDBException|DBException|java\.lang\.[A-Za-z0-9_]+Error' "${errlog}"; then
    log "YCSB ${binding} ${phase} reported a fatal exception; treating the case as failed"
    return 1
  fi
  if grep -Eq '^\[OVERALL\], Throughput\(ops/sec\), 0(\.0+)?([[:space:]]|$)' "${errlog}"; then
    log "YCSB ${binding} ${phase} reported zero throughput; treating the case as failed"
    return 1
  fi
  return "${rc}"
}

run_ycsb() {
  local binding="$1" phase="$2" heap="$3"
  shift 3
  local root
  root="$(ycsb_root "${binding}")"

  if [[ -f "${root}/pom.xml" ]]; then
    local java_bin cp db_class command_flag
    local -a cmd
    java_bin="$(resolve_exec java "${JAVA_HOME:+${JAVA_HOME}/bin/java}")"
    cp="$(ycsb_source_classpath "${root}" "${binding}")"
    db_class="$(ycsb_db_class "${binding}")"
    case "${phase}" in
      load) command_flag="-load" ;;
      run) command_flag="-t" ;;
      *) echo "unknown YCSB phase: ${phase}" >&2; exit 2 ;;
    esac
    cmd=("${java_bin}" "-Xmx${heap}" -cp "${cp}" site.ycsb.Client -db "${db_class}" "$@" "${command_flag}")
    run_ycsb_checked "${binding}" "${phase}" "${cmd[@]}"
  else
    local ycsb
    local -a cmd
    ycsb="${root}/bin/ycsb"
    cmd=("${ycsb}" "${phase}" "${binding}" -jvm-args="-Xmx${heap}" "$@")
    run_ycsb_checked "${binding}" "${phase}" "${cmd[@]}"
  fi
}

java_env() {
  if [[ -n "${YCSB_JAVA_HOME:-}" && -x "${YCSB_JAVA_HOME}/bin/java" ]]; then
    export JAVA_HOME="${YCSB_JAVA_HOME}"
    export PATH="${JAVA_HOME}/bin:${PATH}"
  elif [[ -x "${TOOLS_DIR}/jdk8/bin/java" ]]; then
    export JAVA_HOME="${TOOLS_DIR}/jdk8"
    export PATH="${JAVA_HOME}/bin:${PATH}"
  elif [[ -x "${BENCH_TOOLS_DIR}/jdk8/bin/java" ]]; then
    export JAVA_HOME="${BENCH_TOOLS_DIR}/jdk8"
    export PATH="${JAVA_HOME}/bin:${PATH}"
  elif [[ -x "${BENCH_TOOLS_DIR}/jdk17/bin/java" ]]; then
    export JAVA_HOME="${BENCH_TOOLS_DIR}/jdk17"
    export PATH="${JAVA_HOME}/bin:${PATH}"
  fi
}

run_redis_uniform() {
  trap stop_redis EXIT
  start_redis
  local bench="${BENCHMARK_DIR}/redis/src/redis-benchmark"
  need_exec "${bench}"

  local keyspace="${REDIS_KEYSPACE:-2000000}"
  local load_requests="${REDIS_LOAD_REQUESTS:-3000000}"
  local run_requests="${REDIS_RUN_REQUESTS:-3000000}"
  local value_size="${REDIS_VALUE_SIZE:-16384}"
  local clients="${REDIS_CLIENTS:-128}"
  local threads="${REDIS_CLIENT_THREADS:-${OMP_THREADS}}"
  local tests="${REDIS_TESTS:-get,set}"

  log "redis preload: requests=${load_requests} keyspace=${keyspace} value_size=${value_size}"
  "${bench}" -p "${REDIS_PORT}" -c "${clients}" --threads "${threads}" \
    -n "${load_requests}" -r "${keyspace}" -d "${value_size}" -t set --csv
  log "redis run: tests=${tests} requests=${run_requests}"
  "${bench}" -p "${REDIS_PORT}" -c "${clients}" --threads "${threads}" \
    -n "${run_requests}" -r "${keyspace}" -d "${value_size}" -t "${tests}" --csv
}

run_redis_ycsb_a() {
  trap stop_redis EXIT
  java_env
  start_redis
  local workload_file

  local records="${YCSB_RECORDCOUNT:-800000}"
  local ops="${YCSB_OPERATIONCOUNT:-1600000}"
  local fieldlength="${YCSB_FIELDLENGTH:-4096}"
  local fieldcount="${YCSB_FIELDCOUNT:-10}"
  local threads="${YCSB_THREADS:-${OMP_THREADS}}"
  local dist="${YCSB_DISTRIBUTION:-uniform}"
  local heap="${YCSB_HEAP:-4g}"
  local workload="${YCSB_WORKLOAD:-workloada}"
  workload_file="$(ycsb_workload_file redis "${workload}")"

  log "redis ycsb load: workload=${workload} records=${records} fieldcount=${fieldcount} fieldlength=${fieldlength} dist=${dist}"
  run_ycsb redis load "${heap}" -s -P "${workload_file}" \
    -threads "${threads}" \
    -p "redis.host=127.0.0.1" -p "redis.port=${REDIS_PORT}" \
    -p "recordcount=${records}" -p "operationcount=${ops}" \
    -p "fieldcount=${fieldcount}" -p "fieldlength=${fieldlength}" \
    -p "requestdistribution=${dist}"

  log "redis ycsb run: ops=${ops}"
  run_ycsb redis run "${heap}" -s -P "${workload_file}" \
    -threads "${threads}" \
    -p "redis.host=127.0.0.1" -p "redis.port=${REDIS_PORT}" \
    -p "recordcount=${records}" -p "operationcount=${ops}" \
    -p "fieldcount=${fieldcount}" -p "fieldlength=${fieldlength}" \
    -p "requestdistribution=${dist}"
}

run_ycsb_rocksdb_uniform() {
  if [[ -z "${YCSB_JAVA_HOME:-}" && -x "${TOOLS_DIR}/jdk17/bin/java" ]]; then
    export YCSB_JAVA_HOME="${TOOLS_DIR}/jdk17"
  elif [[ -z "${YCSB_JAVA_HOME:-}" && -x "${BENCH_TOOLS_DIR}/jdk17/bin/java" ]]; then
    export YCSB_JAVA_HOME="${BENCH_TOOLS_DIR}/jdk17"
  elif [[ -z "${YCSB_JAVA_HOME:-}" && -x /usr/lib/jvm/java-17-openjdk-amd64/bin/java ]]; then
    export YCSB_JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
  fi
  java_env
  local workload_file
  local dbdir="${ROCKSDB_DIR:-/dev/shm/rocksdb-data-$$}"
  if [[ -n "${ROCKSDB_SHM_SIZE:-}" && "${dbdir}" == /dev/shm/* ]]; then
    mount -o "remount,size=${ROCKSDB_SHM_SIZE}" /dev/shm || true
  fi
  rm -rf "${dbdir}"
  mkdir -p "${dbdir}"
  trap "rm -rf '${dbdir}'" EXIT

  local records="${YCSB_RECORDCOUNT:-800000}"
  local ops="${YCSB_OPERATIONCOUNT:-1600000}"
  local fieldlength="${YCSB_FIELDLENGTH:-4096}"
  local fieldcount="${YCSB_FIELDCOUNT:-10}"
  local threads="${YCSB_THREADS:-${OMP_THREADS}}"
  local heap="${YCSB_HEAP:-4g}"
  local workload="${YCSB_WORKLOAD:-workloadc}"
  workload_file="$(ycsb_workload_file rocksdb "${workload}")"

  log "rocksdb ycsb load: records=${records} fieldcount=${fieldcount} fieldlength=${fieldlength}"
  run_ycsb rocksdb load "${heap}" -s -P "${workload_file}" \
    -threads "${threads}" \
    -p "rocksdb.dir=${dbdir}" \
    -p "recordcount=${records}" -p "operationcount=${ops}" \
    -p "fieldcount=${fieldcount}" -p "fieldlength=${fieldlength}" \
    -p "requestdistribution=uniform"

  log "rocksdb ycsb run: ops=${ops}"
  run_ycsb rocksdb run "${heap}" -s -P "${workload_file}" \
    -threads "${threads}" \
    -p "rocksdb.dir=${dbdir}" \
    -p "recordcount=${records}" -p "operationcount=${ops}" \
    -p "fieldcount=${fieldcount}" -p "fieldlength=${fieldlength}" \
    -p "requestdistribution=uniform"
}

run_memcached_ycsb_uniform() {
  trap stop_memcached EXIT
  java_env
  start_memcached
  local workload_file

  local records="${YCSB_RECORDCOUNT:-800000}"
  local ops="${YCSB_OPERATIONCOUNT:-1600000}"
  local fieldlength="${YCSB_FIELDLENGTH:-4096}"
  local fieldcount="${YCSB_FIELDCOUNT:-10}"
  local threads="${YCSB_THREADS:-${OMP_THREADS}}"
  local heap="${YCSB_HEAP:-4g}"
  local workload="${YCSB_WORKLOAD:-workloada}"
  workload_file="$(ycsb_workload_file memcached "${workload}")"

  log "memcached ycsb load: mem=${MEMCACHED_MEMORY_MB}MB records=${records}"
  run_ycsb memcached load "${heap}" -s -P "${workload_file}" \
    -threads "${threads}" \
    -p "memcached.hosts=127.0.0.1:${MEMCACHED_PORT}" \
    -p "recordcount=${records}" -p "operationcount=${ops}" \
    -p "fieldcount=${fieldcount}" -p "fieldlength=${fieldlength}" \
    -p "requestdistribution=uniform"

  log "memcached ycsb run: ops=${ops}"
  run_ycsb memcached run "${heap}" -s -P "${workload_file}" \
    -threads "${threads}" \
    -p "memcached.hosts=127.0.0.1:${MEMCACHED_PORT}" \
    -p "recordcount=${records}" -p "operationcount=${ops}" \
    -p "fieldcount=${fieldcount}" -p "fieldlength=${fieldlength}" \
    -p "requestdistribution=uniform"
}

run_faster() {
  local mix="$1"
  local dotnet
  dotnet="$(resolve_exec dotnet "${DOTNET_BIN:-}" "${TOOLS_DIR}/dotnet7/dotnet" "${BENCH_TOOLS_DIR}/dotnet7/dotnet" "${BENCH_TOOLS_DIR}/bin/bench-dotnet")"
  local dll="${BENCHMARK_DIR}/FASTER/cs/benchmark/bin/x64/Release/net7.0/FASTER.benchmark.dll"
  need_file "${dll}"
  if [[ "$(basename -- "${dotnet}")" == "dotnet" ]]; then
    export DOTNET_ROOT="$(cd -- "$(dirname -- "${dotnet}")" && pwd)"
  else
    export DOTNET_ROOT="${BENCH_TOOLS_DIR}/dotnet7"
  fi
  export PATH="${DOTNET_ROOT}:${PATH}"
  local faster_workdir="${WORKDIR}/faster"
  mkdir -p "${faster_workdir}/D:/data/FasterYcsbBenchmark"
  cd "${faster_workdir}"
  "${dotnet}" "${dll}" \
    --benchmark "${FASTER_BENCHMARK:-1}" \
    --threads "${FASTER_THREADS:-${OMP_THREADS}}" \
    --iterations "${FASTER_ITERATIONS:-1}" \
    --distribution "${FASTER_DISTRIBUTION:-uniform}" \
    --synth \
    --runsec "${FASTER_RUNSEC:-180}" \
    --rumd "${mix}" \
    ${FASTER_EXTRA_ARGS:-}
}

run_dlrm_synth() {
  local py
  py="$(resolve_exec python "${DLRM_PYTHON:-}" "${TOOLS_DIR}/dlrm-venv/bin/python" "${BENCH_TOOLS_DIR}/dlrm-venv/bin/python" "${BENCH_TOOLS_DIR}/bin/bench-python")"
  local app="${BENCHMARK_DIR}/DLRM/dlrm_s_pytorch.py"
  need_file "${app}"
  local site_packages
  site_packages="$(resolve_dir dlrm-site-packages "${TOOLS_DIR}/dlrm-venv/lib/python3.10/site-packages" "${BENCH_TOOLS_DIR}/dlrm-venv/lib/python3.10/site-packages")"
  export PYTHONPATH="${site_packages}:${PYTHONPATH:-}"
  local tables="${DLRM_TABLES:-8}"
  local rows="${DLRM_ROWS_PER_TABLE:-22000000}"
  local emb
  emb="$("${py}" - <<PY
tables = int("${tables}")
rows = int("${rows}")
print("-".join([str(rows)] * tables))
PY
)"
  cd "${BENCHMARK_DIR}/DLRM"
  "${py}" "${app}" \
    --mini-batch-size="${DLRM_MINI_BATCH:-16}" \
    --num-batches="${DLRM_NUM_BATCHES:-1}" \
    --nepochs="${DLRM_EPOCHS:-1}" \
    --test-freq=0 \
    --data-generation=random \
    --arch-embedding-size="${emb}" \
    --arch-sparse-feature-size="${DLRM_SPARSE_FEATURE:-64}" \
    --arch-mlp-bot="${DLRM_MLP_BOT:-13-512-64}" \
    --arch-mlp-top="${DLRM_MLP_TOP:-1024-1024-1024-1}" \
    --num-indices-per-lookup="${DLRM_INDICES_PER_LOOKUP:-100}" \
    --print-freq="${DLRM_PRINT_FREQ:-1}" \
    --print-time
}

run_npb() {
  local name="$1"
  local bin="${BENCHMARK_DIR}/NPB3.4.3/NPB3.4-OMP/bin/${name}.D.x"
  need_exec "${bin}"
  "${bin}"
}

run_spec_bwaves() {
  local dir="${BENCHMARK_DIR}/spec/603.bwaves_s/run/run_base_refspeed_mytest-m64.0000"
  need_exec "${dir}/speed_bwaves_base.mytest-m64"
  need_file "${dir}/bwaves_1.in"
  need_file "${dir}/bwaves_2.in"
  cd "${dir}"
  ./speed_bwaves_base.mytest-m64 bwaves_1 < bwaves_1.in
  ./speed_bwaves_base.mytest-m64 bwaves_2 < bwaves_2.in
}

run_spec_fotonik3d() {
  local dir="${BENCHMARK_DIR}/spec/649.fotonik3d_s"
  need_exec "${dir}/exe/fotonik3d_s_base.mytest-m64"
  if [[ ! -f "${dir}/run/yee.dat" && ! -f "${dir}/yee.dat" ]]; then
    echo "649.fotonik3d_s binary is staged, but SPEC ref input yee.dat is missing in this local tree" >&2
    exit 77
  fi
  cd "${dir}/run"
  ../exe/fotonik3d_s_base.mytest-m64
}

run_spec_roms() {
  local dir="${BENCHMARK_DIR}/spec/654.roms_s"
  need_exec "${dir}/exe/sroms_base.mytest-m64"
  if [[ ! -f "${dir}/run/ocean_benchmark3.in" || ! -f "${dir}/run/ROMS/External/varinfo.dat" ]]; then
    echo "654.roms_s binary is staged, but complete SPEC ref run directory is missing in this local tree" >&2
    exit 77
  fi
  cd "${dir}/run"
  ./sroms_base.mytest-m64 < ocean_benchmark3.in
}

spec2017_benchmark_mode() {
  local bench="$1"
  case "${bench}" in
    intrate|fprate|*_r|5[0-9][0-9].*) printf 'rate\n' ;;
    intspeed|fpspeed|*_s|6[0-9][0-9].*) printf 'speed\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

spec2017_benchmark_for_workload() {
  local workload="$1"
  workload="${workload#spec2017_}"
  workload="${workload#spec32_}"

  case "${workload}" in
    intrate|fprate|intspeed|fpspeed|[56][0-9][0-9].*) printf '%s\n' "${workload}" ;;
    500_perlbench_r|perlbench_r) printf '500.perlbench_r\n' ;;
    503_bwaves_r|bwaves_r) printf '503.bwaves_r\n' ;;
    505_mcf_r|mcf_r) printf '505.mcf_r\n' ;;
    507_cactuBSSN_r|cactuBSSN_r) printf '507.cactuBSSN_r\n' ;;
    508_namd_r|namd_r) printf '508.namd_r\n' ;;
    511_povray_r|povray_r) printf '511.povray_r\n' ;;
    519_lbm_r|lbm_r) printf '519.lbm_r\n' ;;
    520_omnetpp_r|omnetpp_r) printf '520.omnetpp_r\n' ;;
    523_xalancbmk_r|xalancbmk_r) printf '523.xalancbmk_r\n' ;;
    525_x264_r|x264_r) printf '525.x264_r\n' ;;
    526_blender_r|blender_r) printf '526.blender_r\n' ;;
    531_deepsjeng_r|deepsjeng_r) printf '531.deepsjeng_r\n' ;;
    538_imagick_r|imagick_r) printf '538.imagick_r\n' ;;
    541_leela_r|leela_r) printf '541.leela_r\n' ;;
    544_nab_r|nab_r) printf '544.nab_r\n' ;;
    548_exchange2_r|exchange2_r) printf '548.exchange2_r\n' ;;
    549_fotonik3d_r|fotonik3d_r) printf '549.fotonik3d_r\n' ;;
    554_roms_r|roms_r) printf '554.roms_r\n' ;;
    557_xz_r|xz_r) printf '557.xz_r\n' ;;
    600_perlbench_s|perlbench_s) printf '600.perlbench_s\n' ;;
    603_bwaves_s|bwaves_s) printf '603.bwaves_s\n' ;;
    605_mcf_s|mcf_s) printf '605.mcf_s\n' ;;
    607_cactuBSSN_s|cactuBSSN_s) printf '607.cactuBSSN_s\n' ;;
    619_lbm_s|lbm_s) printf '619.lbm_s\n' ;;
    620_omnetpp_s|omnetpp_s) printf '620.omnetpp_s\n' ;;
    623_xalancbmk_s|xalancbmk_s) printf '623.xalancbmk_s\n' ;;
    625_x264_s|x264_s) printf '625.x264_s\n' ;;
    631_deepsjeng_s|deepsjeng_s) printf '631.deepsjeng_s\n' ;;
    638_imagick_s|imagick_s) printf '638.imagick_s\n' ;;
    641_leela_s|leela_s) printf '641.leela_s\n' ;;
    644_nab_s|nab_s) printf '644.nab_s\n' ;;
    648_exchange2_s|exchange2_s) printf '648.exchange2_s\n' ;;
    649_fotonik3d_s|fotonik3d_s) printf '649.fotonik3d_s\n' ;;
    654_roms_s|roms_s) printf '654.roms_s\n' ;;
    657_xz_s|xz_s) printf '657.xz_s\n' ;;
    *) return 1 ;;
  esac
}

run_spec2017_runcpu() {
  local bench="$1"
  local root config config_file size tune iterations threads copies expid nobuild fake output_root mode spec_log rc
  local -a cmd

  root="$(resolve_dir spec2017-root "${SPEC2017_ROOT:-}" "${BENCHMARK_DIR}/spec")"
  config="${SPEC2017_CONFIG:-iccd-gcc-32core}"
  config_file="${config}"
  [[ "${config_file}" == *.cfg ]] || config_file="${config_file}.cfg"
  need_file "${root}/shrc"
  need_file "${root}/config/${config_file}"

  size="${SPEC2017_SIZE:-ref}"
  tune="${SPEC2017_TUNE:-base}"
  iterations="${SPEC2017_ITERATIONS:-1}"
  threads="${SPEC2017_THREADS:-${OMP_THREADS}}"
  copies="${SPEC2017_COPIES:-${OMP_THREADS}}"
  expid="${SPEC2017_EXPID:-}"
  nobuild="${SPEC2017_NOBUILD:-1}"
  fake="${SPEC2017_FAKE:-0}"
  output_root="${SPEC2017_OUTPUT_ROOT:-}"
  mode="$(spec2017_benchmark_mode "${bench}")"
  [[ "${mode}" != "unknown" ]] || {
    echo "cannot infer SPEC CPU2017 mode for ${bench}" >&2
    exit 2
  }

  cmd=(
    runcpu
    --config "${config}"
    --size "${size}"
    --tune "${tune}"
    --iterations "${iterations}"
    --noreportable
  )
  [[ -n "${expid}" ]] && cmd+=(--expid "${expid}")
  case "${mode}" in
    speed) cmd+=(--threads "${threads}") ;;
    rate) cmd+=(--copies "${copies}") ;;
  esac
  [[ "${nobuild}" == "1" ]] && cmd+=(--nobuild)
  [[ "${fake}" == "1" ]] && cmd+=(--fake)
  if [[ -n "${output_root}" ]]; then
    mkdir -p "${output_root}"
    cmd+=(--output_root "${output_root}")
  fi
  cmd+=("${bench}")

  cd "${root}"
  set +u
  # shellcheck source=/dev/null
  . ./shrc
  set -u

  log "spec2017 runcpu: root=${root} config=${config} mode=${mode} bench=${bench}"
  printf '[spec2017] command:' >&2
  printf ' %q' "${cmd[@]}" >&2
  printf '\n' >&2

  export OMP_PROC_BIND="${OMP_PROC_BIND:-true}"
  export OMP_PLACES="${OMP_PLACES:-cores}"
  spec_log="$(mktemp "${TMPDIR:-/tmp}/spec2017-runcpu.XXXXXX")"
  set +e
  "${cmd[@]}" 2>&1 | tee "${spec_log}"
  rc="${PIPESTATUS[0]}"
  set -e
  if ((rc != 0)); then
    rm -f "${spec_log}"
    return "${rc}"
  fi
  if grep -Eq '^(Error:|Error [0-9][0-9][0-9]\.)' "${spec_log}"; then
    echo "SPEC CPU2017 reported benchmark errors despite runcpu rc=0" >&2
    rm -f "${spec_log}"
    return 1
  fi
  if ! grep -Eq '^Success:' "${spec_log}"; then
    echo "SPEC CPU2017 did not report Success:" >&2
    rm -f "${spec_log}"
    return 1
  fi
  rm -f "${spec_log}"
}

run_spec2017_workload() {
  local bench
  bench="$(spec2017_benchmark_for_workload "${WORKLOAD}")" || {
    echo "unknown SPEC CPU2017 workload alias: ${WORKLOAD}" >&2
    exit 2
  }
  run_spec2017_runcpu "${bench}"
}

generate_canneal_netlist() {
  local out="$1"
  local elems="${CANNEAL_ELEMENTS:-500000}"
  local grid_x="${CANNEAL_GRID_X:-1024}"
  local grid_y="${CANNEAL_GRID_Y:-1024}"
  local fanin="${CANNEAL_FANIN:-4}"
  if [[ -f "${out}" ]]; then
    return 0
  fi
  log "generating canneal netlist: elems=${elems} grid=${grid_x}x${grid_y} fanin=${fanin}"
  awk -v n="${elems}" -v x="${grid_x}" -v y="${grid_y}" -v fanin="${fanin}" '
    BEGIN {
      print n, x, y;
      for (i = 0; i < n; i++) {
        printf "n%d 1", i;
        for (j = 1; j <= fanin; j++) {
          printf " n%d", (i + j * 2654435761) % n;
        }
        print " END";
      }
    }
  ' > "${out}"
}

run_canneal_synth() {
  local bin="${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_canneal_mt"
  local netlist="${WORKDIR}/canneal-${CANNEAL_ELEMENTS:-500000}.net"
  need_exec "${bin}"
  generate_canneal_netlist "${netlist}"
  "${bin}" \
    "${CANNEAL_THREADS:-${OMP_THREADS}}" \
    "${CANNEAL_SWAPS:-1000000}" \
    "${CANNEAL_TEMP:-2000}" \
    "${netlist}" \
    "${CANNEAL_STEPS:-1}"
}

unavailable() {
  echo "$1 is recognized but not locally runnable yet: $2" >&2
  exit 77
}

case "${WORKLOAD}" in
  redis_uniform) run_redis_uniform ;;
  redis_ycsb_a) run_redis_ycsb_a ;;
  rocksdb_ycsb_uniform) run_ycsb_rocksdb_uniform ;;
  memcached_ycsb_uniform) run_memcached_ycsb_uniform ;;
  faster_uniform) run_faster "${FASTER_RUMD:-100,0,0,0}" ;;
  faster_ycsb_a) run_faster "${FASTER_RUMD:-50,50,0,0}" ;;
  dlrm_synth) run_dlrm_synth ;;
  npb_cg) run_npb cg ;;
  npb_mg) run_npb mg ;;
  npb_ua) run_npb ua ;;
  spec_bwaves) run_spec_bwaves ;;
  spec_fotonik3d) run_spec_fotonik3d ;;
  spec_roms) run_spec_roms ;;
  spec2017_*|spec32_*) run_spec2017_workload ;;
  canneal_synth) run_canneal_synth ;;
  hibench_repartition) unavailable "${WORKLOAD}" "Spark/Hadoop runtime is not staged by the lightweight default path" ;;
  hibench_sql_join) unavailable "${WORKLOAD}" "Spark/Hadoop runtime is not staged by the lightweight default path" ;;
  cloudsuite_data_caching) unavailable "${WORKLOAD}" "CloudSuite Docker image/dataset is not staged by the lightweight default path" ;;
  cloudsuite_web_search) unavailable "${WORKLOAD}" "Solr Docker image and 14GB index dataset are not staged by the lightweight default path" ;;
  cloudsuite_als) unavailable "${WORKLOAD}" "Spark runtime and MovieLens dataset are not staged by the lightweight default path" ;;
  duckdb_tpch) unavailable "${WORKLOAD}" "DuckDB binary/data are external; install/stage per run to avoid bloating the VM image" ;;
  clickbench) unavailable "${WORKLOAD}" "ClickBench data/engine are external; install/stage per run to avoid bloating the VM image" ;;
  hnsw_faiss) unavailable "${WORKLOAD}" "FAISS/hnswlib package and vector dataset are external; install/stage per run" ;;
  *)
    echo "unknown real-world workload: ${WORKLOAD}" >&2
    exit 2
    ;;
esac
