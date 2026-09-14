#!/bin/bash

# Shared installer lifecycle helpers. Callers must set destination and executable.

lock_acquired=0
lock_token=
lock_owner=
lock_token_file=

acquire_install_lock() {
  lock=$1
  lock_owner="$lock/owner"
  lock_token_file="$lock/token"
  lock_token="$$.$(date +%s)"

  if ! mkdir "$lock" 2>/dev/null; then
    if [ ! -d "$lock" ] || [ -L "$lock" ]; then
      echo "Error: install lock is not a directory: $lock. Remove it only after confirming no install or uninstall is running." >&2
      return 1
    fi
    owner=$(cat "$lock/owner" 2>/dev/null || true)
    case "$owner" in
      ''|*[!0-9]*)
        echo "Error: install lock has an invalid owner: $lock. Confirm no install or uninstall is running, then remove this lock manually." >&2
        return 1
        ;;
    esac
    if /bin/kill -0 "$owner" 2>/dev/null; then
      echo "Error: another install or uninstall (PID $owner) is already in progress for: $destination" >&2
      return 1
    fi

    stale_lock="$lock.stale.$$"
    if [ -e "$stale_lock" ] || [ -L "$stale_lock" ]; then
      echo "Error: stale-lock recovery path already exists: $stale_lock. Confirm no lifecycle command is running, remove that recovery path, and retry." >&2
      return 1
    fi
    if ! mv "$lock" "$stale_lock" 2>/dev/null; then
      echo "Error: stale install lock changed while recovering it: $lock. Retry the command." >&2
      return 1
    fi
    moved_owner=$(cat "$stale_lock/owner" 2>/dev/null || true)
    if [ "$moved_owner" != "$owner" ]; then
      echo "Error: install lock ownership changed while recovering it: $lock. Retry the command." >&2
      mv "$stale_lock" "$lock" 2>/dev/null || true
      return 1
    fi
    rm -rf "$stale_lock"
    if ! mkdir "$lock" 2>/dev/null; then
      echo "Error: another install or uninstall acquired the lock while stale-lock recovery was in progress for: $destination" >&2
      return 1
    fi
  fi

  if ! printf '%s\n' "$$" > "$lock_owner" || ! printf '%s\n' "$lock_token" > "$lock_token_file"; then
    rm -rf "$lock"
    echo "Error: could not record install lock ownership at: $lock" >&2
    return 1
  fi
  lock_acquired=1
}

release_install_lock() {
  [ "$lock_acquired" -eq 1 ] || return 0
  current_owner=$(cat "$lock_owner" 2>/dev/null || true)
  current_token=$(cat "$lock_token_file" 2>/dev/null || true)
  if [ "$current_owner" = "$$" ] && [ "$current_token" = "$lock_token" ]; then
    rm -rf "$lock"
  fi
  lock_acquired=0
}

owned_pids() {
  for process_name in HerdrMenubar HerdrWidgets; do
  if matches=$(pgrep -x "$process_name" 2>/dev/null); then
    pgrep_status=0
  else
    pgrep_status=$?
  fi
  if [ "$pgrep_status" -eq 1 ]; then continue; fi
  if [ "$pgrep_status" -ne 0 ]; then
    echo "Error: could not inspect HerdrMenubar processes with pgrep ($process_name)." >&2
    return 1
  fi

  while IFS= read -r pid; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    if ! command_path=$(ps -p "$pid" -o comm= 2>/dev/null); then
      if /bin/kill -0 "$pid" 2>/dev/null; then
        echo "Error: could not inspect running HerdrMenubar PID $pid with ps. The application was not changed; quit it and retry." >&2
        return 1
      fi
      continue
    fi
    command_path=${command_path#"${command_path%%[! ]*}"}
    if [ "$command_path" = "$executable" ] || [ "$command_path" = "$destination/Contents/PlugIns/HerdrWidgets.appex/Contents/MacOS/HerdrWidgets" ]; then printf '%s\n' "$pid"; fi
  done <<EOF
$matches
EOF
  done
}

signal_pids() {
  signal=$1
  pids=$2
  [ -n "$pids" ] || return 0
  while IFS= read -r pid; do
    if ! env kill "$signal" "$pid" >/dev/null 2>&1; then
      echo "Error: could not send $signal to Herdr Menubar PID $pid. The application was not changed; quit it and retry." >&2
      return 1
    fi
  done <<EOF
$pids
EOF
}

wait_for_owned_exit() {
  attempts=$1
  remaining=
  count=0
  while [ "$count" -lt "$attempts" ]; do
    remaining=$(owned_pids) || return 2
    [ -n "$remaining" ] || return 0
    count=$((count + 1))
    sleep 0.1
  done
  return 1
}

stop_running_app() {
  initial=$(owned_pids) || return 1
  [ -n "$initial" ] || return 0
  signal_pids -TERM "$initial" || return 1
  if wait_for_owned_exit 50; then
    return 0
  else
    wait_status=$?
    [ "$wait_status" -ne 2 ] || return 1
  fi

  remaining=$(owned_pids) || return 1
  [ -n "$remaining" ] || return 0
  echo "HerdrMenubar did not quit after 5 seconds; stopping it forcefully." >&2
  signal_pids -KILL "$remaining" || return 1
  if wait_for_owned_exit 50; then
    return 0
  else
    wait_status=$?
    [ "$wait_status" -ne 2 ] || return 1
  fi

  remaining=$(owned_pids) || return 1
  echo "Error: Herdr Menubar is still running from $destination (PID(s): $(printf '%s' "$remaining" | tr '\n' ' ')). The application was not changed; quit it and retry." >&2
  return 1
}

unregister_app() {
  local bundle=$1 output line absent=0 unexpected=0
  if output=$("$lsregister_tool" -u "$bundle" 2>&1); then return 0; fi
  # kLSApplicationNotFoundErr means this exact bundle is already unregistered.
  # Accept only the observed diagnostic and its optional Spotlight suffix;
  # similarly prefixed numeric codes and any additional errors remain fatal.
  while IFS= read -r line; do
    case "$line" in
      "failed to scan $bundle: -10814") absent=1 ;;
      " from spotlight"|'') ;;
      *) unexpected=1 ;;
    esac
  done <<EOF_DIAGNOSTIC
$output
EOF_DIAGNOSTIC
  if [ "$absent" -eq 1 ] && [ "$unexpected" -eq 0 ]; then return 0; fi
  printf '%s\n' "$output" >&2
  return 1
}
