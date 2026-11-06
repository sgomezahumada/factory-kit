"""doctor.sh: every check prints ok or the exact fix; the run never stops at the first failure."""

from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path

import pytest

from tests.conftest import TelemetryServer, telemetry_env
from tests.engine_helpers import commit_file, git_out

FORK_URL = "https://github.com/ana/x.git"


@pytest.fixture
def doctor_repo(kit_repo: Path, stub_env: dict[str, str], tmp_path: Path) -> Path:
    fork = str(tmp_path / "fork.git")
    git_out(kit_repo, stub_env, "config", f"url.{fork}.insteadOf", FORK_URL)
    git_out(
        kit_repo, stub_env, "config", "--add", f"url.{fork}.insteadOf", "git@github.com:ana/x.git"
    )
    git_out(kit_repo, stub_env, "remote", "set-url", "origin", FORK_URL)
    git_out(kit_repo, stub_env, "config", "credential.helper", "store")
    return kit_repo


def doctor(repo: Path, env: dict[str, str], **extra: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "doctor.sh"],
        cwd=repo,
        env={**env, **extra},
        capture_output=True,
        text=True,
        timeout=60,
    )


def line(out: subprocess.CompletedProcess[str], check: str) -> str:
    matches = [l for l in out.stdout.splitlines() if l[5:].startswith(check)]
    assert matches, f"no line for {check!r} in:\n{out.stdout}"
    return matches[0]


def test_all_green(doctor_repo: Path, stub_env: dict[str, str]) -> None:
    out = doctor(doctor_repo, stub_env)
    assert out.returncode == 0, out.stdout + out.stderr
    assert out.stdout.rstrip().splitlines()[-1] == "doctor: all green"
    assert "FIX" not in out.stdout


def test_claude_not_logged_in(doctor_repo: Path, stub_env: dict[str, str]) -> None:
    out = doctor(doctor_repo, stub_env, STUB_CLAUDE_LOGGED_OUT="1")
    assert out.returncode == 1
    assert line(out, "Claude login").startswith("FIX  Claude login")


def test_gh_not_logged_in(doctor_repo: Path, stub_env: dict[str, str]) -> None:
    out = doctor(doctor_repo, stub_env, STUB_GH_AUTH="1")
    assert out.returncode == 1
    assert line(out, "GitHub login").startswith("FIX  GitHub login: gh auth login")


def test_missing_git_credentials(doctor_repo: Path, stub_env: dict[str, str]) -> None:
    git_out(doctor_repo, stub_env, "config", "--unset", "credential.helper")
    out = doctor(doctor_repo, stub_env)
    assert line(out, "git credentials") == "FIX  git credentials: gh auth setup-git"


def test_ssh_origin_is_flagged(doctor_repo: Path, stub_env: dict[str, str]) -> None:
    git_out(doctor_repo, stub_env, "remote", "set-url", "origin", "git@github.com:ana/x.git")
    out = doctor(doctor_repo, stub_env)
    assert out.returncode == 1
    assert (
        line(out, "origin is HTTPS")
        == f"FIX  origin is HTTPS: git remote set-url origin {FORK_URL}"
    )


def test_not_a_fork(doctor_repo: Path, stub_env: dict[str, str]) -> None:
    out = doctor(doctor_repo, stub_env, STUB_GH_NOT_FORK="1")
    assert line(out, "fork").startswith("FIX  fork")


def test_push_failure_is_flagged(
    doctor_repo: Path, stub_env: dict[str, str], tmp_path: Path
) -> None:
    git_out(
        doctor_repo, stub_env, "config", "--unset-all", f"url.{tmp_path / 'fork.git'}.insteadOf"
    )
    git_out(doctor_repo, stub_env, "remote", "set-url", "origin", str(tmp_path / "missing.git"))
    out = doctor(doctor_repo, stub_env)
    assert line(out, "push").startswith("FIX  push")


def test_missing_runtime_is_flagged(doctor_repo: Path, stub_env: dict[str, str]) -> None:
    conf = (doctor_repo / "factory.conf").read_text() + 'RUNTIME="no-such-runtime-xyz"\n'
    commit_file(doctor_repo, stub_env, "factory.conf", conf)
    out = doctor(doctor_repo, stub_env)
    assert line(out, "runtime").startswith("FIX  runtime: no-such-runtime-xyz")


def test_failing_tests_are_flagged(doctor_repo: Path, stub_env: dict[str, str]) -> None:
    commit_file(doctor_repo, stub_env, "check.sh", "#!/usr/bin/env bash\nexit 1\n", 0o755)
    out = doctor(doctor_repo, stub_env)
    assert out.returncode == 1
    assert line(out, "tests").startswith("FIX  tests")


def test_doctor_warns_when_fork_is_behind(
    doctor_repo: Path, stub_env: dict[str, str], tmp_path: Path
) -> None:
    other = tmp_path / "other"
    subprocess.run(
        ["git", "clone", "-q", str(tmp_path / "upstream.git"), str(other)], env=stub_env, check=True
    )
    commit_file(other, stub_env, "app/new.txt", "upstream moved on\n")
    git_out(other, stub_env, "push", "-q", "origin", "main")
    out = doctor(doctor_repo, stub_env)
    assert out.returncode == 0, out.stdout
    warns = [l for l in out.stdout.splitlines() if l.startswith("WARN")]
    assert any("git pull upstream main" in w for w in warns), warns


def test_runs_every_check_even_after_a_failure(doctor_repo: Path, stub_env: dict[str, str]) -> None:
    out = doctor(doctor_repo, stub_env, STUB_GH_AUTH="1")
    assert line(out, "tests").startswith("ok")


def test_missing_conf_is_a_fix_not_a_crash(doctor_repo: Path, stub_env: dict[str, str]) -> None:
    (doctor_repo / "factory.conf").unlink()
    out = doctor(doctor_repo, stub_env)
    assert out.returncode == 1
    assert line(out, "factory.conf").startswith("FIX  factory.conf")


def test_all_green_sends_hello_only_when_telemetry_is_on(
    doctor_repo: Path,
    stub_env: dict[str, str],
    tmp_path: Path,
    telemetry_server: TelemetryServer,
    curl_calls: Path,
) -> None:
    quiet = doctor(doctor_repo, stub_env)
    assert quiet.returncode == 0
    assert not curl_calls.exists()

    # a real curl for the server test
    stub_env["PATH"] = stub_env["PATH"].split(os.pathsep, 1)[1]
    env = telemetry_env(stub_env, tmp_path, telemetry_server.url)
    out = doctor(doctor_repo, env)
    assert out.returncode == 0 and out.stdout == quiet.stdout and out.stderr == quiet.stderr
    [hello] = [r for r in telemetry_server.wait_for("hello") if r["event"] == "hello"]
    assert hello["participant"] == "ana" and hello["workshop"] == "nov-10"
    headers = {str(k).lower(): v for k, v in dict(telemetry_server.requests[0]["headers"]).items()}  # type: ignore[call-overload]
    assert headers["authorization"] == "Bearer s3cret-token"


def test_doctor_with_fixes_sends_no_hello(
    doctor_repo: Path, stub_env: dict[str, str], tmp_path: Path, telemetry_server: TelemetryServer
) -> None:
    env = telemetry_env(stub_env, tmp_path, telemetry_server.url)
    out = doctor(doctor_repo, {**env, "STUB_GH_AUTH": "1"})
    assert out.returncode == 1
    time.sleep(1)
    assert telemetry_server.requests == []


def test_doctor_ignores_an_unreachable_endpoint(
    doctor_repo: Path, stub_env: dict[str, str], tmp_path: Path
) -> None:
    quiet = doctor(doctor_repo, stub_env)
    out = doctor(doctor_repo, telemetry_env(stub_env, tmp_path, "http://127.0.0.1:9"))
    assert (out.returncode, out.stdout, out.stderr) == (0, quiet.stdout, quiet.stderr)
