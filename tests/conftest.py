"""Shared fixtures: a problem repo wired to a fake fork and upstream, and stub claude/gh on PATH.

Nothing here spends tokens or touches GitHub: the remotes are local bare repos and the
`claude` and `gh` on PATH are the scripts in tests/stubs.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading
import time
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
KIT = ROOT / "kit"
STUBS = Path(__file__).resolve().parent / "stubs"

sys.path.insert(0, str(KIT))  # so `from dashboard import ...` works in panel tests

FACTORY_CONF = 'TEST_CMD="./check.sh"\nLINT_CMD="./lint.sh"\nSCOPE="app/ tests/"\n'
GITIGNORE = ".factory/*\n!.factory/.gitkeep\n"


def git(repo: Path, *args: str, env: dict[str, str] | None = None) -> str:
    out = subprocess.run(
        ["git", *args], cwd=repo, env=env, capture_output=True, text=True, check=True
    )
    return out.stdout.strip()


@pytest.fixture
def stub_env(tmp_path: Path) -> dict[str, str]:
    stub_dir = tmp_path / "stub"
    stub_dir.mkdir()
    gitconfig = tmp_path / "gitconfig"
    gitconfig.write_text(
        "[user]\n\tname = Test\n\temail = test@example.com\n[init]\n\tdefaultBranch = main\n"
    )
    env = {k: v for k, v in os.environ.items() if not k.startswith(("FACTORY_", "STUB_", "GIT_"))}
    env.update(
        PATH=f"{STUBS}{os.pathsep}{env['PATH']}",
        STUB_DIR=str(stub_dir),
        STUB_GH_USER="ana",
        STUB_GH_UPSTREAM="workshop/leaderboard-api",
        STUB_ISSUE_TITLE="Add stats",
        GIT_CONFIG_GLOBAL=str(gitconfig),
        GIT_CONFIG_NOSYSTEM="1",
    )
    return env


def _executable(path: Path, body: str) -> None:
    path.write_text(body)
    path.chmod(0o755)


@pytest.fixture
def kit_repo(tmp_path: Path, stub_env: dict[str, str]) -> Path:
    upstream = tmp_path / "upstream.git"
    fork = tmp_path / "fork.git"
    repo = tmp_path / "repo"
    for bare in (upstream, fork):
        subprocess.run(
            ["git", "init", "-q", "--bare", "-b", "main", str(bare)], env=stub_env, check=True
        )
    repo.mkdir()
    git(repo, "init", "-q", "-b", "main", env=stub_env)
    if KIT.is_dir():
        shutil.copytree(KIT, repo, dirs_exist_ok=True, ignore=shutil.ignore_patterns("__pycache__"))
    (repo / "factory.conf").write_text(FACTORY_CONF)
    _executable(repo / "check.sh", "#!/usr/bin/env bash\nexit 0\n")
    _executable(repo / "lint.sh", "#!/usr/bin/env bash\nexit 0\n")
    for rel, text in {
        "app/x.txt": "app\n",
        "tests/t.txt": "test\n",
        "AGENTS.md": "# Agents\n",
    }.items():
        (repo / rel).parent.mkdir(parents=True, exist_ok=True)
        (repo / rel).write_text(text)
    (repo / ".factory").mkdir(exist_ok=True)
    (repo / ".factory" / ".gitkeep").write_text("")
    (repo / ".gitignore").write_text(GITIGNORE)
    git(repo, "add", "-A", env=stub_env)
    git(repo, "commit", "-q", "-m", "Initial commit", env=stub_env)
    for name, bare in (("origin", fork), ("upstream", upstream)):
        git(repo, "remote", "add", name, str(bare), env=stub_env)
        git(repo, "push", "-q", name, "main", env=stub_env)
    git(repo, "fetch", "-q", "upstream", env=stub_env)
    return repo


def run_factory(repo: Path, env: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "factory.sh", *args], cwd=repo, env=env, capture_output=True, text=True, timeout=60
    )


class TelemetryServer:
    """A dashboard stand-in on 127.0.0.1 (ephemeral port): records every POST the client sends."""

    def __init__(self) -> None:
        self.requests: list[dict[str, object]] = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:  # noqa: N802
                body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
                outer.requests.append(
                    {"path": self.path, "headers": dict(self.headers.items()), "body": body}
                )
                self.send_response(200)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"{}")

            def log_message(self, *args: object) -> None:
                pass

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def events(self) -> list[dict[str, object]]:
        """Every event line received so far, in the order the client numbered them."""
        rows = [
            json.loads(line)
            for req in list(self.requests)
            for line in str(req["body"]).splitlines()
            if line.strip()
        ]
        return sorted(rows, key=lambda row: row["seq"])

    def wait_for(self, event: str, timeout: float = 15.0) -> list[dict[str, object]]:
        """Delivery is detached and asynchronous: poll until `event` has arrived."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            rows = self.events()
            if any(row["event"] == event for row in rows):
                return rows
            time.sleep(0.05)
        raise AssertionError(f"no {event!r} event arrived; got {[r['event'] for r in self.events()]}")


@pytest.fixture
def telemetry_server() -> Iterator[TelemetryServer]:
    server = TelemetryServer()
    yield server
    server.httpd.shutdown()
    server.httpd.server_close()


@pytest.fixture
def curl_calls(tmp_path: Path, stub_env: dict[str, str]) -> Path:
    """Puts a `curl` first on PATH that only records that it was called (and fails), so a test can
    prove nothing tried the network. Returns the log file, which exists only once curl is called."""
    bin_dir = tmp_path / "fakebin"
    bin_dir.mkdir()
    log = tmp_path / "curl.log"
    _executable(bin_dir / "curl", f'#!/usr/bin/env bash\necho "$*" >>"{log}"\nexit 7\n')
    stub_env["PATH"] = f"{bin_dir}{os.pathsep}{stub_env['PATH']}"
    return log


def telemetry_env(env: dict[str, str], tmp_path: Path, url: str) -> dict[str, str]:
    """env plus the telemetry settings, with the client's identity cache kept inside tmp_path."""
    return {
        **env,
        "FACTORY_TELEMETRY_URL": url,
        "FACTORY_TELEMETRY_TOKEN": "s3cret-token",
        "FACTORY_WORKSHOP": "nov-10",
        "FACTORY_PARTICIPANT": "ana",
        "HOME": str(tmp_path / "home"),
        "XDG_CACHE_HOME": str(tmp_path / "cache"),
    }
