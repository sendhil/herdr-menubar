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
# shellcheck source=scripts/lib.sh
. "$script_dir/lib.sh"
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
registration_list="$install_dir/.Herdr Menubar.registration.$$"

mkdir -p "$install_dir"
acquire_install_lock "$lock"

cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  rm -rf "$stage"
  rm -f "$registration_list"
  if [ -e "$backup" ] || [ -L "$backup" ]; then
    if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
      mv "$backup" "$destination" || true
    else
      echo "Previous installation retained at: $backup" >&2
    fi
  fi
  release_install_lock
  exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

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

# Validate the completed product before stopping or moving the installed app.
python3 "$script_dir/validate-widget-product.py" "$product"
codesign --verify --strict "$product/Contents/PlugIns/HerdrWidgets.appex"
codesign --verify --strict "$product"
python3 "$script_dir/validate-widget-product.py" --registration-candidates "$repo_root" "$product" > "$registration_list"

rm -rf "$stage" "$backup"
cp -R "$product" "$stage"

stop_running_app
if [ -e "$destination" ] || [ -L "$destination" ]; then
  mv "$destination" "$backup"
fi

if [ -e "$destination" ] || [ -L "$destination" ]; then
  echo "Error: installation destination reappeared before replacement: $destination" >&2
  exit 1
fi
mv "$stage" "$destination"

# Remove only this build product's registration; registering .appex directly
# with lsregister is unsupported. Keep existing desktop widget configurations.
lsregister_tool="${HERDR_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister}"
while IFS= read -r -d '' candidate; do
  if ! unregister_app "$candidate"; then
    echo "Error: widget registration failed for build copy: $candidate. Previous installation retained at: $backup" >&2
    exit 1
  fi
done < "$registration_list"
if ! unregister_app "$destination" ||
   ! "$lsregister_tool" -f -R "$destination" ||
   ! pluginkit -a "$destination/Contents/PlugIns/HerdrWidgets.appex"; then
  echo "Error: widget registration failed. The new app remains installed; any previous installation is retained at: $backup" >&2
  exit 1
fi
rm -rf "$backup"

echo "Installed Herdr Menubar at: $destination"
if [ "$launch" -eq 1 ]; then
  if ! open "$destination"; then
    echo "Error: installed Herdr Menubar, but could not launch it." >&2
    exit 1
  fi
  echo "Launched Herdr Menubar."
fi
