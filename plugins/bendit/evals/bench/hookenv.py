"""A throwaway project and a real hook call, shared by latency.py and corpus.py.

Nothing here touches the person's real state: the project is a fresh git repo
under a temp dir, and HOME, XDG_*, BENDIT_CONFIG_DIR all point inside it.
Python 3.9, standard library only.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent.parent / "scripts"


class Sandbox:
    """A scratch project plus an environment that cannot reach real state."""

    def __init__(self, shell: str = "/bin/zsh", ls_guard: bool = True):
        self.root = Path(tempfile.mkdtemp(prefix="bendit-bench-")).resolve()
        self.project = self.root / "proj"
        self.project.mkdir()
        git_env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"}
        subprocess.run(["git", "init", "-q", str(self.project)], check=True, env=git_env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("BENDIT_", "CLAUDE", "XDG_")) and k != "SHELL"}
        home = self.root / "home"
        home.mkdir()
        env.update({
            "HOME": str(home), "XDG_CACHE_HOME": str(home / ".cache"),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "BENDIT_CONFIG_DIR": str(self.root / "bendit-config"),
            "CLAUDE_PROJECT_DIR": str(self.project),
            "SHELL": shell, "PYTHONDONTWRITEBYTECODE": "1",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
        })
        self.env = env
        if ls_guard:
            r = subprocess.run([sys.executable, str(SCRIPTS / "features.py"), "set", str(self.project),
                                "ls-guard", "on", "benchmark sandbox"], env=env,
                               capture_output=True, text=True)
            if r.returncode != 0:
                raise RuntimeError("could not turn ls-guard on: " + r.stderr)

    def close(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)

    def payload(self, tool: str, tool_input: dict, event: str = "PreToolUse", response=None) -> bytes:
        d = {"session_id": "bench", "cwd": str(self.project), "hook_event_name": event,
             "tool_name": tool, "tool_input": tool_input}
        if response is not None:
            d["tool_response"] = response
        return json.dumps(d).encode()

    def bash(self, command: str, event: str = "PreToolUse") -> bytes:
        resp = {"stdout": "", "stderr": "", "interrupted": False} if event == "PostToolUse" else None
        return self.payload("Bash", {"command": command}, event, resp)

    def run(self, script: str, args, stdin: bytes, python: str = "python3"):
        """One real hook call. Returns (returncode, stderr text, wall seconds)."""
        t0 = time.perf_counter()
        r = subprocess.run([python, str(SCRIPTS / script)] + list(args), input=stdin,
                           capture_output=True, cwd=str(self.project), env=self.env)
        dt = time.perf_counter() - t0
        return r.returncode, r.stderr.decode("utf-8", "replace"), dt


def wilson(k: int, n: int, z: float = 1.96):
    """Wilson score interval for k successes in n trials."""
    if n == 0:
        return (0.0, 1.0)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * ((p * (1 - p) / n + z * z / (4 * n * n)) ** 0.5) / d
    return (max(0.0, c - h), min(1.0, c + h))
