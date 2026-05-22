#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(dirname -- "$SCRIPT_DIR")
BIN="$ROOT_DIR/mbench"

TIMEOUT_SEC=${MBENCH_PHASE_SMOKE_TIMEOUT_SEC:-15}
DRY_RUN=0
NO_BUILD=0
KEEP_OUTPUT=0

log() {
    printf '[mbench-phase-smoke] %s\n' "$*"
}

usage() {
    cat <<'EOF'
usage: mbench-phase-smoke.sh [options] [-- mbench-args...]

Builds Microbenchmark/mbench if needed, then runs a timeout-bounded phase
preset smoke test with a small arena/window. The run succeeds only if output
contains a phase_id field and at least two distinct phase_id values.

Options:
  --timeout SEC      Wall-clock cap for the smoke run. Default: 15.
  --dry-run          Print the command without building or running it.
  --no-build         Require an existing Microbenchmark/mbench binary.
  --keep-output      Keep captured stdout/stderr files and print their paths.
  -h, --help         Show this help.

Override the default phase preset by passing the full mbench argument list
after "--", or by setting MBENCH_PHASE_SMOKE_ARGS.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --timeout)
            if [ $# -lt 2 ]; then
                log "missing value for --timeout"
                exit 1
            fi
            TIMEOUT_SEC=$2
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --no-build)
            NO_BUILD=1
            shift
            ;;
        --keep-output)
            KEEP_OUTPUT=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            log "unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if [ $# -eq 0 ]; then
    if [ "${MBENCH_PHASE_SMOKE_ARGS:-}" ]; then
        # Intentional shell splitting for an operator-provided argument string.
        # Keep values simple, or pass explicit argv after "--" instead.
        # shellcheck disable=SC2086
        set -- $MBENCH_PHASE_SMOKE_ARGS
    else
        set -- \
            --phase-preset friendly-unfriendly \
            --arena-size 64M \
            --window-size 8M \
            --phase-ms 1000 \
            --phase-repeat 3 \
            --sample-ms 250 \
            --threads 2 \
            --ops-per-pass 16384 \
            --pause-ns 100000 \
            --csv
    fi
fi

build_if_needed() {
    if [ -x "$BIN" ] &&
        ! find "$ROOT_DIR/Makefile" "$ROOT_DIR/include" "$ROOT_DIR/src" -type f -newer "$BIN" | grep -q .; then
        log "found existing binary: $BIN"
        return
    fi

    if [ "$NO_BUILD" -eq 1 ]; then
        if [ -x "$BIN" ]; then
            log "using existing binary without rebuilding: $BIN"
            return
        fi
        log "binary not found: $BIN"
        exit 1
    fi

    if [ ! -f "$ROOT_DIR/Makefile" ]; then
        log "missing $ROOT_DIR/Makefile"
        exit 1
    fi

    log "building project with make"
    make -C "$ROOT_DIR"

    if [ ! -x "$BIN" ]; then
        log "build finished but $BIN is still missing or not executable"
        exit 1
    fi
}

cleanup() {
    if [ "${TMPDIR_CREATED:-}" ] && [ "$KEEP_OUTPUT" -eq 0 ]; then
        rm -rf "$TMPDIR_CREATED"
    fi
}

phase_id_count() {
    combined=$1

    {
        awk -F, '
            col == 0 {
                for (i = 1; i <= NF; i++) {
                    if ($i == "phase_id") {
                        col = i
                    }
                }
                if (col > 0) {
                    next
                }
            }
            col > 0 && $col ~ /^[0-9]+$/ {
                print $col
            }
        ' "$combined"
        sed -n 's/.*phase_id[= ]\([0-9][0-9]*\).*/\1/p' "$combined"
    } | sed '/^$/d' | sort -u | wc -l | awk '{print $1}'
}

run_smoke() {
    if ! command -v timeout >/dev/null 2>&1; then
        log "missing required timeout(1)"
        exit 1
    fi

    TMPDIR_CREATED=$(mktemp -d "${TMPDIR:-/tmp}/mbench-phase-smoke.XXXXXX")
    trap cleanup EXIT INT TERM
    stdout_path="$TMPDIR_CREATED/stdout.txt"
    stderr_path="$TMPDIR_CREATED/stderr.txt"
    combined_path="$TMPDIR_CREATED/combined.txt"

    log "running with ${TIMEOUT_SEC}s timeout: $BIN $*"
    set +e
    timeout "$TIMEOUT_SEC" "$BIN" "$@" >"$stdout_path" 2>"$stderr_path"
    rc=$?
    set -e

    cat "$stdout_path" "$stderr_path" >"$combined_path"

    if ! grep -q 'phase_id' "$combined_path"; then
        log "phase_id field was not observed"
        log "stderr tail:"
        tail -n 20 "$stderr_path" | sed 's/^/[stderr] /'
        exit 1
    fi

    ids=$(phase_id_count "$combined_path")
    if [ "$ids" -lt 2 ]; then
        log "expected at least two distinct phase_id values, observed $ids"
        tail -n 20 "$combined_path" | sed 's/^/[output] /'
        exit 1
    fi

    case "$rc" in
        0|124|143)
            log "phase smoke passed: observed $ids phase_id values (exit=$rc)"
            ;;
        *)
            log "mbench exited with $rc despite phase_id output"
            tail -n 20 "$combined_path" | sed 's/^/[output] /'
            exit "$rc"
            ;;
    esac

    if [ "$KEEP_OUTPUT" -eq 1 ]; then
        log "stdout: $stdout_path"
        log "stderr: $stderr_path"
    fi
}

if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run: timeout $TIMEOUT_SEC $BIN $*"
    exit 0
fi

build_if_needed
run_smoke "$@"
