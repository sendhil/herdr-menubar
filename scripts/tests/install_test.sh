#!/bin/bash
set -u

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
INSTALLER="$REPO_ROOT/scripts/install.sh"
UNINSTALLER="$REPO_ROOT/scripts/uninstall.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/herdr-install-tests.XXXXXX") || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT

passed=0
failed=0
pass() { passed=$((passed + 1)); printf 'ok - %s\n' "$1"; }
fail() { failed=$((failed + 1)); printf 'not ok - %s\n' "$1" >&2; }
assert_file() { [ -e "$1" ] || { printf 'Expected file: %s\n' "$1" >&2; return 1; }; }
assert_path() { [ -e "$1" ] || [ -L "$1" ] || { printf 'Expected path: %s\n' "$1" >&2; return 1; }; }
assert_not_path() { [ ! -e "$1" ] && [ ! -L "$1" ] || { printf 'Expected no path: %s\n' "$1" >&2; return 1; }; }
assert_contains() { case "$1" in *"$2"*) return 0;; esac; printf 'Expected output to contain %s, got:\n%s\n' "$2" "$1" >&2; return 1; }
assert_log_call() {
  file=$1; shift
  expected="argc=$#"
  for argument in "$@"; do expected="$expected
arg=$argument"; done
  expected="$expected
end"
  actual=$(cat "$file" 2>/dev/null || true)
  [ "$actual" = "$expected" ] || { printf 'Unexpected argument log %s. Expected:\n%s\nActual:\n%s\n' "$file" "$expected" "$actual" >&2; return 1; }
}

make_fakes() {
  case_dir=$1
  mkdir -p "$case_dir/bin" "$case_dir/log"
  cat > "$case_dir/bin/xcodebuild" <<'FAKE'
#!/bin/bash
{
  printf 'argc=%s\n' "$#"
  for argument in "$@"; do printf 'arg=%s\n' "$argument"; done
  printf 'end\n'
} >> "$FAKE_LOG/xcodebuild"
derived=
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-derivedDataPath" ]; then shift; derived=$1; fi
  shift
done
[ "${FAKE_XCODEBUILD_FAIL:-0}" != 1 ] || exit 65
if [ "${FAKE_XCODEBUILD_NO_PRODUCT:-0}" != 1 ]; then
  mkdir -p "$derived/Build/Products/Release/HerdrMenubar.app/Contents/MacOS"
  printf '#!/bin/sh\n' > "$derived/Build/Products/Release/HerdrMenubar.app/Contents/MacOS/HerdrMenubar"
fi
FAKE
  cat > "$case_dir/bin/open" <<'FAKE'
#!/bin/bash
{
  printf 'argc=%s\n' "$#"
  for argument in "$@"; do printf 'arg=%s\n' "$argument"; done
  printf 'end\n'
} >> "$FAKE_LOG/open"
if [ "${FAKE_REPLACE_LOCK:-0}" = 1 ]; then
  rm -rf "$FAKE_LOCK_PATH"
  mkdir "$FAKE_LOCK_PATH"
  printf '99999999\n' > "$FAKE_LOCK_PATH/owner"
  printf 'replacement-token\n' > "$FAKE_LOCK_PATH/token"
fi
[ "${FAKE_OPEN_FAIL:-0}" != 1 ]
FAKE
  cat > "$case_dir/bin/pgrep" <<'FAKE'
#!/bin/bash
{
  printf 'argc=%s\n' "$#"
  for argument in "$@"; do printf 'arg=%s\n' "$argument"; done
  printf 'end\n'
} >> "$FAKE_LOG/pgrep"
[ "$#" -eq 2 ] && [ "$1" = -x ] && [ "$2" = HerdrMenubar ] || {
  echo "pgrep contract violation" >&2
  exit 64
}
if [ "${FAKE_CREATE_RACE:-0}" = 1 ] && [ ! -e "$FAKE_LOG/race-created" ]; then
  : > "$FAKE_LOG/race-created"
  mkdir -p "$FAKE_RACE_DESTINATION"
  printf raced > "$FAKE_RACE_DESTINATION/raced-marker"
fi
found=1
for pid in ${FAKE_PGREP_PIDS:-}; do
  if ! grep -qx "$pid" "$FAKE_LOG/dead" 2>/dev/null; then printf '%s\n' "$pid"; found=0; fi
done
exit "$found"
FAKE
  cat > "$case_dir/bin/ps" <<'FAKE'
#!/bin/bash
{
  printf 'argc=%s\n' "$#"
  for argument in "$@"; do printf 'arg=%s\n' "$argument"; done
  printf 'end\n'
} >> "$FAKE_LOG/ps"
[ "$#" -eq 4 ] && [ "$1" = -p ] && [ -n "$2" ] && [ "$3" = -o ] && [ "$4" = comm= ] || {
  echo "ps contract violation" >&2
  exit 64
}
pid=$2
case "$pid" in *[!0-9]*|'') echo "ps PID boundary violation" >&2; exit 64;; esac
[ "${FAKE_PS_FAIL:-0}" != 1 ] || exit 71
if [ "$pid" = "${FAKE_OWNED_PID:-101}" ]; then printf '%s\n' "$FAKE_EXPECTED_EXECUTABLE"; else printf '%s\n' "${FAKE_OTHER_EXECUTABLE:-/tmp/debug/HerdrMenubar}"; fi
FAKE
  cat > "$case_dir/bin/kill" <<'FAKE'
#!/bin/bash
{
  printf 'argc=%s\n' "$#"
  for argument in "$@"; do printf 'arg=%s\n' "$argument"; done
  printf 'end\n'
} >> "$FAKE_LOG/kill"
[ "$#" -eq 2 ] || { echo "kill contract violation" >&2; exit 64; }
signal=$1; pid=$2
case "$signal" in -TERM|-KILL) ;; *) echo "kill signal contract violation" >&2; exit 64;; esac
case "$pid" in *[!0-9]*|'') echo "kill PID boundary violation" >&2; exit 64;; esac
[ "${FAKE_SIGNAL_FAIL:-0}" != 1 ] || exit 77
if [ "$signal" = -TERM ] && [ "${FAKE_TERM_IGNORED:-0}" != 1 ] && [ "${FAKE_STUBBORN:-0}" != 1 ]; then
  printf '%s\n' "$pid" >> "$FAKE_LOG/dead"
elif [ "$signal" = -KILL ] && [ "${FAKE_STUBBORN:-0}" != 1 ]; then
  printf '%s\n' "$pid" >> "$FAKE_LOG/dead"
fi
FAKE
  cat > "$case_dir/bin/sleep" <<'FAKE'
#!/bin/bash
exit 0
FAKE
  chmod +x "$case_dir/bin/"*
}

run_installer() {
  case_dir=$1; shift
  destination="$case_dir/Applications/Herdr Menubar.app"
  PATH="$case_dir/bin:/usr/bin:/bin" FAKE_LOG="$case_dir/log" \
    FAKE_EXPECTED_EXECUTABLE="$destination/Contents/MacOS/HerdrMenubar" \
    HERDR_INSTALL_DERIVED_DATA_DIR="$case_dir/derived data" HOME="$case_dir/home" \
    "$INSTALLER" "$@" 2>&1
}
run_uninstaller() {
  case_dir=$1; shift
  destination="$case_dir/Applications/Herdr Menubar.app"
  PATH="$case_dir/bin:/usr/bin:/bin" FAKE_LOG="$case_dir/log" \
    FAKE_EXPECTED_EXECUTABLE="$destination/Contents/MacOS/HerdrMenubar" \
    "$UNINSTALLER" "$@" 2>&1
}

# Success and argument boundaries, including the app path containing spaces.
case_dir="$TEST_ROOT/success"; make_fakes "$case_dir"
output=$(cd / && run_installer "$case_dir" --install-dir "$case_dir/Applications"); status=$?
if [ "$status" -eq 0 ] && assert_file "$case_dir/Applications/Herdr Menubar.app/Contents/MacOS/HerdrMenubar" \
  && assert_log_call "$case_dir/log/open" "$case_dir/Applications/Herdr Menubar.app" \
  && assert_log_call "$case_dir/log/pgrep" -x HerdrMenubar \
  && assert_contains "$(cat "$case_dir/log/xcodebuild")" "arg=$case_dir/derived data"; then pass "success preserves argument boundaries"; else fail "success preserves argument boundaries"; fi

# Build failure must not stop or alter the prior installation.
case_dir="$TEST_ROOT/build-failure"; make_fakes "$case_dir"; mkdir -p "$case_dir/Applications/Herdr Menubar.app"; printf old > "$case_dir/Applications/Herdr Menubar.app/old"
output=$(FAKE_XCODEBUILD_FAIL=1 run_installer "$case_dir" --no-launch --install-dir "$case_dir/Applications"); status=$?
if [ "$status" -ne 0 ] && assert_file "$case_dir/Applications/Herdr Menubar.app/old" && assert_not_path "$case_dir/log/kill"; then pass "build failure leaves prior install untouched"; else fail "build failure leaves prior install untouched"; fi

# A live lock owner rejects a concurrent installer without touching the app.
case_dir="$TEST_ROOT/concurrent"; make_fakes "$case_dir"; mkdir -p "$case_dir/Applications/.Herdr Menubar.install.lock" "$case_dir/Applications/Herdr Menubar.app"; printf '%s\n' "$$" > "$case_dir/Applications/.Herdr Menubar.install.lock/owner"; printf old > "$case_dir/Applications/Herdr Menubar.app/old"
output=$(run_installer "$case_dir" --no-launch --install-dir "$case_dir/Applications"); status=$?
if [ "$status" -ne 0 ] && assert_contains "$output" "another install or uninstall" && assert_file "$case_dir/Applications/Herdr Menubar.app/old"; then pass "concurrent install lock fails clearly"; else fail "concurrent install lock fails clearly"; fi

# A dead numeric owner is recovered exactly once and installation proceeds.
case_dir="$TEST_ROOT/stale-lock"; make_fakes "$case_dir"; mkdir -p "$case_dir/Applications/.Herdr Menubar.install.lock"; printf '99999999\n' > "$case_dir/Applications/.Herdr Menubar.install.lock/owner"
output=$(run_installer "$case_dir" --no-launch --install-dir "$case_dir/Applications"); status=$?
if [ "$status" -eq 0 ] && assert_file "$case_dir/Applications/Herdr Menubar.app/Contents/MacOS/HerdrMenubar" && assert_not_path "$case_dir/Applications/.Herdr Menubar.install.lock"; then pass "stale lock owner is recovered"; else fail "stale lock owner is recovered"; fi

# A malformed owner is never guessed stale or removed.
case_dir="$TEST_ROOT/invalid-lock"; make_fakes "$case_dir"; mkdir -p "$case_dir/Applications/.Herdr Menubar.install.lock"; printf 'not-a-pid\n' > "$case_dir/Applications/.Herdr Menubar.install.lock/owner"
output=$(run_installer "$case_dir" --no-launch --install-dir "$case_dir/Applications"); status=$?
if [ "$status" -ne 0 ] && assert_contains "$output" "invalid owner" && assert_file "$case_dir/Applications/.Herdr Menubar.install.lock/owner"; then pass "invalid lock owner requires manual cleanup"; else fail "invalid lock owner requires manual cleanup"; fi

# A destination appearing after backup must abort and preserve both it and the backup.
case_dir="$TEST_ROOT/race"; make_fakes "$case_dir"; mkdir -p "$case_dir/Applications/Herdr Menubar.app"; printf old > "$case_dir/Applications/Herdr Menubar.app/old"
output=$(FAKE_CREATE_RACE=1 FAKE_RACE_DESTINATION="$case_dir/Applications/Herdr Menubar.app" run_installer "$case_dir" --no-launch --install-dir "$case_dir/Applications"); status=$?
backup=$(find "$case_dir/Applications" -name '.Herdr Menubar.app.backup.*' -print | head -1)
if [ "$status" -ne 0 ] && assert_contains "$output" "reappeared" && assert_file "$case_dir/Applications/Herdr Menubar.app/raced-marker" && [ -n "$backup" ] && assert_file "$backup/old"; then pass "final destination race preserves backup"; else fail "final destination race preserves backup"; fi

# A dangling destination symlink is replaced as a link, without following its target.
case_dir="$TEST_ROOT/dangling"; make_fakes "$case_dir"; mkdir -p "$case_dir/Applications" "$case_dir/outside"; printf keep > "$case_dir/outside/keep"; ln -s "$case_dir/outside/missing" "$case_dir/Applications/Herdr Menubar.app"
output=$(run_installer "$case_dir" --no-launch --install-dir "$case_dir/Applications"); status=$?
if [ "$status" -eq 0 ] && [ ! -L "$case_dir/Applications/Herdr Menubar.app" ] && assert_file "$case_dir/Applications/Herdr Menubar.app/Contents/MacOS/HerdrMenubar" && assert_file "$case_dir/outside/keep"; then pass "dangling destination symlink is safely replaced"; else fail "dangling destination symlink is safely replaced"; fi

# Only the exact executable path is signaled; an unrelated same-name process is ignored.
case_dir="$TEST_ROOT/process-filter"; make_fakes "$case_dir"; mkdir -p "$case_dir/Applications/Herdr Menubar.app"
output=$(FAKE_PGREP_PIDS='101 202' run_installer "$case_dir" --no-launch --install-dir "$case_dir/Applications"); status=$?
if [ "$status" -eq 0 ] && assert_log_call "$case_dir/log/kill" -TERM 101 && [ "$(grep -c '^arg=202$' "$case_dir/log/kill")" -eq 0 ] \
  && assert_contains "$(cat "$case_dir/log/ps")" "arg=-p" && assert_contains "$(cat "$case_dir/log/pgrep")" "arg=HerdrMenubar"; then pass "signals only exact installed executable"; else fail "signals only exact installed executable"; fi

# A process that ignores TERM receives bounded KILL with intact PID boundary.
case_dir="$TEST_ROOT/force"; make_fakes "$case_dir"; mkdir -p "$case_dir/Applications/Herdr Menubar.app"
output=$(FAKE_PGREP_PIDS=101 FAKE_TERM_IGNORED=1 run_installer "$case_dir" --no-launch --install-dir "$case_dir/Applications"); status=$?
if [ "$status" -eq 0 ] && assert_contains "$output" "forcefully" && assert_contains "$(cat "$case_dir/log/kill")" "arg=-KILL" && assert_contains "$(cat "$case_dir/log/kill")" "arg=101"; then pass "bounded escalation force-kills exact process"; else fail "bounded escalation force-kills exact process"; fi

# A signal error aborts replacement and restores the prior destination.
case_dir="$TEST_ROOT/signal-failure"; make_fakes "$case_dir"; mkdir -p "$case_dir/Applications/Herdr Menubar.app"; printf old > "$case_dir/Applications/Herdr Menubar.app/old"
output=$(FAKE_PGREP_PIDS=101 FAKE_SIGNAL_FAIL=1 run_installer "$case_dir" --no-launch --install-dir "$case_dir/Applications"); status=$?
if [ "$status" -ne 0 ] && assert_contains "$output" "could not send -TERM" && assert_file "$case_dir/Applications/Herdr Menubar.app/old"; then pass "signal failure preserves prior install"; else fail "signal failure preserves prior install"; fi

# A process inspection error is not treated as process exit or swallowed.
case_dir="$TEST_ROOT/process-inspection-failure"; make_fakes "$case_dir"; mkdir -p "$case_dir/Applications/Herdr Menubar.app"; printf old > "$case_dir/Applications/Herdr Menubar.app/old"
output=$(FAKE_PGREP_PIDS="$$" FAKE_PS_FAIL=1 run_installer "$case_dir" --no-launch --install-dir "$case_dir/Applications"); status=$?
if [ "$status" -ne 0 ] && assert_contains "$output" "could not inspect running" && assert_file "$case_dir/Applications/Herdr Menubar.app/old"; then pass "process inspection failure preserves prior install"; else fail "process inspection failure preserves prior install"; fi

# A completed build with no product aborts before touching the prior destination.
case_dir="$TEST_ROOT/missing-product"; make_fakes "$case_dir"; mkdir -p "$case_dir/Applications/Herdr Menubar.app"; printf old > "$case_dir/Applications/Herdr Menubar.app/old"
output=$(FAKE_XCODEBUILD_NO_PRODUCT=1 run_installer "$case_dir" --no-launch --install-dir "$case_dir/Applications"); status=$?
if [ "$status" -ne 0 ] && assert_contains "$output" "was not found" && assert_file "$case_dir/Applications/Herdr Menubar.app/old" && assert_not_path "$case_dir/log/kill"; then pass "missing build product leaves prior install untouched"; else fail "missing build product leaves prior install untouched"; fi

# Launch failure is reported as failure but leaves the completed install in place.
case_dir="$TEST_ROOT/launch-failure"; make_fakes "$case_dir"
output=$(FAKE_OPEN_FAIL=1 run_installer "$case_dir" --install-dir "$case_dir/Applications"); status=$?
if [ "$status" -ne 0 ] && assert_file "$case_dir/Applications/Herdr Menubar.app/Contents/MacOS/HerdrMenubar" && assert_not_path "$case_dir/Applications/.Herdr Menubar.install.lock"; then pass "launch failure keeps completed install and releases lock"; else fail "launch failure keeps completed install and releases lock"; fi

# Cleanup never removes a lock path that was replaced after this process acquired it.
case_dir="$TEST_ROOT/replaced-lock"; make_fakes "$case_dir"
output=$(FAKE_REPLACE_LOCK=1 FAKE_LOCK_PATH="$case_dir/Applications/.Herdr Menubar.install.lock" run_installer "$case_dir" --install-dir "$case_dir/Applications"); status=$?
if [ "$status" -eq 0 ] && assert_file "$case_dir/Applications/.Herdr Menubar.install.lock/token" && assert_contains "$(cat "$case_dir/Applications/.Herdr Menubar.install.lock/token")" "replacement-token"; then pass "cleanup preserves replacement lock token"; else fail "cleanup preserves replacement lock token"; fi

# Option-looking values are rejected, while an explicitly relative dash path is accepted.
option_output=$("$INSTALLER" --install-dir --no-launch 2>&1); option_status=$?
case_dir="$TEST_ROOT/dash-path"; make_fakes "$case_dir"; mkdir -p "$case_dir/work"; output=$(cd "$case_dir/work" && run_installer "$case_dir" --no-launch --install-dir ./-Apps); dash_status=$?
if [ "$option_status" -eq 2 ] && assert_contains "$option_output" "requires" && [ "$dash_status" -eq 0 ] && assert_file "$case_dir/work/-Apps/Herdr Menubar.app/Contents/MacOS/HerdrMenubar"; then pass "option-looking value rejected and explicit dash path accepted"; else fail "option-looking value rejected and explicit dash path accepted"; fi

# Uninstall shares the lifecycle lock: a live holder blocks it, release permits it.
case_dir="$TEST_ROOT/uninstall-lock"; make_fakes "$case_dir"; mkdir -p "$case_dir/Applications/.Herdr Menubar.install.lock" "$case_dir/Applications/Herdr Menubar.app"; printf '%s\n' "$$" > "$case_dir/Applications/.Herdr Menubar.install.lock/owner"; printf keep > "$case_dir/Applications/Herdr Menubar.app/keep"
output=$(run_uninstaller "$case_dir" --install-dir "$case_dir/Applications"); locked_status=$?
rm -rf "$case_dir/Applications/.Herdr Menubar.install.lock"
_release_output=$(run_uninstaller "$case_dir" --install-dir "$case_dir/Applications"); released_status=$?
if [ "$locked_status" -ne 0 ] && assert_contains "$output" "another install or uninstall" && [ "$released_status" -eq 0 ] && assert_not_path "$case_dir/Applications/Herdr Menubar.app"; then pass "uninstall coordinates with install lock"; else fail "uninstall coordinates with install lock"; fi

# A process surviving TERM and KILL aborts uninstall and preserves the app.
case_dir="$TEST_ROOT/uninstall-stubborn"; make_fakes "$case_dir"; mkdir -p "$case_dir/Applications/Herdr Menubar.app"; printf keep > "$case_dir/Applications/Herdr Menubar.app/keep"
output=$(FAKE_PGREP_PIDS=101 FAKE_STUBBORN=1 run_uninstaller "$case_dir" --install-dir "$case_dir/Applications"); status=$?
if [ "$status" -ne 0 ] && assert_contains "$output" "still running" && assert_file "$case_dir/Applications/Herdr Menubar.app/keep" && assert_contains "$(cat "$case_dir/log/kill")" "arg=-KILL"; then pass "stubborn process aborts uninstall removal"; else fail "stubborn process aborts uninstall removal"; fi

# Uninstall uses the same exact-path filtering and safely removes a dangling link.
case_dir="$TEST_ROOT/uninstall"; make_fakes "$case_dir"; mkdir -p "$case_dir/Applications" "$case_dir/outside"; printf keep > "$case_dir/outside/keep"; ln -s "$case_dir/outside/missing" "$case_dir/Applications/Herdr Menubar.app"
output=$(FAKE_PGREP_PIDS='101 202' run_uninstaller "$case_dir" --install-dir "$case_dir/Applications"); status=$?
if [ "$status" -eq 0 ] && assert_not_path "$case_dir/Applications/Herdr Menubar.app" && assert_file "$case_dir/outside/keep" && assert_log_call "$case_dir/log/kill" -TERM 101; then pass "uninstall filters processes and removes dangling link"; else fail "uninstall filters processes and removes dangling link"; fi

printf '\n%d passed; %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
