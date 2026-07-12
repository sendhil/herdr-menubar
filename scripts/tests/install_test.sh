#!/bin/bash
set -u

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
INSTALLER="$REPO_ROOT/scripts/install.sh"
UNINSTALLER="$REPO_ROOT/scripts/uninstall.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/herdr-install-tests.XXXXXX") || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT

passed=0
failed=0

pass() {
  passed=$((passed + 1))
  printf 'ok - %s\n' "$1"
}

fail() {
  failed=$((failed + 1))
  printf 'not ok - %s\n' "$1" >&2
}

assert_file() {
  if [ -e "$1" ]; then return 0; fi
  printf 'Expected file to exist: %s\n' "$1" >&2
  return 1
}

assert_not_file() {
  if [ ! -e "$1" ]; then return 0; fi
  printf 'Expected file not to exist: %s\n' "$1" >&2
  return 1
}

assert_contains() {
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  printf 'Expected output to contain %s, got:\n%s\n' "$2" "$1" >&2
  return 1
}

make_fakes() {
  case_dir=$1
  mkdir -p "$case_dir/bin"
  cat > "$case_dir/bin/xcodebuild" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_LOG/xcodebuild"
derived=
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-derivedDataPath" ]; then
    shift
    derived=$1
  fi
  shift
done
if [ "${FAKE_XCODEBUILD_FAIL:-0}" = 1 ]; then exit 65; fi
if [ "${FAKE_XCODEBUILD_NO_PRODUCT:-0}" != 1 ]; then
  mkdir -p "$derived/Build/Products/Release/HerdrMenubar.app/Contents/MacOS"
  printf '#!/bin/sh\n' > "$derived/Build/Products/Release/HerdrMenubar.app/Contents/MacOS/HerdrMenubar"
fi
FAKE
  cat > "$case_dir/bin/open" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_LOG/open"
FAKE
  cat > "$case_dir/bin/pkill" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_LOG/pkill"
exit 1
FAKE
  chmod +x "$case_dir/bin/xcodebuild" "$case_dir/bin/open" "$case_dir/bin/pkill"
}

run_installer() {
  case_dir=$1
  shift
  mkdir -p "$case_dir/log"
  PATH="$case_dir/bin:/usr/bin:/bin" \
    FAKE_LOG="$case_dir/log" \
    HERDR_INSTALL_DERIVED_DATA_DIR="$case_dir/derived data" \
    HOME="$case_dir/home" \
    "$INSTALLER" "$@" 2>&1
}

# Successful installs build Release from any caller cwd and launch the spaced app path.
case_dir="$TEST_ROOT/success"
make_fakes "$case_dir"
output=$(cd / && run_installer "$case_dir" --install-dir "$case_dir/Applications")
status=$?
if [ "$status" -eq 0 ] \
  && assert_file "$case_dir/Applications/Herdr Menubar.app/Contents/MacOS/HerdrMenubar" \
  && assert_contains "$(cat "$case_dir/log/xcodebuild")" "-configuration Release" \
  && assert_contains "$(cat "$case_dir/log/xcodebuild")" "-project $REPO_ROOT/HerdrMenubar.xcodeproj" \
  && assert_contains "$(cat "$case_dir/log/xcodebuild")" "platform=macOS" \
  && assert_contains "$(cat "$case_dir/log/open")" "$case_dir/Applications/Herdr Menubar.app"; then
  pass "success builds Release, installs, and launches"
else
  fail "success builds Release, installs, and launches"
fi

# --no-launch must not invoke open.
case_dir="$TEST_ROOT/no-launch"
make_fakes "$case_dir"
output=$(run_installer "$case_dir" --no-launch --install-dir "$case_dir/Apps")
status=$?
if [ "$status" -eq 0 ] && assert_not_file "$case_dir/log/open"; then
  pass "--no-launch suppresses launch"
else
  fail "--no-launch suppresses launch"
fi

# A successful xcodebuild without an app product must fail clearly.
case_dir="$TEST_ROOT/no-product"
make_fakes "$case_dir"
output=$(FAKE_XCODEBUILD_NO_PRODUCT=1 run_installer "$case_dir" --no-launch --install-dir "$case_dir/Apps")
status=$?
if [ "$status" -ne 0 ] && assert_contains "$output" "HerdrMenubar.app" && assert_not_file "$case_dir/Apps/Herdr Menubar.app"; then
  pass "missing build product fails"
else
  fail "missing build product fails"
fi

# Missing xcodebuild must give an actionable Xcode message.
case_dir="$TEST_ROOT/no-xcode"
make_fakes "$case_dir"
rm "$case_dir/bin/xcodebuild"
output=$(PATH="$case_dir/bin:/bin" FAKE_LOG="$case_dir/log" HOME="$case_dir/home" \
  "$INSTALLER" --no-launch --install-dir "$case_dir/Apps" 2>&1)
status=$?
if [ "$status" -ne 0 ] && assert_contains "$output" "Xcode" && assert_contains "$output" "xcode-select --install"; then
  pass "missing xcodebuild is actionable"
else
  fail "missing xcodebuild is actionable"
fi

# Help succeeds; unknown and missing option values fail.
output=$("$INSTALLER" --help 2>&1); help_status=$?
unknown_output=$("$INSTALLER" --wat 2>&1); unknown_status=$?
missing_output=$("$INSTALLER" --install-dir 2>&1); missing_status=$?
if [ "$help_status" -eq 0 ] && assert_contains "$output" "--no-launch" \
  && [ "$unknown_status" -ne 0 ] && assert_contains "$unknown_output" "Unknown option" \
  && [ "$missing_status" -ne 0 ] && assert_contains "$missing_output" "requires"; then
  pass "argument parsing handles help and errors"
else
  fail "argument parsing handles help and errors"
fi

# Paths with spaces and replacement of an existing app are safe.
case_dir="$TEST_ROOT/path with spaces"
make_fakes "$case_dir"
mkdir -p "$case_dir/My Applications/Herdr Menubar.app"
printf old > "$case_dir/My Applications/Herdr Menubar.app/old-marker"
output=$(run_installer "$case_dir" --no-launch --install-dir "$case_dir/My Applications")
status=$?
if [ "$status" -eq 0 ] \
  && assert_file "$case_dir/My Applications/Herdr Menubar.app/Contents/MacOS/HerdrMenubar" \
  && assert_not_file "$case_dir/My Applications/Herdr Menubar.app/old-marker" \
  && assert_contains "$(cat "$case_dir/log/pkill")" "HerdrMenubar"; then
  pass "spaces and existing installation replacement"
else
  fail "spaces and existing installation replacement"
fi

# Uninstall removes only the installed app and attempts a graceful stop.
case_dir="$TEST_ROOT/uninstall"
make_fakes "$case_dir"
mkdir -p "$case_dir/Apps/Herdr Menubar.app" "$case_dir/Apps/Keep.app" "$case_dir/log"
output=$(PATH="$case_dir/bin:/usr/bin:/bin" FAKE_LOG="$case_dir/log" "$UNINSTALLER" --install-dir "$case_dir/Apps" 2>&1)
status=$?
if [ "$status" -eq 0 ] \
  && assert_not_file "$case_dir/Apps/Herdr Menubar.app" \
  && assert_file "$case_dir/Apps/Keep.app" \
  && assert_contains "$(cat "$case_dir/log/pkill")" "HerdrMenubar"; then
  pass "uninstall cleans up only Herdr Menubar"
else
  fail "uninstall cleans up only Herdr Menubar"
fi

printf '\n%d passed; %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
