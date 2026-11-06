# Run contract

What the factory promises to everything that watches it. The **room board** reads only the pull
requests on GitHub (sections 1 and 2). The **local panel** and anyone debugging read the files in
`.factory/` (section 3). `tests/test_contract.py` checks the engine against this page, so if a
test fails after a change, either the change or this page is wrong.

**Compatibility:** marker keys, PR conventions and event fields are only ever added to. Nothing is
renamed or removed without bumping the marker's `v` and telling the room board's owner first.

## 1. Pull requests

Every run that reaches a verdict opens exactly one PR. Runs that crash, time out or fail preflight
open nothing (the participant sees why in their terminal).

| | Approved run | Rejected run |
|---|---|---|
| Repo | the workshop problem repo (the fork's parent) | same |
| Base branch | `main` | `main` |
| Head | `<fork owner>:<branch>` | same |
| Title | `<ticket title>` | `[REJECTED] <ticket title>` |
| Draft | no | yes |
| Body line 2 | `Closes #<n>` | `Rejected run for #<n> (not closing it).` |
| Author | the participant (their `gh` login) | same |

`<branch>` is unique per run:

```head-regex
^factory/issue-(\d+)-(\d{8})-(\d{6})$
```

(ticket number, then the run's local date `YYYYmmdd` and time `HHMMSS`). After body line 2 come
`## Review` (the reviewer's or the stopping gate's text), `## Test and security report` when phase 3
ran, and the plan inside `<details>`. All agent text has `@mentions` defused and the body is cut
at 60,000 bytes.

## 2. The run marker

The first line of every factory PR body. A PR without a valid marker was not opened by the factory
(show it as "manual").

```marker-regex
^<!-- factory-run (\{.*\}) -->$
```

| Key | Type | Meaning |
|---|---|---|
| `v` | int | marker version, `1` |
| `ticket` | int | the issue number in the workshop repo |
| `verdict` | `"APPROVE"` \| `"REJECT"` | the run's outcome |
| `stopped_by` | `null` \| `"review"` \| `"scope"` \| `"gate:<file>"` | what rejected it; `null` when approved |
| `turns` | int | agent turns over all phases that ran |
| `cost` | number | USD over all phases that ran, as reported by Claude Code |
| `model` | string | the model every phase used |
| `tier` | `1` \| `2` \| `3` | 3 if the participant changed `prompts/`, else 2 if they changed `gates/`, else 1 |

Approved:

<!-- factory-run {"v":1,"ticket":1,"verdict":"APPROVE","stopped_by":null,"turns":31,"cost":0.42,"model":"claude-sonnet-5-5","tier":1} -->

Rejected by a participant's gate (phase 4 never ran):

<!-- factory-run {"v":1,"ticket":3,"verdict":"REJECT","stopped_by":"gate:no-deps.sh","turns":22,"cost":0.29,"model":"claude-sonnet-5-5","tier":2} -->

## 3. Local run files (`.factory/`)

| File | Appears | Contents |
|---|---|---|
| `plan.md` | end of phase 1 | the plan |
| `build.md` | end of phase 2 | what was built, red and green test runs |
| `report.md` | end of phase 3 | test and lint output, security findings |
| `review.md` | end of phase 4, or when scope or a gate stops the run | reasons; last line `VERDICT: APPROVE` or `VERDICT: REJECT` |
| `pr-body.md` | when a PR is opened | the PR body as sent |
| `logs/phaseN.jsonl` | while phase N runs | Claude Code `stream-json`, unmodified |
| `logs/gate-<file>.log` | when that gate runs | the gate's output |
| `logs/events.jsonl` | throughout | the events below, one JSON object per line |

Every event has `ts` (int, epoch seconds) and `event`. All other values are strings.

### `run_start`

```jsonl
{"ts":1793992300,"event":"run_start","issue":"1"}
```

### `preflight`

Preflight passed. `upstream` is the workshop repo.

```jsonl
{"ts":1793992302,"event":"preflight","ok":"true","title":"Add stats","branch":"factory/issue-1-20261106-141200","upstream":"workshop/leaderboard-api"}
```

### `phase_start`

`name` is the `# Heading` of the phase's prompt file; `tools` the allowed shell commands, `|`-separated.

```jsonl
{"ts":1793992302,"event":"phase_start","phase":"2","name":"Build","tools":"Bash(pytest -q:*)|Bash(ruff check .)"}
```

### `phase_end`

`turns`, `cost_usd` (USD, as reported by Claude Code) and `seconds` (rounded from the result's
`duration_ms`) are for that phase alone, not the run so far.

```jsonl
{"ts":1793992330,"event":"phase_end","phase":"2","turns":"14","cost_usd":"0.1832","seconds":"28"}
```

### `scope`

After phase 2 (`after` = `2`), phase 3 (`3`) and before an approval (`final`). `files` is newline-separated.

```jsonl
{"ts":1793992330,"event":"scope","after":"2","ok":"true","files":"app/main.py\ntests/test_main.py"}
```

### `gate`

One per participant gate that ran (in name order, stopping at the first failure).

```jsonl
{"ts":1793992360,"event":"gate","name":"no-deps.sh","ok":"false"}
```

### `verdict`

```jsonl
{"ts":1793992361,"event":"verdict","value":"REJECT"}
```

### `finish`

`result` is `pr` (approved and pushed), `rejected` (a draft PR when pushed; local only in a rehearsal)
or `committed` (approved in a rehearsal, `FACTORY_NO_PUSH=1`). `url` only when a PR was opened.
`tier` and `model` are the same values as in the run marker.

```jsonl
{"ts":1793992362,"event":"finish","result":"rejected","url":"https://github.com/workshop/leaderboard-api/pull/7","verdict":"REJECT","stopped_by":"gate:no-deps.sh","turns":"22","cost":"0.29","model":"claude-sonnet-5-5","tier":"2"}
```

### `fail`

The run stopped without a verdict (crash, timeout, turn limit, missing contract file, preflight).
`phase` is empty before phase 1. `model` and `tier` are there when the run already knew them: `model`
once `factory.conf` is read, `tier` once preflight passed. A `fail` earlier than that omits them.

```jsonl
{"ts":1793992340,"event":"fail","phase":"2","reason":"phase 2 did not finish cleanly, e.g. hit the turn limit (raw log: .factory/logs/phase2.jsonl)","model":"claude-sonnet-5-5","tier":"1"}
```

## 4. Telemetry (optional)

The factory can also send its events to the workshop dashboard. It is off unless
`FACTORY_TELEMETRY_URL` is set; with it unset nothing happens (no files, no network).

| Variable | Meaning |
|---|---|
| `FACTORY_TELEMETRY_URL` | base URL of the dashboard API; unset = telemetry off |
| `FACTORY_TELEMETRY_TOKEN` | ingest bearer token, sent as `Authorization: Bearer …` |
| `FACTORY_WORKSHOP` | workshop id (default `default`) |

`lib/telemetry.sh` is a copy of `client/telemetry.sh` from Emer-42/demo-factory-dashboard; its README
lists the rest of its variables. Every event in section 3 is sent with a random run id, a sequence
number, the participant's GitHub login (or `anon-xxxxxx`) and the OS. Each event is also appended to
`.factory/logs/telemetry.jsonl`.

- **Sent:** the event name and the fields of section 3 on an allowlist: issue number, ticket title,
  branch, upstream, phase number and name, changed file paths, gate name and result, verdict,
  `stopped_by`, tier, model, turns, cost, seconds, PR URL and the failure reason.
- **Not sent:** prompts, code or diffs, transcripts, agent output, review text, tool lists,
  environment variables. Anything off the allowlist is dropped before it is written or sent.
- **Fail-open:** delivery is a detached background `curl` with short timeouts and errors ignored.
  An unset, unreachable or rejecting endpoint never fails a run, changes its exit code or its
  `events.jsonl`, or makes it wait.

`./doctor.sh` sends one `hello` when it ends all green (same rules: silent, background, only with the URL set).
To check the connection by hand: `bash lib/telemetry.sh hello`.
