"""factory.sh core: phases from prompt files, contract files, scope, review fingerprint."""

from __future__ import annotations

import re
from pathlib import Path

from tests.conftest import run_factory
from tests.engine_helpers import (
    argv,
    claude_calls,
    commit_file,
    events,
    flag_values,
    git_out,
    last,
    prompt_of,
    script_phases,
)


def rehearse(env: dict[str, str]) -> dict[str, str]:
    return {**env, "FACTORY_NO_PUSH": "1"}


def test_happy_path_commits_on_a_run_branch(kit_repo: Path, stub_env: dict[str, str]) -> None:
    script_phases(stub_env)
    out = run_factory(kit_repo, rehearse(stub_env), "1")
    assert out.returncode == 0, out.stderr
    [run] = git_out(kit_repo, stub_env, "branch", "--list", "factory/*", "--format=%(refname:short)").split()
    assert re.match(r"^factory/issue-1-\d{8}-\d{6}$", run)
    assert git_out(kit_repo, stub_env, "log", "-1", "--format=%s", run) == "feat: Add stats (#1)"
    assert git_out(kit_repo, stub_env, "branch", "--show-current") == "main"  # the run ends on main
    assert events(kit_repo)[-1]["event"] == "finish"
    assert last(kit_repo, "finish")["result"] == "committed"


def test_prompts_come_from_files_with_placeholders(
    kit_repo: Path, stub_env: dict[str, str]
) -> None:
    commit_file(
        kit_repo, stub_env, "prompts/1-plan.md", "# Plan\nissue {{ISSUE}} in {{UPSTREAM}}\n"
    )
    script_phases(stub_env)
    out = run_factory(kit_repo, rehearse(stub_env), "1")
    assert out.returncode == 0, out.stderr
    assert "issue 1 in workshop/leaderboard-api" in prompt_of(argv(stub_env, 1))


def test_each_phase_gets_its_allow_and_deny_lists(kit_repo: Path, stub_env: dict[str, str]) -> None:
    script_phases(stub_env)
    assert run_factory(kit_repo, rehearse(stub_env), "1").returncode == 0
    build = argv(stub_env, 2)
    assert {"Bash(./check.sh:*)", "Bash(./lint.sh)"} <= set(flag_values(build, "--allowedTools"))
    assert "Edit(app/**)" not in flag_values(build, "--disallowedTools")
    assert "Edit(app/**)" in flag_values(argv(stub_env, 4), "--disallowedTools")
    assert flag_values(argv(stub_env, 1), "--allowedTools") == ["Bash(gh issue view:*)"]


def test_scope_violation_rejects_instead_of_dying(kit_repo: Path, stub_env: dict[str, str]) -> None:
    script_phases(stub_env, phase2_extra="echo oops > README.md\n")
    out = run_factory(kit_repo, rehearse(stub_env), "1")
    assert out.returncode == 1
    review = (kit_repo / ".factory" / "review.md").read_text()
    assert "README.md" in review
    assert review.rstrip().splitlines()[-1] == "VERDICT: REJECT"
    assert last(kit_repo, "scope")["ok"] == "false"
    assert last(kit_repo, "finish")["result"] == "rejected"
    assert claude_calls(stub_env) == 2


def test_reviewer_edit_stops_the_run(kit_repo: Path, stub_env: dict[str, str]) -> None:
    script_phases(stub_env, phase4_extra="echo sneaky >> app/x.txt\n")
    out = run_factory(kit_repo, rehearse(stub_env), "1")
    assert out.returncode == 1
    assert "phase 4 changed the code it was reviewing" in out.stderr


def test_missing_contract_file_stops(kit_repo: Path, stub_env: dict[str, str]) -> None:
    script_phases(stub_env, phase1="true\n")
    out = run_factory(kit_repo, rehearse(stub_env), "1")
    assert out.returncode == 1
    assert "phase 1 did not write .factory/plan.md" in out.stderr


def test_turn_limit_stops(kit_repo: Path, stub_env: dict[str, str]) -> None:
    script_phases(stub_env)
    out = run_factory(kit_repo, {**rehearse(stub_env), "STUB_RESULT_2": "error_max_turns"}, "1")
    assert out.returncode == 1
    assert "phase 2 did not finish cleanly" in out.stderr


def test_dirty_tree_message_says_commit(kit_repo: Path, stub_env: dict[str, str]) -> None:
    (kit_repo / "gates").mkdir()
    (kit_repo / "gates" / "g.sh").write_text("exit 0\n")
    out = run_factory(kit_repo, rehearse(stub_env), "1")
    assert out.returncode == 1
    assert "Commit your changes first" in out.stderr
    assert "gates/" in out.stderr


def test_not_on_main_stops(kit_repo: Path, stub_env: dict[str, str]) -> None:
    git_out(kit_repo, stub_env, "checkout", "-q", "-b", "x")
    out = run_factory(kit_repo, rehearse(stub_env), "1")
    assert out.returncode == 1
    assert "start from main" in out.stderr


def test_issue_must_be_a_number(kit_repo: Path, stub_env: dict[str, str]) -> None:
    out = run_factory(kit_repo, rehearse(stub_env), "one")
    assert out.returncode == 1
    assert "issue must be a number" in out.stderr


def test_totals_sum_phase_results(kit_repo: Path, stub_env: dict[str, str]) -> None:
    script_phases(stub_env)
    assert run_factory(kit_repo, rehearse(stub_env), "1").returncode == 0
    finish = last(kit_repo, "finish")
    assert (finish["turns"], finish["cost"]) == ("12", "0.4")


def test_events_carry_upstream_verdict_and_stop_reason(kit_repo: Path, stub_env: dict[str, str]) -> None:
    script_phases(stub_env, phase2_extra="echo oops > README.md\n")
    run_factory(kit_repo, rehearse(stub_env), "1")
    assert last(kit_repo, "preflight")["upstream"] == "workshop/leaderboard-api"
    finish = last(kit_repo, "finish")
    assert (finish["verdict"], finish["stopped_by"]) == ("REJECT", "scope")


def test_run_works_without_the_telemetry_client(kit_repo: Path, stub_env: dict[str, str]) -> None:
    # an older checkout, or a repo synced before the client existed
    (kit_repo / "lib" / "telemetry.sh").unlink()
    git_out(kit_repo, stub_env, "commit", "-qam", "no telemetry client")
    script_phases(stub_env)
    out = run_factory(kit_repo, rehearse(stub_env), "1")
    assert out.returncode == 0, out.stderr
