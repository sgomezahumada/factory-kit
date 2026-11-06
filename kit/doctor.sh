#!/usr/bin/env bash
# doctor.sh — is this laptop, and this fork, ready for ./factory.sh?
# Usage: ./doctor.sh   (run it until the last line says "doctor: all green")
#
# Every check prints "ok", or "FIX" with the exact command or step that fixes it.
# "WARN" lines are worth reading but do not block. Nothing here changes your code.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

FIXES=0
ok() { printf 'ok   %s\n' "$1"; }
fix() {
  printf 'FIX  %s: %s\n' "$1" "$2"
  FIXES=$((FIXES + 1))
}
warn() { printf 'WARN %s: %s\n' "$1" "$2"; }
# The sourced libraries call die and emit; here a die only ends the subshell it runs in.
die() {
  printf '%s\n' "$1" >&2
  exit 1
}
# shellcheck disable=SC2329  # called by the sourced libraries
emit() { :; }
# shellcheck source=lib/conf.sh
source lib/conf.sh
# shellcheck source=lib/github.sh
source lib/github.sh
# shellcheck source=lib/gates.sh
source lib/gates.sh
MODEL="claude-sonnet-5-5"  # until factory.conf is read
export GIT_TERMINAL_PROMPT=0  # a missing credential fails the check instead of waiting for a password

install_hint() {
  if [[ "$(uname)" == "Darwin" ]]; then echo "brew install $1"; else echo "sudo apt install $1"; fi
}

check_tools() {
  local missing="" tool
  for tool in git jq gh; do command -v "$tool" >/dev/null || missing+=" $tool"; done
  if [[ -n "$missing" ]]; then fix "tools" "$(install_hint "${missing# }")"; fi
  if ! command -v claude >/dev/null; then
    fix "tools" "install Claude Code: curl -fsSL https://claude.ai/install.sh | bash"
  fi
  if [[ -z "$missing" ]] && command -v claude >/dev/null; then ok "tools"; fi
}

check_claude() {
  local out
  if out="$(claude -p 'reply ok' --max-turns 1 --model "$MODEL" 2>&1)" && grep -qiw ok <<<"$out"; then
    ok "Claude login"
  else
    fix "Claude login" "run claude once, log in, then type /exit"
  fi
}

check_github() {
  if gh auth status >/dev/null 2>&1; then ok "GitHub login"; else fix "GitHub login" "gh auth login"; fi
  if git config --get-urlmatch credential.helper https://github.com >/dev/null 2>&1; then
    ok "git credentials"
  else
    fix "git credentials" "gh auth setup-git"
  fi
}

check_origin() {
  local url slug
  url="$(git config --get remote.origin.url || true)"
  if [[ "$url" == https://* ]]; then
    ok "origin is HTTPS"
    return
  fi
  slug="$(origin_slug)"
  fix "origin is HTTPS" "git remote set-url origin https://github.com/${slug:-<you>/<repo>}.git"
}

check_fork() {
  local up
  if up="$( (detect_upstream && echo "$UPSTREAM") 2>/dev/null)" && [[ -n "$up" ]]; then
    UPSTREAM="$up"
    ok "fork of $UPSTREAM"
  else
    UPSTREAM=""
    fix "fork" "fork the workshop repo on GitHub, then clone YOUR fork (gh repo fork <workshop repo> --clone)"
  fi
}

check_push() {
  if git push --dry-run -q origin main >/dev/null 2>&1; then
    ok "push to your fork"
  else
    fix "push" "git cannot push to origin: check origin is your fork, then gh auth setup-git"
  fi
}

check_conf() {  # returns 1 when factory.conf is unusable, so runtime and tests are skipped
  local msg
  if ! msg="$( (load_conf) 2>&1 >/dev/null)"; then
    fix "factory.conf" "${msg:-factory.conf could not be read}"
    return 1
  fi
  load_conf
  ok "factory.conf"
}

check_runtime() {
  [[ -n "$RUNTIME" ]] || return 0
  if command -v "$RUNTIME" >/dev/null; then
    ok "runtime ($RUNTIME)"
  else
    fix "runtime" "$RUNTIME is not installed (factory.conf RUNTIME); install it, then run ./doctor.sh again"
  fi
}

check_tests() {
  if bash -c "$TEST_CMD" >/dev/null 2>&1; then
    ok "tests pass ($TEST_CMD)"
  else
    if [[ -n "$SETUP" ]]; then
      fix "tests" "run  $SETUP  first, then ./doctor.sh again (if they still fail: $TEST_CMD)"
    else
      fix "tests" "the tests fail on this checkout: run  $TEST_CMD  to see why (or git pull upstream main)"
    fi
  fi
}

check_gates() {
  local problem
  if problem="$(check_gate_files)"; then ok "gates"; else fix "gates" "$problem"; fi
}

check_time_limit() {
  if command -v gtimeout >/dev/null || command -v timeout >/dev/null; then return 0; fi
  warn "phase time limit" "no timeout command, so a stuck phase never times out: $(install_hint coreutils)"
}

check_behind() {
  local behind
  [[ -n "$UPSTREAM" ]] || return 0
  git fetch -q upstream main 2>/dev/null || return 0
  behind="$(git rev-list --count main..upstream/main 2>/dev/null || echo 0)"
  if [[ "$behind" -gt 0 ]]; then
    warn "fork is behind" "the workshop repo has $behind new commit(s): git pull upstream main"
  fi
}

check_tools
CONF_OK=""
if check_conf; then CONF_OK=1; fi
check_claude
check_github
check_origin
check_fork
check_push
if [[ -n "$CONF_OK" ]]; then
  check_runtime
  check_tests
fi
check_gates
check_time_limit
check_behind

# Tells the workshop dashboard this laptop is ready. Silent and in the background: it never changes
# doctor's output or exit code, and does nothing unless FACTORY_TELEMETRY_URL is set.
say_hello() {
  [[ -n "${FACTORY_TELEMETRY_URL:-}" && -f lib/telemetry.sh ]] || return 0
  (bash lib/telemetry.sh hello >/dev/null 2>&1 </dev/null &) >/dev/null 2>&1 || true
}

if [[ "$FIXES" -eq 0 ]]; then
  echo "doctor: all green"
  say_hello
  exit 0
fi
echo "doctor: $FIXES thing(s) to fix, then run ./doctor.sh again"
exit 1
