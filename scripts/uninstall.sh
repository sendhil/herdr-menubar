#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/uninstall.sh [--install-dir DIR]

Remove Herdr Menubar (default: ~/Applications/Herdr Menubar.app).
USAGE
}

install_dir="${HOME}/Applications"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help) usage; exit 0 ;;
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
case "$install_dir" in
  /*) ;;
  *) install_dir="$(pwd)/$install_dir" ;;
esac

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/lib.sh
. "$script_dir/lib.sh"

destination="$install_dir/Herdr Menubar.app"
executable="$destination/Contents/MacOS/HerdrMenubar"
lock="$install_dir/.Herdr Menubar.install.lock"

mkdir -p "$install_dir"
acquire_install_lock "$lock"
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  release_install_lock
  exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

stop_running_app
rm -rf "$destination"
echo "Removed Herdr Menubar from: $destination"
