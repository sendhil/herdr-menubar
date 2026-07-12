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
    --help)
      usage
      exit 0
      ;;
    --no-launch)
      launch=0
      shift
      ;;
    --install-dir)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "Error: --install-dir requires a directory." >&2
        exit 2
      fi
      install_dir=$2
      shift 2
      ;;
    *)
      echo "Error: Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
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

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
derived_data="${HERDR_INSTALL_DERIVED_DATA_DIR:-$repo_root/.build/InstallerDerivedData}"
product="$derived_data/Build/Products/Release/HerdrMenubar.app"
destination="$install_dir/Herdr Menubar.app"
stage="$install_dir/.Herdr Menubar.app.install.$$"
backup="$install_dir/.Herdr Menubar.app.backup.$$"

cleanup() {
  status=$?
  rm -rf "$stage"
  if [ -e "$backup" ]; then
    if [ ! -e "$destination" ]; then
      mv "$backup" "$destination" || true
    else
      rm -rf "$backup"
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

stop_running_app() {
  pkill -TERM -x HerdrMenubar >/dev/null 2>&1 || true

  attempts=0
  while pgrep -x HerdrMenubar >/dev/null 2>&1; do
    if [ "$attempts" -ge 49 ]; then
      echo "HerdrMenubar did not quit after 5 seconds; stopping it forcefully." >&2
      pkill -KILL -x HerdrMenubar >/dev/null 2>&1 || true
      break
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done
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

mkdir -p "$install_dir"
rm -rf "$stage" "$backup"
cp -R "$product" "$stage"
stop_running_app

if [ -e "$destination" ]; then
  mv "$destination" "$backup"
fi
mv "$stage" "$destination"
rm -rf "$backup"

echo "Installed Herdr Menubar at: $destination"
if [ "$launch" -eq 1 ]; then
  open "$destination"
  echo "Launched Herdr Menubar."
fi
