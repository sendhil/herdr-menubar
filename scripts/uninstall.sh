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
    --help)
      usage
      exit 0
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

destination="$install_dir/Herdr Menubar.app"
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

rm -rf "$destination"
echo "Removed Herdr Menubar from: $destination"
