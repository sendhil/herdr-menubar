#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/install.sh [--no-launch] [--install-dir DIR]

Build and install Herdr Menubar from this checkout.

Options:
  --no-launch       Install without launching the app.
  --install-dir DIR Install into DIR (default: ~/Applications).
  --help            Show this help.
USAGE
}

launch=1
install_dir="${HOME}/Applications"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help) usage; exit 0 ;;
    --no-launch) launch=0; shift ;;
    --install-dir)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "Error: --install-dir requires a directory." >&2
        exit 2
      fi
      case "$2" in
        -*) echo "Error: --install-dir requires a directory, not an option. Use ./-name for a directory beginning with a dash." >&2; exit 2 ;;
      esac
      install_dir=$2
      shift 2
      ;;
    *) echo "Error: Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! command -v xcodebuild >/dev/null 2>&1; then
  cat >&2 <<'ERROR'
Error: xcodebuild was not found. Install Xcode from the Mac App Store, or
install Apple's Command Line Tools with `xcode-select --install`, then ensure
an active developer directory is selected with `xcode-select -p`.
ERROR
  exit 1
fi

case "$install_dir" in
  /*) ;;
  *) install_dir="$(pwd)/$install_dir" ;;
esac

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
derived_data="${HERDR_INSTALL_DERIVED_DATA_DIR:-$repo_root/.build/InstallerDerivedData}"
case "$derived_data" in
  /*) ;;
  *) derived_data="$(pwd)/$derived_data" ;;
esac
product="$derived_data/Build/Products/Release/HerdrMenubar.app"
destination="$install_dir/Herdr Menubar.app"
executable="$destination/Contents/MacOS/HerdrMenubar"
stage="$install_dir/.Herdr Menubar.app.install.$$"
backup="$install_dir/.Herdr Menubar.app.backup.$$"
lock="$install_dir/.Herdr Menubar.install.lock"
lock_owner="$lock/owner"
lock_acquired=0

mkdir -p "$install_dir"
if ! mkdir "$lock" 2>/dev/null; then
  echo "Error: another install is already in progress for: $destination" >&2
  exit 1
fi
printf '%s\n' "$$" > "$lock_owner"
lock_acquired=1

cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  rm -rf "$stage"
  if [ -e "$backup" ] || [ -L "$backup" ]; then
    if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
      mv "$backup" "$destination" || true
    else
      echo "Previous installation retained at: $backup" >&2
    fi
  fi
  if [ "$lock_acquired" -eq 1 ] && [ -f "$lock_owner" ] && [ "$(cat "$lock_owner" 2>/dev/null || true)" = "$$" ]; then
    rm -rf "$lock"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

owned_pids() {
  pgrep -x HerdrMenubar 2>/dev/null | while IFS= read -r pid; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    command_path=$(ps -p "$pid" -o comm= 2>/dev/null) || continue
    command_path=${command_path#"${command_path%%[! ]*}"}
    if [ "$command_path" = "$executable" ]; then printf '%s\n' "$pid"; fi
  done
}

signal_owned() {
  signal=$1
  pids=$(owned_pids || true)
  [ -n "$pids" ] || return 1
  while IFS= read -r pid; do env kill "$signal" "$pid" >/dev/null 2>&1 || true; done <<EOF
$pids
EOF
  return 0
}

stop_running_app() {
  signal_owned -TERM || return 0
  attempts=0
  while [ "$attempts" -lt 50 ]; do
    remaining=$(owned_pids || true)
    [ -n "$remaining" ] || return 0
    attempts=$((attempts + 1))
    sleep 0.1
  done
  echo "HerdrMenubar did not quit after 5 seconds; stopping it forcefully." >&2
  signal_owned -KILL || true
}

mkdir -p "$derived_data"
rm -rf "$product"
echo "Building Herdr Menubar (Release)..."
xcodebuild build \
  -project "$repo_root/HerdrMenubar.xcodeproj" \
  -scheme HerdrMenubar \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data"

if [ ! -d "$product" ]; then
  echo "Error: xcodebuild completed but HerdrMenubar.app was not found at: $product" >&2
  exit 1
fi

rm -rf "$stage" "$backup"
cp -R "$product" "$stage"

if [ -e "$destination" ] || [ -L "$destination" ]; then
  mv "$destination" "$backup"
fi
stop_running_app

if [ -e "$destination" ] || [ -L "$destination" ]; then
  echo "Error: installation destination reappeared before replacement: $destination" >&2
  exit 1
fi
mv "$stage" "$destination"
rm -rf "$backup"

echo "Installed Herdr Menubar at: $destination"
if [ "$launch" -eq 1 ]; then
  if ! open "$destination"; then
    echo "Error: installed Herdr Menubar, but could not launch it." >&2
    exit 1
  fi
  echo "Launched Herdr Menubar."
fi
