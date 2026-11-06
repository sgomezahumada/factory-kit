"""lib/conf.sh: factory.conf loading and the permission lists each phase gets."""

from __future__ import annotations

import subprocess
from pathlib import Path

from tests.conftest import KIT

CONF_LIB = KIT / "lib" / "conf.sh"
STUB_DIE = 'die() { printf "%s\\n" "$*" >&2; exit 1; }; '


def sh(
    cwd: Path, script: str, env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-c", f"set -euo pipefail; {STUB_DIE}source '{CONF_LIB}'; {script}"],
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
    )


def lines(cwd: Path, script: str, env: dict[str, str] | None = None) -> list[str]:
    out = sh(cwd, script, env)
    assert out.returncode == 0, out.stderr
    return out.stdout.splitlines()


def conf(tmp_path: Path, text: str) -> Path:
    (tmp_path / "factory.conf").write_text(text)
    return tmp_path


def test_allowlist_phase2_uses_exact_commands(tmp_path: Path) -> None:
    repo = conf(tmp_path, 'TEST_CMD="npm test"\nLINT_CMD="npx eslint ."\nSCOPE="src/"\n')
    assert lines(repo, "load_conf; allowed_tools 2") == ["Bash(npm test:*)", "Bash(npx eslint .)"]


def test_allowlist_without_lint(tmp_path: Path) -> None:
    repo = conf(tmp_path, 'TEST_CMD="npm test"\nSCOPE="src/"\n')
    assert lines(repo, "load_conf; allowed_tools 2") == ["Bash(npm test:*)"]


def test_plan_and_review_phases_get_their_extra_commands(tmp_path: Path) -> None:
    repo = conf(tmp_path, 'TEST_CMD="npm test"\nSCOPE="src/"\n')
    assert lines(repo, "load_conf; allowed_tools 1") == ["Bash(gh issue view:*)"]
    review = lines(repo, "load_conf; FACTORY_BASE_REF=main; allowed_tools 4")
    assert review == [
        "Bash(npm test:*)",
        "Bash(git diff main)",
        "Bash(git diff --stat main)",
        "Bash(git diff --name-only main)",
    ]


def test_review_phase_denies_scope_edits(tmp_path: Path) -> None:
    repo = conf(tmp_path, 'TEST_CMD="t"\nSCOPE="app/ tests/"\n')
    review = lines(repo, "load_conf; denied_tools 4")
    build = lines(repo, "load_conf; denied_tools 2")
    assert {"Edit(app/**)", "Write(tests/**)"} <= set(review)
    assert not {"Edit(app/**)", "Write(tests/**)"} & set(build)
    for denied in (review, build):
        assert {"Edit(gates/**)", "Write(.claude/**)", "Edit(factory.conf)", "Bash(rm:*)"} <= set(
            denied
        )


def test_protect_extra_is_added(tmp_path: Path) -> None:
    repo = conf(tmp_path, 'TEST_CMD="t"\nSCOPE="app/"\nPROTECT_EXTRA="venv package.json"\n')
    (repo / "venv").mkdir()
    denied = set(lines(repo, "load_conf; denied_tools 1"))
    assert {
        "Edit(package.json)",
        "Write(package.json)",
        "Edit(venv/**)",
        "Write(venv/**)",
    } <= denied


def test_missing_test_cmd_dies_with_message(tmp_path: Path) -> None:
    repo = conf(tmp_path, 'SCOPE="app/"\n')
    out = sh(repo, "load_conf")
    assert out.returncode == 1
    assert "factory.conf: TEST_CMD is required" in out.stderr


def test_missing_conf_file_dies_with_message(tmp_path: Path) -> None:
    out = sh(tmp_path, "load_conf")
    assert out.returncode == 1
    assert "factory.conf not found" in out.stderr


def test_env_overrides_model(tmp_path: Path) -> None:
    repo = conf(tmp_path, 'TEST_CMD="t"\nSCOPE="app/"\nMODEL="from-file"\n')
    import os

    env = {**os.environ, "FACTORY_MODEL": "x"}
    assert lines(repo, 'load_conf; echo "$MODEL"', env) == ["x"]
    assert lines(repo, 'load_conf; echo "$MODEL"') == ["from-file"]


def test_default_model_is_sonnet(tmp_path: Path) -> None:
    repo = conf(tmp_path, 'TEST_CMD="t"\nSCOPE="app/"\n')
    assert lines(repo, 'load_conf; echo "$MODEL"') == ["claude-sonnet-5-5"]


def test_in_scope(tmp_path: Path) -> None:
    repo = conf(tmp_path, 'TEST_CMD="t"\nSCOPE="app/ tests/"\n')
    out = lines(
        repo,
        'load_conf; for p in app/a.py tests/b.py README.md apps/x; do in_scope "$p" && echo "$p"; done; true',
    )
    assert out == ["app/a.py", "tests/b.py"]


def test_no_macos_only_constructs() -> None:
    scripts = [p for p in KIT.rglob("*.sh")] + [KIT / "factory.sh", KIT / "doctor.sh"]
    banned = ("sed -i ''", "shasum", "mapfile", "declare -A", "readarray")
    for path in {p for p in scripts if p.is_file()}:
        text = path.read_text()
        for word in banned:
            assert word not in text, f"{path.name} uses {word!r}"


def test_missing_conf_message_has_no_local_path(tmp_path: Path) -> None:
    # die messages reach the room board when telemetry is on; a path would carry the user's name
    out = sh(tmp_path, "load_conf")
    assert "factory.conf not found" in out.stderr
    assert str(tmp_path.resolve()) not in out.stderr and str(tmp_path) not in out.stderr
