#!/usr/bin/env bash
# Vendored from Emer-42/demo-factory-dashboard, client/telemetry.sh (commit 32ed9bf). Fixes go upstream first.
# telemetry.sh - jq-free telemetry client for the workshop dashboard (docs/SPEC.md, "Client").
#
# Source it from a factory script:
#   source ./telemetry.sh; telemetry_init .factory/logs; telemetry_emit run_start issue=12
# or run it:
#   ./telemetry.sh hello | whoami | flush <spool_file>
#
# Design rules:
#   * bash 3.2 compatible (macOS /bin/bash): no associative arrays, no ${v,,}, no bash-4 array builtins.
#   * safe under the caller's `set -euo pipefail`: every public function runs its body in an
#     `|| true` context (which suspends errexit inside) and always returns 0.
#   * FACTORY_TELEMETRY_URL unset => every function returns immediately.
#   * never changes shell options, never installs traps; globals are prefixed TELEMETRY_ / _TEL_.
#
# Env: FACTORY_TELEMETRY_URL, FACTORY_TELEMETRY_TOKEN, FACTORY_WORKSHOP [default],
#      FACTORY_PARTICIPANT, FACTORY_TELEMETRY_SHOWCASE (1 => showcase=1 on run_start),
#      FACTORY_NAME (client.factory override).

_TEL_RE_PART='^[A-Za-z0-9][A-Za-z0-9._-]{0,38}$'
_TEL_RE_WS='^[a-z0-9][a-z0-9-]{0,39}$'
_TEL_EVENTS=" hello run_start preflight phase_start phase_end scope gate verdict fail finish "
_TEL_ALLOW=" phase name after ok files value reason code result url issue cost_usd turns seconds gate message showcase upstream title branch verdict stopped_by cost tier model "

TELEMETRY_SPOOL=""
TELEMETRY_RUN_ID=""
TELEMETRY_SEQ=0
TELEMETRY_FLUSHED_SEQ=0
TELEMETRY_PARTICIPANT=""
_TEL_LINE=""
_TEL_J=""
_TEL_WORKSHOP="default"
_TEL_OS=""
_TEL_FACTORY=""

_tel_enabled() { [ -n "${FACTORY_TELEMETRY_URL:-}" ]; }

# _tel_esc <string>: sets _TEL_J to the JSON-escaped string (no surrounding quotes), truncated
# to 500 bytes. Works on bytes (LC_ALL=C); UTF-8 is passed through, invalid sequences are
# dropped with iconv -c when iconv exists (one bad byte would make the server reject a batch).
_tel_esc() {
  local LC_ALL=C
  # shellcheck disable=SC1003  # a lone backslash in single quotes is intended
  local s="${1-}" bs='\' dq='"' nl=$'\n' cr=$'\r' tab=$'\t' i c hex out
  s="${s:0:500}"
  s="${s//"$bs"/$bs$bs}"
  s="${s//"$dq"/$bs$dq}"
  s="${s//"$nl"/${bs}n}"
  s="${s//"$cr"/${bs}r}"
  s="${s//"$tab"/${bs}t}"
  case "$s" in
    *[[:cntrl:]]*)
      out=""
      i=0
      while [ "$i" -lt "${#s}" ]; do
        c="${s:$i:1}"
        case "$c" in
          [[:cntrl:]]) printf -v hex '\\u%04x' "'$c"; out="$out$hex" ;;
          *) out="$out$c" ;;
        esac
        i=$((i + 1))
      done
      s="$out"
      ;;
  esac
  case "$s" in
    *[![:print:]]*)
      if command -v iconv >/dev/null 2>&1; then
        out="$(printf '%s.' "$s" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)" && s="${out%.}"
      fi
      ;;
  esac
  _TEL_J="$s"
}

_tel_uuid() {
  local u=""
  if command -v uuidgen >/dev/null 2>&1; then
    u="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')" || u=""
  fi
  if [ -z "$u" ] && [ -r /proc/sys/kernel/random/uuid ]; then
    u="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)" || u=""
  fi
  if [ -z "$u" ]; then
    printf -v u '%04x%04x-%04x-%04x-%04x-%04x%04x%04x' \
      "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM"
  fi
  printf '%s' "$u"
}

_tel_valid_participant() { [[ "${1-}" =~ $_TEL_RE_PART ]]; }

# gh api user, hard-capped at ~3 s (no dependency on timeout/gtimeout).
_tel_gh_login() {
  command -v gh >/dev/null 2>&1 || return 1
  local tmp pid n=0 out=""
  tmp="$(mktemp 2>/dev/null)" || return 1
  gh api user -q .login >"$tmp" 2>/dev/null </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$n" -ge 30 ]; then
      kill "$pid" 2>/dev/null
      break
    fi
    sleep 0.1
    n=$((n + 1))
  done
  wait "$pid" 2>/dev/null
  read -r out <"$tmp" 2>/dev/null
  rm -f "$tmp"
  [ -n "$out" ] && printf '%s' "$out"
}

# Sets TELEMETRY_PARTICIPANT: env override, cache file, gh login, anon-<6 hex of a hostname checksum>.
_tel_resolve_identity() {
  local p="${FACTORY_PARTICIPANT:-}" cache_dir cache h=""
  if [ -n "$p" ] && ! _tel_valid_participant "$p"; then p=""; fi
  if [ -z "$p" ]; then
    cache_dir="${XDG_CACHE_HOME:-}"
    if [ -z "$cache_dir" ] && [ -n "${HOME:-}" ]; then cache_dir="$HOME/.cache"; fi
    cache=""
    [ -n "$cache_dir" ] && cache="$cache_dir/factory-telemetry/participant"
    if [ -n "$cache" ] && [ -r "$cache" ]; then
      read -r p <"$cache" 2>/dev/null
      _tel_valid_participant "$p" || p=""
    fi
    if [ -z "$p" ]; then
      p="$(_tel_gh_login)" || p=""
      if _tel_valid_participant "$p"; then
        if [ -n "$cache" ]; then
          { mkdir -p "$cache_dir/factory-telemetry" && printf '%s\n' "$p" >"$cache"; } 2>/dev/null
        fi
      else
        p=""
      fi
    fi
  fi
  if [ -z "$p" ]; then
    # cksum is POSIX (same on macOS and Linux); kit-local change: not every Linux has the macOS hash tool.
    h="$(hostname 2>/dev/null | cksum 2>/dev/null | cut -d' ' -f1)"
    if [ -n "$h" ]; then printf -v h '%06x' $((h % 16777216)); else h="000000"; fi
    p="anon-$h"
  fi
  TELEMETRY_PARTICIPANT="$p"
}

_tel_post_headers_and_send() {  # $1 = curl -m seconds, $2 = data source ("@-" or "@file"); extra curl args after
  local m="$1" data="$2"
  shift 2
  if [ -n "${FACTORY_TELEMETRY_TOKEN:-}" ]; then
    # Header via process substitution (printf is a builtin): the token never appears in `ps` argv.
    curl -sS -m "$m" -X POST -H 'Content-Type: application/x-ndjson' \
      -H @<(printf 'Authorization: Bearer %s\n' "${FACTORY_TELEMETRY_TOKEN}") --data-binary "$data" "$@" \
      "${FACTORY_TELEMETRY_URL%/}/v1/events"
  else
    curl -sS -m "$m" -X POST -H 'Content-Type: application/x-ndjson' \
      --data-binary "$data" "$@" "${FACTORY_TELEMETRY_URL%/}/v1/events"
  fi
}

_tel_init_impl() {
  _tel_enabled || return 0
  local dir="${1:-}" ws
  [ -n "$dir" ] || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  TELEMETRY_SPOOL="$dir/telemetry.jsonl"
  : >"$TELEMETRY_SPOOL" 2>/dev/null || { TELEMETRY_SPOOL=""; return 0; }
  TELEMETRY_RUN_ID="$(_tel_uuid)"
  TELEMETRY_SEQ=0
  TELEMETRY_FLUSHED_SEQ=0
  _tel_resolve_identity
  ws="$(printf '%s' "${FACTORY_WORKSHOP:-default}" | tr '[:upper:]' '[:lower:]')"
  [[ "$ws" =~ $_TEL_RE_WS ]] || ws="default"
  _TEL_WORKSHOP="$ws"
  _TEL_OS="$(uname -s 2>/dev/null)" || _TEL_OS=""
  if [ -n "${FACTORY_NAME:-}" ]; then
    _TEL_FACTORY="$FACTORY_NAME"
  else
    _TEL_FACTORY="$(basename "$(cd "$(dirname "${0:-.}")" 2>/dev/null && pwd)" 2>/dev/null)" || _TEL_FACTORY=""
    [ -n "$_TEL_FACTORY" ] || _TEL_FACTORY="$(basename "$PWD")"
  fi
}

# _tel_build <event> [k=v ...]: sets _TEL_LINE, appends it to the spool, bumps seq.
_tel_build() {
  local ev="${1:-}" kv key val attrs="" seen=" " sep="" ts
  [ -n "$ev" ] || return 1
  shift
  case "$_TEL_EVENTS" in *" $ev "*) ;; *) return 1 ;; esac
  for kv in "$@"; do
    case "$kv" in *=*) ;; *) continue ;; esac
    key="${kv%%=*}"
    val="${kv#*=}"
    case "$_TEL_ALLOW" in *" $key "*) ;; *) continue ;; esac
    case "$seen" in *" $key "*) continue ;; esac
    seen="$seen$key "
    _tel_esc "$val"
    attrs="$attrs$sep\"$key\":\"$_TEL_J\""
    sep=","
  done
  if [ "$ev" = "run_start" ] && [ "${FACTORY_TELEMETRY_SHOWCASE:-}" = "1" ]; then
    case "$seen" in *" showcase "*) ;; *) attrs="$attrs$sep\"showcase\":\"1\"" ;; esac
  fi
  ts="$(date +%s 2>/dev/null)" || ts=0
  _tel_esc "$_TEL_FACTORY"; local f="$_TEL_J"
  _tel_esc "$_TEL_OS"; local o="$_TEL_J"
  printf -v _TEL_LINE '{"v":1,"workshop":"%s","run_id":"%s","seq":%s,"ts":%s,"participant":"%s","event":"%s","attrs":{%s},"client":{"factory":"%s","os":"%s"}}' \
    "$_TEL_WORKSHOP" "$TELEMETRY_RUN_ID" "$TELEMETRY_SEQ" "$ts" "$TELEMETRY_PARTICIPANT" "$ev" "$attrs" "$f" "$o"
  TELEMETRY_SEQ=$((TELEMETRY_SEQ + 1))
  printf '%s\n' "$_TEL_LINE" >>"$TELEMETRY_SPOOL" 2>/dev/null
  return 0
}

_tel_emit_impl() {
  _tel_enabled || return 0
  [ -n "$TELEMETRY_SPOOL" ] || return 0
  command -v curl >/dev/null 2>&1 || { _tel_build "$@" || true; return 0; }
  _tel_build "$@" || return 0
  # Fully detached: subshell + background + all fds redirected, so the factory never waits.
  (
    { printf '%s\n' "$_TEL_LINE" | _tel_post_headers_and_send 3 @- --connect-timeout 2; } \
      >/dev/null 2>&1 </dev/null &
  ) >/dev/null 2>&1
  return 0
}

_tel_flush_impl() {
  _tel_enabled || return 0
  [ -n "$TELEMETRY_SPOOL" ] && [ -s "$TELEMETRY_SPOOL" ] || return 0
  [ "$TELEMETRY_SEQ" -gt "$TELEMETRY_FLUSHED_SEQ" ] || return 0   # nothing new since the last flush
  TELEMETRY_FLUSHED_SEQ="$TELEMETRY_SEQ"
  command -v curl >/dev/null 2>&1 || return 0
  _tel_post_headers_and_send 5 "@$TELEMETRY_SPOOL" --connect-timeout 3 >/dev/null 2>&1 </dev/null
  return 0
}

_tel_stats_impl() {
  local f="${1:-}" line cost turns ms out=""
  [ -n "$f" ] && [ -r "$f" ] || return 0
  line="$(grep '"type": *"result"' "$f" 2>/dev/null | tail -n 1)" || line=""
  [ -n "$line" ] || return 0
  cost="$(printf '%s\n' "$line" | grep -o '"total_cost_usd": *[0-9][0-9.eE+-]*' | head -n 1 | sed 's/.*: *//')" || cost=""
  turns="$(printf '%s\n' "$line" | grep -o '"num_turns": *[0-9][0-9]*' | head -n 1 | sed 's/.*: *//')" || turns=""
  ms="$(printf '%s\n' "$line" | grep -o '"duration_ms": *[0-9][0-9]*' | head -n 1 | sed 's/.*: *//')" || ms=""
  [ -n "$cost" ] && out="cost_usd=$cost"
  [ -n "$turns" ] && out="${out:+$out }turns=$turns"
  [ -n "$ms" ] && out="${out:+$out }seconds=$(((ms + 500) / 1000))"
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# ---- public API: errexit-proof wrappers ------------------------------------------------------
telemetry_init() { _tel_init_impl "$@" || true; return 0; }
telemetry_emit() { _tel_emit_impl "$@" || true; return 0; }
telemetry_flush() { _tel_flush_impl "$@" || true; return 0; }
telemetry_phase_stats() { _tel_stats_impl "$@" || true; return 0; }

# ---- CLI -------------------------------------------------------------------------------------
_tel_status_word() {  # http code -> accepted|unreachable|rejected (<code>)
  case "$1" in
    2??) printf 'accepted' ;;
    000|"") printf 'unreachable' ;;
    *) printf 'rejected (%s)' "$1" ;;
  esac
}

_tel_cli() {
  local cmd="${1:-}" tmp code spool
  case "$cmd" in
    whoami)
      _tel_resolve_identity
      printf '%s\n' "$TELEMETRY_PARTICIPANT"
      ;;
    hello)
      if ! _tel_enabled; then
        _tel_resolve_identity
        printf 'participant: %s, server: disabled (FACTORY_TELEMETRY_URL is not set)\n' "$TELEMETRY_PARTICIPANT"
        return 0
      fi
      tmp="$(mktemp -d 2>/dev/null)" || tmp=""
      if [ -z "$tmp" ]; then printf 'participant: ?, server: unreachable (no temp dir)\n'; return 0; fi
      _tel_init_impl "$tmp" || true
      _tel_build hello || true
      code="$(printf '%s\n' "$_TEL_LINE" | _tel_post_headers_and_send 5 @- --connect-timeout 3 \
        -o /dev/null -w '%{http_code}' 2>/dev/null)" || code=""
      printf 'participant: %s, server: %s\n' "$TELEMETRY_PARTICIPANT" "$(_tel_status_word "$code")"
      rm -rf "$tmp"
      ;;
    flush)
      spool="${2:-}"
      if [ -z "$spool" ] || [ ! -r "$spool" ]; then printf 'usage: telemetry.sh flush <spool_file>\n' >&2; return 2; fi
      if ! _tel_enabled; then printf 'telemetry disabled (FACTORY_TELEMETRY_URL is not set)\n'; return 0; fi
      code="$(_tel_post_headers_and_send 5 "@$spool" --connect-timeout 3 -o /dev/null -w '%{http_code}' 2>/dev/null)" || code=""
      printf 'flush %s (%s lines): %s\n' "$spool" "$(wc -l <"$spool" | tr -d ' ')" "$(_tel_status_word "$code")"
      ;;
    *)
      printf 'usage: telemetry.sh hello | whoami | flush <spool_file>\n' >&2
      return 2
      ;;
  esac
  return 0
}

if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  _tel_cli "$@"
  exit $?
fi
