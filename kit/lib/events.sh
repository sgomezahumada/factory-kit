# shellcheck shell=bash
# lib/events.sh — machine-readable run events for the panel, and the ways a run ends.
# Sourced by factory.sh. Events go to .factory/logs/events.jsonl, one JSON object per line.

EVENTS=".factory/logs/events.jsonl"
CURRENT_PHASE=""
ENDED=""
ON_STOP=""  # a function to call when the run stops early (factory.sh parks the run branch)
RUN_TIER=""  # 1, 2 or 3 once preflight knows it (same rule as the PR marker)

# Optional dashboard telemetry (docs/run-contract.md, "Telemetry"). Does nothing unless
# FACTORY_TELEMETRY_URL is set, and never fails or slows a run.
if [[ -f "${BASH_SOURCE[0]%/*}/telemetry.sh" ]]; then
  # shellcheck source=lib/telemetry.sh
  source "${BASH_SOURCE[0]%/*}/telemetry.sh"
else
  telemetry_init() { :; }  # an older checkout without the client
  telemetry_emit() { :; }
  telemetry_flush() { :; }
fi

# telemetry_resend: when a run ends, resend the whole run in the background. Events sent one by one
# can be lost on flaky venue Wi-Fi; the dashboard drops duplicates, so a resend is always safe.
telemetry_resend() {
  # shellcheck disable=SC2119  # telemetry_flush takes no arguments
  (telemetry_flush >/dev/null 2>&1 </dev/null &) >/dev/null 2>&1 || true
}

# emit <event> [key=value ...]: append one JSON line. Never fails the run.
emit() {
  local -a args=(-nc --arg event "$1" --argjson ts "$(date +%s)")
  # shellcheck disable=SC2016  # jq variables, not shell ones
  local filter='{ts: $ts, event: $event}' kv key ev="$1"
  shift
  for kv in "$@"; do
    key="${kv%%=*}"
    args+=(--arg "$key" "${kv#*=}")
    filter+=" + {$key: \$$key}"
  done
  jq "${args[@]}" "$filter" >>"$EVENTS" 2>/dev/null || true
  telemetry_emit "$ev" "$@"
}

# run_facts: sets RUN_FACTS to the model=/tier= pairs known so far (finish and fail carry them).
run_facts() {
  RUN_FACTS=()
  [[ -z "${MODEL:-}" ]] || RUN_FACTS+=(model="$MODEL")
  [[ -z "$RUN_TIER" ]] || RUN_FACTS+=(tier="$RUN_TIER")
}

# die <message lines...>: stop the run, tell the panel why.
die() {
  local msg="$1"
  printf '\n✗ %s\n' "$msg" >&2
  shift
  [[ $# -eq 0 ]] || printf '%s\n' "$@" >&2
  ENDED=1
  run_facts
  emit fail phase="$CURRENT_PHASE" reason="$msg" ${RUN_FACTS[@]+"${RUN_FACTS[@]}"}
  telemetry_resend
  [[ -z "$ON_STOP" ]] || "$ON_STOP"
  exit 1
}

finish_run() {
  ENDED=1
  run_facts
  emit finish "$@" ${RUN_FACTS[@]+"${RUN_FACTS[@]}"}
  telemetry_resend
}

# Any exit that is not a die() or finish_run() (Ctrl+C, a failed command) still tells the panel.
on_exit() {
  [[ -z "$ENDED" ]] || return 0
  ENDED=1
  if [[ -d .factory/logs ]]; then
    run_facts
    emit fail phase="$CURRENT_PHASE" reason="stopped: interrupted or a command failed" ${RUN_FACTS[@]+"${RUN_FACTS[@]}"}
    telemetry_resend
  fi
  [[ -z "$ON_STOP" ]] || "$ON_STOP"
}

install_traps() {
  trap on_exit EXIT
  trap 'exit 130' INT TERM
}
