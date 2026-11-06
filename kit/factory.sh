#!/usr/bin/env bash
# factory.sh — the workshop software factory.
# Usage: ./factory.sh <issue-number>
#
# Each phase is a FRESH claude session; state travels only through .factory/ files.
# What you change lives elsewhere: AGENTS.md (context), gates/ (your checks), prompts/ (the phases),
# factory.conf (test and lint commands, scope, model). This engine stays the same in every repo.
#
# Optional env:
#   FACTORY_NO_PUSH=1    commit locally, skip push + PR (rehearsals)
#   FACTORY_MODEL=<id>   override MODEL from factory.conf
#   FACTORY_MAX_TURNS=N  override MAX_TURNS (default 40)
#   FACTORY_TIMEOUT=N    seconds per phase (default 300), needs timeout or gtimeout
set -euo pipefail

ISSUE="${1:-}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
# shellcheck source=lib/events.sh
source lib/events.sh
# shellcheck source=lib/conf.sh
source lib/conf.sh
# shellcheck source=lib/gates.sh
source lib/gates.sh
# shellcheck source=lib/github.sh
source lib/github.sh

FACTORY_BASE_REF="main"
FACTORY_BASE=""
UPSTREAM=""
ISSUE_TITLE=""
BRANCH=""
STOPPED_BY=""
TOTAL_TURNS=0
TOTAL_COST=0
PHASE_TURNS=0
PHASE_COST=0
PHASE_SECONDS=0

# Appended to every prompt: chained commands are checked part by part and get denied.
SHELL_RULE="Run exactly one shell command per Bash call, with no ;, &&, || or pipes. Use the Read tool to read files."

# Turns the stream-json log into one readable line per action.
# shellcheck disable=SC2016  # $root is a jq variable
FILTER='
def short: tostring | ltrimstr($root) | gsub("\\s+"; " ") | if length > 110 then .[0:110] + "…" else . end;
if .type == "assistant" then
  .message.content[]?
  | if .type == "tool_use" then
      "  → \(.name)  \((.input.command // .input.file_path // .input.pattern // .input.path // "") | short)"
    elif .type == "text" and (.text | length) > 0 then
      "\n\(.text)\n"
    else empty end
elif .type == "user" then
  .message.content
  | if type == "array" then .[] else empty end
  | select(type == "object" and .type == "tool_result" and .is_error == true)
  | "  ✗ \(.content | if type == "array" then map(.text? // "") | join(" ") else . end | short)"
elif .type == "result" then
  "  ✓ \(.subtype) · \(.num_turns) turns · \(.duration_ms / 1000 | floor)s · $\((.total_cost_usd // 0) * 100 | round / 100)"
else empty end'

preflight() {
  local cmd
  [[ "$ISSUE" =~ ^[0-9]+$ ]] || die "issue must be a number, got '$ISSUE'. Usage: ./factory.sh <issue-number>"
  for cmd in claude gh jq git; do
    command -v "$cmd" >/dev/null || die "missing command: $cmd (run ./doctor.sh)"
  done
  load_conf
  [[ "$(git branch --show-current)" == "main" ]] || die "start from main: git checkout main"
  if [[ -n "$(git status --porcelain)" ]]; then
    die "working tree is not clean. Commit your changes first: git add gates prompts AGENTS.md && git commit -m \"my factory\"" \
      "$(git status --short)"
  fi
  local problem
  problem="$(check_gate_files)" || die "$problem"
  gh auth status >/dev/null 2>&1 || die "gh is not logged in: gh auth login, then ./doctor.sh"
  detect_upstream
  [[ "$(gh issue view "$ISSUE" --repo "$UPSTREAM" --json state -q .state 2>/dev/null)" == "OPEN" ]] \
    || die "issue #$ISSUE does not exist in $UPSTREAM or is not open"
  ISSUE_TITLE="$(gh issue view "$ISSUE" --repo "$UPSTREAM" --json title -q .title | tr '\n\r' '  ' | sed 's/ *$//')"
  bash -c "$TEST_CMD" >/dev/null 2>&1 || die "tests already fail on main ($TEST_CMD): fix them before running the factory"
  if [[ -n "$(git status --porcelain)" ]]; then  # else the agents get blamed for these files
    die "running the tests ($TEST_CMD) leaves files git does not ignore. Add them to .gitignore and commit:" \
      "$(git status --short)"
  fi
  BRANCH="factory/issue-${ISSUE}-$(date +%Y%m%d-%H%M%S)"
  if branch_taken "$BRANCH"; then  # two runs in the same second
    sleep 1
    BRANCH="factory/issue-${ISSUE}-$(date +%Y%m%d-%H%M%S)"
    ! branch_taken "$BRANCH" || die "branch $BRANCH already exists; wait a second and run again"
  fi
  FACTORY_BASE="$(git rev-parse HEAD)"
  RUN_TIER="$(compute_tier)"
  emit preflight ok=true title="$ISSUE_TITLE" branch="$BRANCH" upstream="$UPSTREAM"
}

prompt_file() {  # prompt_file <num> -> prompts/<num>-*.md
  local f
  for f in prompts/"$1"-*.md; do
    if [[ -f "$f" ]]; then
      echo "$f"
      return
    fi
  done
  die "missing prompt file prompts/$1-<name>.md"
}

render_prompt() {  # the prompt file with {{ISSUE}} and {{UPSTREAM}} filled in
  local text issue_tag="{{ISSUE}}" upstream_tag="{{UPSTREAM}}"
  text="$(cat "$1")"
  # Unquoted replacements: bash 3.2 would keep quotes literally; neither value can contain & or \.
  text="${text//"$issue_tag"/$ISSUE}"
  text="${text//"$upstream_tag"/$UPSTREAM}"
  printf '%s' "$text"
}

phase_name() {  # phase_name <file> <num>: the prompt's "# Heading", else the phase's default name
  local heading
  local -a defaults=(Plan Build Check Review)
  heading="$(head -n 1 "$1" | tr -d '\r' | sed -n 's/^#[[:space:]]*//p')"
  echo "${heading:-${defaults[$(($2 - 1))]}}"
}

timeout_cmd() {  # prints the timeout wrapper for this machine, if any
  if command -v gtimeout >/dev/null; then echo gtimeout; elif command -v timeout >/dev/null; then echo timeout; fi
}

add_totals() {  # add a phase's turns and cost from its result line; leaves that phase's own in PHASE_*
  local turns cost
  turns="$(jq -rs '[.[] | select(.type == "result")] | last | .num_turns // 0' "$1")"
  cost="$(jq -rs '[.[] | select(.type == "result")] | last | .total_cost_usd // 0' "$1")"
  TOTAL_TURNS=$((TOTAL_TURNS + turns))
  PHASE_TURNS="$turns" PHASE_COST="$cost"
  PHASE_SECONDS="$(jq -rs '[.[] | select(.type == "result")] | last | ((.duration_ms // 0) / 1000 | round)' "$1")"
  TOTAL_COST="$(jq -n --argjson a "$TOTAL_COST" --argjson b "$cost" '(($a + $b) * 10000 | round) / 10000')"
}

# run_phase <num> <contract file it must write>
run_phase() {
  local num="$1" out="$2" file name prompt rule wrapper log=".factory/logs/phase$1.jsonl"
  local -a allowed=() denied=()
  file="$(prompt_file "$num")"
  name="$(phase_name "$file" "$num")"
  prompt="$(render_prompt "$file") $SHELL_RULE"
  while IFS= read -r rule; do allowed+=("$rule"); done < <(allowed_tools "$num")
  while IFS= read -r rule; do denied+=("$rule"); done < <(denied_tools "$num")
  # --strict-mcp-config and --setting-sources project keep the participant's own connectors, plugins,
  # hooks, CLAUDE.md and .claude/settings.local.json out: only the repo's committed setup applies.
  local -a cmd=(claude -p --permission-mode acceptEdits --max-turns "$MAX_TURNS" --model "$MODEL"
    --strict-mcp-config --setting-sources project --output-format stream-json --verbose
    --disallowedTools "${denied[@]}" --allowedTools "${allowed[@]}" -- "$prompt")
  wrapper="$(timeout_cmd)"
  # --foreground keeps claude in our process group so Ctrl+C still stops it.
  if [[ -n "$wrapper" ]]; then cmd=("$wrapper" --foreground -k 10 "$PHASE_TIMEOUT" "${cmd[@]}"); fi

  CURRENT_PHASE="$num"
  emit phase_start phase="$num" name="$name" tools="$(IFS='|'; echo "${allowed[*]}")"
  printf '\n══ phase %s · %s ══\n' "$num" "$name"
  local status=0 subtype
  "${cmd[@]}" </dev/null | tee "$log" | jq -R -r --unbuffered --arg root "$ROOT/" "fromjson? | $FILTER" || status=$?
  subtype="$(jq -Rrs '[split("\n")[] | fromjson? | select(.type == "result")] | last | .subtype // ""' "$log")"
  if [[ -n "$subtype" && "$subtype" != "success" ]]; then
    die "phase $num did not finish cleanly ($subtype), e.g. hit the turn limit (raw log: $log)"
  fi
  [[ "$status" -eq 0 && -n "$subtype" ]] || die "phase $num crashed or timed out (raw log: $log)"
  [[ -s "$out" ]] || die "phase $num did not write $out, stopping before the next phase builds on nothing"
  add_totals "$log"
  emit phase_end phase="$num" turns="$PHASE_TURNS" cost_usd="$PHASE_COST" seconds="$PHASE_SECONDS"
  CURRENT_PHASE=""
}

# check_scope <label>: only SCOPE may change. A violation writes a rejecting review.md and returns 1.
check_scope() {
  local changed bad="" f
  git add -N .  # intent-to-add makes new files visible to git diff
  changed="$(git -c core.quotepath=off diff --no-renames --name-only "$FACTORY_BASE")"
  [[ -n "$changed" ]] || die "no changes under SCOPE ($SCOPE), nothing to ship"
  while IFS= read -r f; do
    in_scope "$f" || bad+="$f"$'\n'
  done <<<"$changed"
  bad="${bad%$'\n'}"
  if [[ -n "$bad" ]]; then
    emit scope after="$1" ok=false files="$bad"
    STOPPED_BY="scope"
    {
      printf '# Scope check stopped the run\n\nOnly these paths may change: %s\n\nOut of scope:\n\n' "$SCOPE"
      # shellcheck disable=SC2016  # literal backticks: Markdown code
      while IFS= read -r f; do printf -- '- `%s`\n' "$f"; done <<<"$bad"
      printf '\nVERDICT: REJECT\n'
    } >.factory/review.md
    printf '\n✗ scope check: only %s may change. Out of scope:\n%s\n' "$SCOPE" "$bad" >&2
    return 1
  fi
  emit scope after="$1" ok=true files="$changed"
}

code_fingerprint() {  # everything the PR would ship, new files included
  git add -N .
  git -c core.quotepath=off diff --no-renames --binary "$FACTORY_BASE" | git hash-object --stdin
}

# Last line that says something (not blank, not a --- rule or a code fence), normalised.
verdict_is_approve() {
  local last
  last="$(tr -d '\r' <.factory/review.md | grep -vE '^[[:space:]]*(-{3,}|`{3,}.*)?[[:space:]]*$' | tail -n 1 \
    | tr -d '*`_#> \t' | tr '[:lower:]' '[:upper:]' | sed 's/\.$//')"
  [[ "$last" == "VERDICT:APPROVE" ]]
}

commit_run() {
  git add -A
  git -c core.hooksPath=/dev/null commit -q --no-verify -m "feat: ${ISSUE_TITLE} (#${ISSUE})" \
    -m "Built by factory.sh from issue #${ISSUE}."
}

# end_run <APPROVE|REJECT>: record the verdict, then commit (rehearsal) or open a PR.
end_run() {
  local verdict="$1" result
  if [[ "$verdict" == "REJECT" && -z "$STOPPED_BY" ]]; then STOPPED_BY="review"; fi
  emit verdict value="$verdict"
  if [[ -n "${FACTORY_NO_PUSH:-}" ]]; then
    commit_run
    result="committed"
    [[ "$verdict" == "APPROVE" ]] || result="rejected"
    printf '\nFACTORY_NO_PUSH set: %s run committed on %s, not pushed.\n' "$verdict" "$BRANCH"
    finish_run result="$result" verdict="$verdict" stopped_by="$STOPPED_BY" turns="$TOTAL_TURNS" cost="$TOTAL_COST"
  else
    printf '\n══ opening the PR on %s (a human decides; nothing is merged) ══\n' "$UPSTREAM"
    open_pr "$verdict"
  fi
  back_to_main
  [[ "$verdict" == "APPROVE" ]] || exit 1
}

back_to_main() {  # the next change belongs on main, where the next run starts
  git checkout -q main
  printf 'Now back on main: commit your next change here, then ./factory.sh <issue> again.\n'
}

# park_run: when a run stops early, keep its files on the run branch and leave main clean.
park_run() {
  [[ -n "$BRANCH" && "$(git branch --show-current 2>/dev/null)" == "$BRANCH" ]] || return 0
  git add -A >/dev/null 2>&1 || return 0
  if ! git diff --cached --quiet; then
    git -c core.hooksPath=/dev/null commit -q --no-verify -m "stopped run for #${ISSUE}" >/dev/null 2>&1 || return 0
  fi
  git checkout -q main 2>/dev/null || return 0
  printf 'Back on main, clean. What this run did so far is kept on branch %s.\n' "$BRANCH" >&2
}

rm -rf .factory/logs .factory/*.md .factory/pr-body.md
mkdir -p .factory/logs
# Run files never dirty the repo, whatever its .gitignore says (a "*" file ignores itself too).
[[ -e .factory/.gitignore ]] || printf '*\n' >.factory/.gitignore
install_traps
telemetry_init .factory/logs
emit run_start issue="$ISSUE"
preflight
git checkout -q -b "$BRANCH"
ON_STOP=park_run
printf 'On branch %s · upstream %s · live agent output below · raw logs in .factory/logs/\n' "$BRANCH" "$UPSTREAM"

run_phase 1 .factory/plan.md
[[ -z "$(git status --porcelain)" ]] || die "phase 1 changed files; the plan phase may only write .factory/plan.md"
run_phase 2 .factory/build.md
if check_scope 2; then
  run_phase 3 .factory/report.md
  if check_scope 3 && run_gates; then
    REVIEWED="$(code_fingerprint)"
    run_phase 4 .factory/review.md
    if [[ "$(code_fingerprint)" != "$REVIEWED" ]]; then
      CURRENT_PHASE=4
      die "phase 4 changed the code it was reviewing; a reviewer may only write .factory/review.md"
    fi
  fi
fi

if [[ -z "$STOPPED_BY" ]] && verdict_is_approve && check_scope final; then
  printf '\n══ verdict APPROVE ══\n'
  end_run APPROVE
else
  printf '\n══ verdict REJECT · see .factory/review.md ══\n'
  end_run REJECT
fi
