"""sync.sh: install or update the kit in a problem repo without touching what the repo owns."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

from tests.conftest import ROOT
from tests.engine_helpers import commit_file, git_out


@pytest.fixture
def target(tmp_path: Path, stub_env: dict[str, str]) -> Path:
    repo = tmp_path / "problem"
    repo.mkdir()
    git_out(repo, stub_env, "init", "-q", "-b", "main")
    commit_file(repo, stub_env, "README.md", "# A problem repo\n")
    return repo


def sync(repo: Path, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(ROOT / "sync.sh"), str(repo)], env=env, capture_output=True, text=True
    )


def test_sync_installs_engine_and_default_prompts(target: Path, stub_env: dict[str, str]) -> None:
    out = sync(target, stub_env)
    assert out.returncode == 0, out.stderr
    for rel in (
        "factory.sh",
        "doctor.sh",
        "lib/conf.sh",
        "lib/gates.sh",
        "lib/telemetry.sh",
        "prompts/4-review.md",
        "dashboard/server.py",
    ):
        assert (target / rel).is_file(), rel
    assert os.access(target / "factory.sh", os.X_OK) and os.access(target / "doctor.sh", os.X_OK)
    assert not (target / "dashboard" / "__pycache__").exists()
    assert "factory.sh" in out.stdout


def test_sync_keeps_repo_owned_files(target: Path, stub_env: dict[str, str]) -> None:
    owned = {
        "gates/no-deps.sh": "#!/usr/bin/env bash\nexit 0\n",
        "AGENTS.md": "# This repo's context\n",
        "factory.conf": 'TEST_CMD="npm test"\nSCOPE="src/"\n',
        "prompts/4-review.md": "# Strict review\nBe strict.\n",
        "factory.sh": "#!/usr/bin/env bash\necho old engine\n",
    }
    for rel, text in owned.items():
        commit_file(target, stub_env, rel, text)
    assert sync(target, stub_env).returncode == 0
    for rel in ("gates/no-deps.sh", "AGENTS.md", "factory.conf", "prompts/4-review.md"):
        assert (target / rel).read_text() == owned[rel], rel
    assert (target / "factory.sh").read_text() == (ROOT / "kit" / "factory.sh").read_text()
    assert (target / "prompts" / "1-plan.md").is_file()  # missing prompts are added


def test_sync_refuses_dirty_target(target: Path, stub_env: dict[str, str]) -> None:
    (target / "wip.txt").write_text("uncommitted\n")
    out = sync(target, stub_env)
    assert out.returncode == 1
    assert "commit or stash" in out.stderr
    assert not (target / "factory.sh").exists()


def test_sync_refuses_a_non_repo(tmp_path: Path, stub_env: dict[str, str]) -> None:
    plain = tmp_path / "plain"
    plain.mkdir()
    out = sync(plain, stub_env)
    assert out.returncode == 1
    assert "not a git repo" in out.stderr


def test_synced_repo_runs_the_factory(target: Path, stub_env: dict[str, str]) -> None:
    """The point of sync: a problem repo with only its own files plus the kit can run."""
    from tests.conftest import run_factory
    from tests.engine_helpers import script_phases

    commit_file(target, stub_env, "factory.conf", 'TEST_CMD="true"\nSCOPE="app/"\n')
    commit_file(target, stub_env, "app/x.txt", "app\n")
    commit_file(target, stub_env, ".gitignore", ".factory/*\n")
    assert sync(target, stub_env).returncode == 0
    git_out(target, stub_env, "add", "-A")
    git_out(target, stub_env, "commit", "-q", "-m", "kit")
    script_phases(stub_env)
    out = run_factory(target, {**stub_env, "FACTORY_NO_PUSH": "1"}, "1")
    assert out.returncode == 0, out.stderr
