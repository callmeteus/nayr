#!/bin/sh
# nayr integration tests
#
# Runs a series of correctness checks comparing nayr against yarn classic.
# Each test copies a fixture to a temp directory, runs both tools, and
# compares the outcomes (exit code, installed files, script output).
#
# Usage: sh tests/integration/test.sh [--no-yarn] [--filter <pattern>]
#
#   --no-yarn    Skip yarn comparison (faster, just verify nayr works)
#   --filter     Only run tests whose name matches the pattern

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAYR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NAYR_BIN="$NAYR_ROOT/zig-out/bin/nayr"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
SKIP_YARN=0
FILTER=""

for arg in "$@"; do
    case "$arg" in
        --no-yarn) SKIP_YARN=1 ;;
        --filter)  shift; FILTER="$1" ;;
        *)         FILTER="$arg" ;;
    esac
done

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m';  BOLD='\033[1m';   RESET='\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); printf "${GREEN}  PASS${RESET} %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "${RED}  FAIL${RESET} %s\n" "$1"; if [ -n "$2" ]; then printf "       %s\n" "$2"; fi; }
skip() { SKIP=$((SKIP + 1)); printf "${YELLOW}  SKIP${RESET} %s\n" "$1"; if [ -n "$2" ]; then printf "       ${DIM}%s${RESET}\n" "$2"; fi; }
DIM='\033[2m'
section() { printf "\n${BOLD}${CYAN}%s${RESET}\n" "$1"; }

should_run() {
    [ -z "$FILTER" ] && return 0
    case "$1" in *"$FILTER"*) return 0 ;; esac
    return 1
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# copy_fixture <name> - copies fixture to a fresh temp dir, prints the path
copy_fixture() {
    local name="$1"
    local tmp
    tmp="$(mktemp -d)"
    cp -r "$FIXTURES_DIR/$name/." "$tmp/"
    echo "$tmp"
}

# assert_exit <expected> <actual> <label>
assert_exit() {
    if [ "$1" = "$2" ]; then
        pass "$3 (exit $2)"
    else
        fail "$3" "expected exit $1, got $2"
    fi
}

# assert_file_exists <path> <label>
assert_file_exists() {
    if [ -e "$1" ]; then
        pass "$2"
    else
        fail "$2" "file not found: $1"
    fi
}

# assert_stdout_contains <needle> <stdout_file> <label>
assert_stdout_contains() {
    if grep -qF "$1" "$2" 2>/dev/null; then
        pass "$3"
    else
        fail "$3" "expected output to contain: $1"
        printf "  --- actual output ---\n"
        head -5 "$2" | sed 's/^/  /'
    fi
}

# assert_same_exit <yarn_exit> <nayr_exit> <label>
assert_same_exit() {
    if [ "$1" = "$2" ]; then
        pass "$3 (both exit $1)"
    else
        fail "$3" "yarn=$1 nayr=$2"
    fi
}

# nayr_run <out_var> <exit_var> <dir> [args...]
# Runs nayr in <dir>, stores combined stdout+stderr in $out_var and exit code
# in $exit_var. Uses a temp file to reliably capture the exit code even when
# the process calls exit() directly (avoids set -e interaction issues).
nayr_run() {
    local _out_var="$1" _ec_var="$2" _dir="$3"; shift 3
    local _tmp_ec _output
    _tmp_ec="$(mktemp)"
    _output="$(cd "$_dir" && "$NAYR_BIN" "$@" 2>&1; echo $? > "$_tmp_ec")"
    eval "$_out_var=\"\$_output\""
    eval "$_ec_var=$(cat "$_tmp_ec")"
    rm -f "$_tmp_ec"
}

# yarn_run <out_var> <exit_var> <dir> [args...]
yarn_run() {
    local _out_var="$1" _ec_var="$2" _dir="$3"; shift 3
    local _tmp_ec _output
    _tmp_ec="$(mktemp)"
    _output="$(cd "$_dir" && . ~/.nvm/nvm.sh 2>/dev/null; yarn "$@" 2>&1; echo $? > "$_tmp_ec")"
    eval "$_out_var=\"\$_output\""
    eval "$_ec_var=$(cat "$_tmp_ec")"
    rm -f "$_tmp_ec"
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
section "Pre-flight checks"

if [ ! -f "$NAYR_BIN" ]; then
    printf "${YELLOW}nayr binary not found, building...${RESET}\n"
    (cd "$NAYR_ROOT" && zig build) || { printf "${RED}Build failed${RESET}\n"; exit 1; }
fi
pass "nayr binary exists ($NAYR_BIN)"

if [ "$SKIP_YARN" = "0" ]; then
    if command -v yarn >/dev/null 2>&1; then
        YARN_VER="$(yarn --version 2>/dev/null)"
        pass "yarn $YARN_VER found"
    else
        printf "${YELLOW}  WARN${RESET} yarn not found - skipping comparison tests\n"
        SKIP_YARN=1
    fi
fi

# ---------------------------------------------------------------------------
# Section: help & version
# ---------------------------------------------------------------------------
section "Help & version"

if should_run "help"; then
    out="$("$NAYR_BIN" --help 2>&1)"
    if echo "$out" | grep -q "install"; then
        pass "help: shows install command"
    else
        fail "help: shows install command"
    fi
    if echo "$out" | grep -q "run"; then
        pass "help: shows run command"
    else
        fail "help: shows run command"
    fi
fi

if should_run "version"; then
    out="$("$NAYR_BIN" --version 2>&1)"
    if echo "$out" | grep -qE "^nayr v?[0-9]"; then
        pass "version: prints version string"
    else
        fail "version: prints version string" "got: $out"
    fi
fi

# ---------------------------------------------------------------------------
# Section: error messages
# ---------------------------------------------------------------------------
section "Error messages"

if should_run "no-package-json"; then
    tmp="$(mktemp -d)"
    nayr_run out ec "$tmp"
    rm -rf "$tmp"
    assert_exit "1" "$ec" "no package.json: exits 1"
    if echo "$out" | grep -qi "package.json"; then
        pass "no package.json: mentions package.json in error"
    else
        fail "no package.json: mentions package.json in error" "got: $out"
    fi
fi

if should_run "unknown-script"; then
    tmp="$(copy_fixture scripts)"
    nayr_run out ec "$tmp" nonexistent-script
    rm -rf "$tmp"
    assert_exit "1" "$ec" "unknown script: exits 1"
    if echo "$out" | grep -qi "not found"; then
        pass "unknown script: mentions 'not found'"
    else
        fail "unknown script: mentions 'not found'" "got: $out"
    fi
fi

# ---------------------------------------------------------------------------
# Section: script execution
# ---------------------------------------------------------------------------
section "Script execution"

if should_run "script-basic"; then
    tmp="$(copy_fixture scripts)"
    nayr_run out ec "$tmp" greet
    rm -rf "$tmp"
    assert_exit "0" "$ec" "script greet: exits 0"
    if echo "$out" | grep -q "hello from nayr"; then
        pass "script greet: correct output"
    else
        fail "script greet: correct output" "got: $out"
    fi
fi

if should_run "script-exit-code"; then
    tmp="$(copy_fixture scripts)"
    nayr_run out ec "$tmp" fail
    rm -rf "$tmp"
    assert_exit "7" "$ec" "script fail: propagates exit code 7"
fi

if should_run "script-args"; then
    tmp="$(copy_fixture scripts)"
    nayr_run out ec "$tmp" run args -- hello world
    rm -rf "$tmp"
    assert_exit "0" "$ec" "script args: exits 0"
    if echo "$out" | grep -q "hello world"; then
        pass "script args: extra args forwarded"
    else
        fail "script args: extra args forwarded" "got: $out"
    fi
fi

if should_run "script-run-prefix"; then
    tmp="$(copy_fixture scripts)"
    nayr_run out1 ec1 "$tmp" greet
    nayr_run out2 ec2 "$tmp" run greet
    rm -rf "$tmp"
    if [ "$out1" = "$out2" ]; then
        pass "script: 'nayr greet' == 'nayr run greet'"
    else
        fail "script: 'nayr greet' == 'nayr run greet'" "direct: $out1 / run: $out2"
    fi
fi

if should_run "script-yarn-parity" && [ "$SKIP_YARN" = "0" ]; then
    tmp="$(copy_fixture scripts)"
    nayr_run nayr_out nayr_ec "$tmp" greet
    yarn_run yarn_out yarn_ec "$tmp" greet
    rm -rf "$tmp"
    assert_same_exit "$yarn_ec" "$nayr_ec" "script yarn-parity: same exit code"
    if echo "$nayr_out" | grep -q "hello from nayr" && echo "$yarn_out" | grep -q "hello from nayr"; then
        pass "script yarn-parity: same stdout content"
    else
        fail "script yarn-parity: same stdout content" "nayr: $nayr_out / yarn: $yarn_out"
    fi
fi

# ---------------------------------------------------------------------------
# Section: install (simple)
# ---------------------------------------------------------------------------
section "Install (simple project)"

if should_run "install-simple"; then
    tmpd="$(mktemp -d)"
    cp "$FIXTURES_DIR/simple/package.json" "$tmpd/"

    nayr_run _out nayr_ec "$tmpd" install

    if [ "$nayr_ec" = "0" ]; then
        pass "simple install: exits 0"
    else
        fail "simple install: exits 0" "exit code: $nayr_ec"
    fi

    if [ -d "$tmpd/node_modules/lodash" ]; then
        pass "simple install: lodash installed"
    else
        fail "simple install: lodash installed"
    fi

    if [ -d "$tmpd/node_modules/ms" ]; then
        pass "simple install: ms installed"
    else
        fail "simple install: ms installed"
    fi

    if [ -f "$tmpd/nayr.lock" ]; then
        pass "simple install: nayr.lock written"
    else
        fail "simple install: nayr.lock written"
    fi

    rm -rf "$tmpd"
fi

if should_run "install-idempotent"; then
    tmpd="$(mktemp -d)"
    cp "$FIXTURES_DIR/simple/package.json" "$tmpd/"

    nayr_run _o1 _ec1 "$tmpd" install
    nayr_run _o2 second_ec "$tmpd" install

    if [ "$second_ec" = "0" ]; then
        pass "install idempotent: second install exits 0"
    else
        fail "install idempotent: second install exits 0" "exit=$second_ec"
    fi

    rm -rf "$tmpd"
fi

if should_run "install-yarn-parity" && [ "$SKIP_YARN" = "0" ]; then
    tmpd_nayr="$(mktemp -d)"
    tmpd_yarn="$(mktemp -d)"
    cp "$FIXTURES_DIR/simple/package.json" "$tmpd_nayr/"
    cp "$FIXTURES_DIR/simple/package.json" "$tmpd_yarn/"

    nayr_run _nayr_out nayr_ec "$tmpd_nayr" install
    yarn_run _yarn_out yarn_ec "$tmpd_yarn" install

    if [ "$nayr_ec" = "$yarn_ec" ]; then
        pass "install parity: same exit code"
    else
        fail "install parity: same exit code" "nayr=$nayr_ec yarn=$yarn_ec"
    fi

    nayr_pkgs="$(ls "$tmpd_nayr/node_modules" 2>/dev/null | sort | tr '\n' ',')"
    yarn_pkgs="$(ls "$tmpd_yarn/node_modules" 2>/dev/null | sort | grep -v '^\.yarn$\|^\.bin$' | tr '\n' ',')"
    if [ "$nayr_pkgs" = "$yarn_pkgs" ]; then
        pass "install parity: same top-level packages installed"
    else
        fail "install parity: same top-level packages installed" \
             "nayr: $nayr_pkgs   yarn: $yarn_pkgs"
    fi

    rm -rf "$tmpd_nayr" "$tmpd_yarn"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf "\n${BOLD}Results:${RESET} ${GREEN}$PASS passed${RESET}"
[ "$FAIL" -gt 0 ] && printf ", ${RED}$FAIL failed${RESET}"
[ "$SKIP" -gt 0 ] && printf ", ${YELLOW}$SKIP skipped${RESET}"
printf "\n\n"

[ "$FAIL" -eq 0 ]
