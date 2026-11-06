# shellcheck shell=bash
# lib/conf.sh — reads factory.conf and builds the permission lists each phase gets.
# Sourced by factory.sh and doctor.sh (which provide die). Bash 3.2 compatible.

# Paths no phase may edit: the factory, its rules, the panel. Directories get /**.
PROTECTED_FILES=(factory.sh factory.conf AGENTS.md doctor.sh .gitignore)
PROTECTED_DIRS=(lib gates prompts dashboard .claude .git)

# load_conf: source ./factory.conf, apply defaults and FACTORY_* overrides, extend PATH.
load_conf() {
  [[ -f factory.conf ]] || die "factory.conf not found here: run this from the repo root (cd into your fork)"
  TEST_CMD="" LINT_CMD="" SCOPE="" MODEL="claude-sonnet-5-5" MAX_TURNS=40 PHASE_TIMEOUT=300
  GATE_TIMEOUT=60 PATH_PREPEND="" PROTECT_EXTRA="" RUNTIME="" SETUP=""
  # shellcheck disable=SC1091
  source ./factory.conf
  [[ -n "$TEST_CMD" ]] || die "factory.conf: TEST_CMD is required (the command that runs the tests)"
  [[ -n "$SCOPE" ]] || die "factory.conf: SCOPE is required (the paths agents may change, e.g. SCOPE=\"app/ tests/\")"
  MODEL="${FACTORY_MODEL:-$MODEL}"
  MAX_TURNS="${FACTORY_MAX_TURNS:-$MAX_TURNS}"
  PHASE_TIMEOUT="${FACTORY_TIMEOUT:-$PHASE_TIMEOUT}"
  local entry
  local -a prepend=()
  read -r -a prepend <<<"$PATH_PREPEND"
  for entry in ${prepend[@]+"${prepend[@]}"}; do
    PATH="$(pwd)/${entry%/}:$PATH"
  done
  export PATH
}

_split() {  # _split "$words" -> one word per line, no globbing
  local -a words=()
  read -r -a words <<<"$1"
  [[ ${#words[@]} -eq 0 ]] || printf '%s\n' "${words[@]}"
}

_rules_for() {  # Edit and Write rules for a path; a directory or a trailing / gets /**
  local p="$1"
  if [[ "$p" == */ || -d "$p" ]]; then p="${p%/}/**"; fi
  printf '%s\n' "Edit($p)" "Write($p)"
}

_run_cmds() {
  echo "Bash($TEST_CMD:*)"  # a prefix rule: agents may target one test file
  [[ -z "$LINT_CMD" ]] || echo "Bash($LINT_CMD)"
}

# allowed_tools <phase>: the shell commands a phase may run, one rule per line.
allowed_tools() {
  local base="${FACTORY_BASE_REF:-main}"
  case "$1" in
    1) echo "Bash(gh issue view:*)" ;;
    2) _run_cmds ;;
    3 | 4)
      _run_cmds
      printf '%s\n' "Bash(git diff $base)" "Bash(git diff --stat $base)" "Bash(git diff --name-only $base)"
      ;;
  esac
}

# denied_tools <phase>: protected paths for every phase; the reviewer also may not edit SCOPE.
denied_tools() {
  local p
  for p in "${PROTECTED_FILES[@]}"; do printf '%s\n' "Edit($p)" "Write($p)"; done
  for p in "${PROTECTED_DIRS[@]}"; do printf '%s\n' "Edit($p/**)" "Write($p/**)"; done
  while IFS= read -r p; do _rules_for "$p"; done < <(_split "$PROTECT_EXTRA")
  printf '%s\n' "Bash(rm:*)" "Bash(mv:*)" "Bash(cp:*)"
  if [[ "$1" == 4 ]]; then
    while IFS= read -r p; do _rules_for "$p"; done < <(_split "$SCOPE")
  fi
}

# in_scope <path>: exit 0 when the path is one of SCOPE's entries or inside one.
in_scope() {
  local p
  while IFS= read -r p; do
    p="${p%/}"
    if [[ "$1" == "$p" || "$1" == "$p/"* ]]; then return 0; fi
  done < <(_split "$SCOPE")
  return 1
}
