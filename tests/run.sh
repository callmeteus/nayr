#!/bin/sh
# nayr test runner
#
# Convenience entrypoint that runs unit tests, integration tests, and/or
# benchmarks depending on the arguments passed.
#
# Usage: sh tests/run.sh [command] [options]
#
# Commands:
#   all         Run unit tests + integration tests (default)
#   unit        Run Zig unit tests only
#   integration Run shell integration tests only
#   bench       Run performance benchmark
#   ci          Run lint, unit tests, and integration (fail fast)
#
# Options forwarded to sub-scripts:
#   --no-yarn       Skip yarn comparison in integration/bench
#   --filter <pat>  Only run integration tests matching pattern
#   --runs <N>      Number of benchmark repetitions (default: 3)
#   --json          Benchmark output as JSON

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAYR_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CMD="${1:-all}"
shift 2>/dev/null || true

if [ -t 1 ]; then
    BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
    RED='\033[0;31m'; RESET='\033[0m'
else
    BOLD=''; CYAN=''; GREEN=''; RED=''; RESET=''
fi

header() { printf "\n${BOLD}${CYAN}=== %s ===${RESET}\n" "$1"; }
ok()     { printf "${GREEN}%s${RESET}\n" "$1"; }
err()    { printf "${RED}%s${RESET}\n" "$1"; }

run_unit() {
    header "Unit tests (zig build test)"
    (cd "$NAYR_ROOT" && zig build test)
}

run_integration() {
    header "Integration tests"
    sh "$SCRIPT_DIR/integration/test.sh" "$@"
}

run_bench() {
    header "Performance benchmark"
    sh "$SCRIPT_DIR/bench/bench.sh" "$@"
}

run_lint() {
    header "Lint (zig fmt --check + zlint)"
    sh "$NAYR_ROOT/scripts/lint.sh"
}

case "$CMD" in
    unit)
        run_unit
        ok "Unit tests passed."
        ;;
    integration)
        run_integration "$@"
        ;;
    bench)
        run_bench "$@"
        ;;
    all)
        run_unit
        run_integration "$@"
        ok "All tests passed."
        ;;
    ci)
        run_lint
        run_unit
        run_integration --no-yarn "$@"
        ok "CI suite passed."
        ;;
    *)
        printf "Unknown command: %s\n" "$CMD"
        printf "Usage: sh tests/run.sh [all|unit|integration|bench|ci] [options]\n"
        exit 1
        ;;
esac
