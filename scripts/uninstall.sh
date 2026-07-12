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

destination="$install_dir/Herdr Menubar.app"
executable="$destination/Contents/MacOS/HerdrMenubar"

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

stop_running_app
rm -rf "$destination"
echo "Removed Herdr Menubar from: $destination"
