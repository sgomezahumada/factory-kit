"""Dashboard telemetry: off unless FACTORY_TELEMETRY_URL is set, fail-open, and carries the run's facts."""

from __future__ import annotations

import time
from pathlib import Path

from tests.conftest import TelemetryServer, git, run_factory, telemetry_env
from tests.engine_helpers import REJECT, commit_file, events, script_phases

CLOSED_PORT = "http://127.0.0.1:9"  # nothing listens on the discard port
NOISE = {"ts", "branch"}  # differ between any two runs


def rehearse(env: dict[str, str]) -> dict[str, str]:
    return {**env, "FACTORY_NO_PUSH": "1"}


def stable(repo: Path) -> list[dict[str, object]]:
    return [{k: v for k, v in row.items() if k not in NOISE} for row in events(repo)]


def rerun(repo: Path, env: dict[str, str], **phases: str) -> None:
    git(repo, "checkout", "-q", "main", env=env)
    (Path(env["STUB_DIR"]) / "count").unlink(missing_ok=True)
    script_phases(env, **phases)


def test_events_carry_phase_stats_tier_and_model(kit_repo: Path, stub_env: dict[str, str]) -> None:
    script_phases(stub_env)
    assert run_factory(kit_repo, rehearse(stub_env), "1").returncode == 0
    rows = events(kit_repo)
    ends = [r for r in rows if r["event"] == "phase_end"]
    assert len(ends) == 4
    # the stub's result line: 3 turns, 1000 ms, $0.1 per phase (not the run so far)
    assert all((r["turns"], r["cost_usd"], r["seconds"]) == ("3", "0.1", "1") for r in ends)
    finish = rows[-1]
    assert (finish["event"], finish["tier"], finish["model"]) == ("finish", "1", "claude-sonnet-5-5")
    assert (finish["turns"], finish["cost"]) == ("12", "0.4")


def test_fail_carries_what_is_known(kit_repo: Path, stub_env: dict[str, str]) -> None:
    script_phases(stub_env)
    out = run_factory(kit_repo, {**stub_env, "STUB_RESULT_2": "error_max_turns"}, "1")
    assert out.returncode == 1
    fail = events(kit_repo)[-1]
    assert (fail["event"], fail["phase"], fail["tier"], fail["model"]) == (
        "fail",
        "2",
        "1",
        "claude-sonnet-5-5",
    )
    # before preflight there is no tier yet, only the model
    out = run_factory(kit_repo, stub_env, "not-a-number")
    assert out.returncode == 1
    fail = events(kit_repo)[-1]
    assert fail["event"] == "fail" and "tier" not in fail and "model" not in fail


def test_without_a_url_nothing_is_sent_and_no_files_appear(
    kit_repo: Path, stub_env: dict[str, str], curl_calls: Path
) -> None:
    script_phases(stub_env)
    assert run_factory(kit_repo, stub_env, "1").returncode == 0
    assert not curl_calls.exists(), "curl was called with telemetry off"
    assert sorted(p.name for p in (kit_repo / ".factory" / "logs").iterdir()) == [
        "events.jsonl",
        "phase1.jsonl",
        "phase2.jsonl",
        "phase3.jsonl",
        "phase4.jsonl",
    ]


def test_an_unreachable_endpoint_changes_nothing(
    kit_repo: Path, stub_env: dict[str, str], tmp_path: Path
) -> None:
    down = telemetry_env(rehearse(stub_env), tmp_path, CLOSED_PORT)
    for phase4, code in (("", 0), (REJECT, 1)):
        extra = {"phase4": phase4} if phase4 else {}
        rerun(kit_repo, stub_env, **extra)
        plain = run_factory(kit_repo, rehearse(stub_env), "1")
        baseline = stable(kit_repo)
        rerun(kit_repo, stub_env, **extra)
        started = time.monotonic()
        with_url = run_factory(kit_repo, down, "1")
        assert time.monotonic() - started < 30
        assert (plain.returncode, with_url.returncode) == (code, code)
        assert stable(kit_repo) == baseline
        assert (kit_repo / ".factory" / "logs" / "telemetry.jsonl").is_file()  # it did try


def test_a_full_run_reaches_the_server(
    kit_repo: Path, stub_env: dict[str, str], tmp_path: Path, telemetry_server: TelemetryServer
) -> None:
    commit_file(kit_repo, stub_env, "gates/ok.sh", "#!/usr/bin/env bash\nexit 0\n", 0o755)
    script_phases(stub_env, phase4=REJECT)
    env = telemetry_env(stub_env, tmp_path, telemetry_server.url)
    assert run_factory(kit_repo, env, "1").returncode == 1
    telemetry_server.wait_for("finish")
    # Live events plus the end-of-run resend (a multi-line batch); the dashboard keeps one row per seq.
    deadline = time.monotonic() + 15
    while not any(str(r["body"]).count("\n") > 1 for r in telemetry_server.requests) and time.monotonic() < deadline:
        time.sleep(0.05)
    assert any(str(r["body"]).count("\n") > 1 for r in telemetry_server.requests), "run was not resent at the end"
    rows = list({(r["run_id"], r["seq"]): r for r in telemetry_server.events()}.values())

    req = telemetry_server.requests[0]
    assert req["path"] == "/v1/events"
    headers = {str(k).lower(): v for k, v in dict(req["headers"]).items()}  # type: ignore[call-overload]
    assert headers["authorization"] == "Bearer s3cret-token"
    assert headers["content-type"] == "application/x-ndjson"

    assert {r["workshop"] for r in rows} == {"nov-10"}
    assert {r["participant"] for r in rows} == {"ana"}
    assert len({r["run_id"] for r in rows}) == 1
    by_event = {str(r["event"]): r["attrs"] for r in rows}
    assert by_event["preflight"]["upstream"] == "workshop/leaderboard-api"  # type: ignore[index]
    ends = [r["attrs"] for r in rows if r["event"] == "phase_end"]
    assert len(ends) == 4
    assert all(a["cost_usd"] == "0.1" and a["turns"] == "3" and a["seconds"] == "1" for a in ends)  # type: ignore[index]
    finish = by_event["finish"]
    assert {k: finish[k] for k in ("stopped_by", "tier", "model", "verdict", "result")} == {  # type: ignore[index]
        "stopped_by": "review",
        "tier": "2",  # the participant added a gate
        "model": "claude-sonnet-5-5",
        "verdict": "REJECT",
        "result": "rejected",
    }
    assert "tools" not in by_event["phase_start"]  # off the allowlist: never sent
    assert not any("Looks fine" in str(r) or "Tests are missing" in str(r) for r in rows)  # no agent text
