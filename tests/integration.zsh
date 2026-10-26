#!/usr/bin/env zsh
# Integration tests for smart-context-suggest
#
# Run from the plugin root:  zsh tests/integration.zsh
# Requires: the Rust binary to be built (run install.sh first)

setopt PIPE_FAIL

PLUGIN_ROOT="${0:A:h:h}"
BIN="$PLUGIN_ROOT/bin/smart-suggest"
TESTDB=$(mktemp -d)/memory.db

export SMART_SUGGEST_DATA_DIR="${TESTDB%/memory.db}"

pass=0
fail=0

# ---------- Helpers ----------

run_test() {
  local name="$1"; shift
  if "$@" 2>/dev/null; then
    print "\033[32m  PASS\033[0m $name"
    pass=$(( pass + 1 ))
  else
    print "\033[31m  FAIL\033[0m $name"
    fail=$(( fail + 1 ))
  fi
}

assert_contains() {
  local output="$1" expected="$2"
  [[ "$output" == *"$expected"* ]]
}

assert_not_contains() {
  local output="$1" expected="$2"
  [[ "$output" != *"$expected"* ]]
}

assert_empty() {
  local output="$1"
  [[ -z "${output// /}" ]]
}

now() { date +%s }

# ---------- Tests ----------

print "\nsmart-context-suggest integration tests\n"
print "Binary: $BIN"
print "Test DB: $SMART_SUGGEST_DATA_DIR\n"

# Test 1: Binary exists and runs
run_test "binary is executable" test -x "$BIN"

# Test 2: Record a command
run_test "record command" \
  "$BIN" record --dir /tmp/proj --cmd "make build" --ts "$(now)"

# Test 3: Query returns recorded command
run_test "query returns recorded command" \
  assert_contains "$("$BIN" query --dir /tmp/proj --prefix "make")" "make build"

# Test 4: Record same command multiple times
"$BIN" record --dir /tmp/proj --cmd "make build" --ts "$(now)" 2>/dev/null
"$BIN" record --dir /tmp/proj --cmd "make build" --ts "$(now)" 2>/dev/null

run_test "frequency increments on repeated record" \
  assert_contains "$("$BIN" list --dir /tmp/proj)" "make build"

# Test 5: Directory isolation — command from /tmp/proj must not appear in /tmp/other
run_test "directory isolation: other dir gets no results" \
  assert_empty "$("$BIN" query --dir /tmp/other --prefix "make" --limit 1)"

# Test 6: Different command in different directory
"$BIN" record --dir /tmp/other --cmd "ls -la" --ts "$(now)"
run_test "other dir has its own commands" \
  assert_contains "$("$BIN" query --dir /tmp/other --prefix "ls")" "ls -la"

run_test "other dir does not see /tmp/proj commands" \
  assert_not_contains "$("$BIN" query --dir /tmp/other --prefix "make")" "make build"

# Test 7: mark-success updates record
run_test "mark-success runs without error" \
  "$BIN" mark-success --dir /tmp/proj --cmd "make build" --ok 1

# Test 8: stats output
run_test "stats runs without error" \
  assert_contains "$("$BIN" stats)" "Total entries"

# Test 9: list output
run_test "list shows commands in dir" \
  assert_contains "$("$BIN" list --dir /tmp/proj)" "make build"

# Test 10: export produces JSON
run_test "export produces valid JSON array" \
  assert_contains "$("$BIN" export)" '"command"'

# Test 11: JSON query output
run_test "query --json returns JSON" \
  assert_contains "$("$BIN" query --dir /tmp/proj --prefix make --json)" '"command"'

# Test 12: Decay removes stale weak entries
# Insert an old entry directly, then force decay
OLD_TS=1000  # very old timestamp
"$BIN" record --dir /tmp/stale --cmd "old-cmd" --ts "$OLD_TS"
"$BIN" decay --stale-days 0  # stale threshold = 0 days → everything is stale
run_test "decay removes stale weak entries" \
  assert_empty "$("$BIN" query --dir /tmp/stale --prefix "old")"

# Test 13: Stronger command survives decay
# Record a frequently-used command
for i in {1..5}; do
  "$BIN" record --dir /tmp/strong --cmd "make test" --ts "$(now)"
  "$BIN" mark-success --dir /tmp/strong --cmd "make test" --ok 1
done
"$BIN" decay --stale-days 9999  # far-future decay — should not remove recent entries
run_test "decay keeps strong recent entries" \
  assert_contains "$("$BIN" query --dir /tmp/strong --prefix make)" "make test"

# Test 14: clear --dir removes only that directory
"$BIN" record --dir /tmp/keep --cmd "keepme" --ts "$(now)"
"$BIN" record --dir /tmp/del  --cmd "deleteme" --ts "$(now)"
"$BIN" clear --dir /tmp/del
run_test "clear --dir removes only that directory" \
  assert_contains "$("$BIN" query --dir /tmp/keep --prefix keep)" "keepme"
run_test "clear --dir does not affect other directories" \
  assert_empty "$("$BIN" query --dir /tmp/del --prefix deleteme)"

# Test 15: Prefix query filters correctly
"$BIN" record --dir /tmp/filter --cmd "git status" --ts "$(now)"
"$BIN" record --dir /tmp/filter --cmd "git log" --ts "$(now)"
"$BIN" record --dir /tmp/filter --cmd "npm install" --ts "$(now)"

run_test "prefix git returns only git commands" \
  assert_not_contains "$("$BIN" query --dir /tmp/filter --prefix "git")" "npm install"

run_test "prefix npm returns npm commands" \
  assert_contains "$("$BIN" query --dir /tmp/filter --prefix "npm")" "npm install"

# Test 16: debug flag
"$BIN" debug on
run_test "debug on creates flag file" \
  test -f "$HOME/.cache/smart-context-suggest/debug.enabled"
"$BIN" debug off
run_test "debug off removes flag file" \
  test ! -f "$HOME/.cache/smart-context-suggest/debug.enabled"

# ---------- Summary ----------

print "\n─────────────────────────────"
print "Results: \033[32m$pass passed\033[0m, \033[31m$fail failed\033[0m"
print "─────────────────────────────\n"

[[ $fail -eq 0 ]] && exit 0 || exit 1
