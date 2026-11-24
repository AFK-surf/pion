# Sourced by test-linux.sh / test-windows.sh: overlapped background gate steps.
#
#   bg_start <log> <cmd...>   start <cmd> with output in <log>; its pid is $BG_PID
#   bg_kill <pid>...          stop steps that are still running (empty pid: none)
#   bg_join <pid> <log>       wait for a step, print its log, return its status
#
# A step runs in its own session when setsid exists, so bg_kill stops the whole
# process group (compilers and assemblers it started included).
bg_start() {
  BG_LOG="$1"
  shift
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" > "$BG_LOG" 2>&1 &
  else
    "$@" > "$BG_LOG" 2>&1 &
  fi
  BG_PID=$!
}

bg_kill() {
  for BG_P in "$@"; do
    [ -n "$BG_P" ] || continue
    kill -TERM -- -"$BG_P" 2>/dev/null || kill "$BG_P" 2>/dev/null || true
    wait "$BG_P" 2>/dev/null || true
  done
}

bg_join() {
  BG_RC=0
  wait "$1" || BG_RC=$?
  cat "$2"
  return "$BG_RC"
}
