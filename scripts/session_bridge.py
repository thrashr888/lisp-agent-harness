#!/usr/bin/env python3
"""Dependency-free MCP bridge for Codex-managed live harness sessions."""

from __future__ import annotations

import argparse
import json
import os
import pty
import re
import subprocess
import sys
import termios
import threading
import time
from pathlib import Path
from typing import Any


PROMPT = "live-agent> "
APPROVAL_PROMPT = "Approve this command? [y/N] "
MAX_TRANSCRIPT_CHARS = 2 * 1024 * 1024
SAFE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}")


def object_schema(properties: dict[str, Any], required: list[str] | None = None) -> dict[str, Any]:
    return {
        "type": "object",
        "properties": properties,
        "required": required or [],
        "additionalProperties": False,
    }


SESSION_PROPERTY = {
    "type": "string",
    "description": "Durable session name. Defaults to 'default'.",
    "pattern": r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$",
}


def session_schema(
    properties: dict[str, Any], required: list[str] | None = None
) -> dict[str, Any]:
    return object_schema({"session": SESSION_PROPERTY, **properties}, required)


TOOLS = [
    {
        "name": "live_sessions_list",
        "description": "List durable and currently running Lisp agent sessions.",
        "inputSchema": object_schema({}),
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "live_session_start",
        "description": "Start or resume one named MCP-owned live Lisp agent session.",
        "inputSchema": session_schema(
            {
                "agent": {"type": "string", "description": "Optional project-relative agent image path."},
                "mode": {
                    "type": "string",
                    "enum": ["auto", "new", "resume"],
                    "description": "Auto resumes or creates; new and resume are strict.",
                },
            }
        ),
    },
    {
        "name": "live_session_status",
        "description": "Read whether the live session is running and its transcript cursor.",
        "inputSchema": session_schema({}),
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "live_session_send",
        "description": (
            "Send a user prompt to the live session and return streamed output through the next "
            "agent prompt or shell-approval boundary."
        ),
        "inputSchema": session_schema(
            {
                "text": {"type": "string"},
                "timeout_seconds": {"type": "number", "minimum": 1, "maximum": 600},
            },
            ["text"],
        ),
    },
    {
        "name": "live_session_read",
        "description": "Read transcript output at or after an optional absolute cursor.",
        "inputSchema": session_schema(
            {"cursor": {"type": "integer", "minimum": 0}}
        ),
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "live_session_approve",
        "description": "Answer the current shell request with one y or N keystroke.",
        "inputSchema": session_schema(
            {
                "approved": {"type": "boolean"},
                "timeout_seconds": {"type": "number", "minimum": 1, "maximum": 600},
            },
            ["approved"],
        ),
    },
    {
        "name": "live_session_set",
        "description": "Change a live session setting by creating a transactional generation.",
        "inputSchema": session_schema(
            {
                "name": {"type": "string", "enum": ["thinking", "stream"]},
                "value": {"type": "string"},
            },
            ["name", "value"],
        ),
    },
    {
        "name": "live_session_add_prompt",
        "description": "Append text to the live system prompt transactionally for later turns.",
        "inputSchema": session_schema(
            {"text": {"type": "string"}}, ["text"]
        ),
    },
    {
        "name": "live_session_eval",
        "description": "Apply a restricted Scheme live expression to the managed session.",
        "inputSchema": session_schema(
            {"expression": {"type": "string"}}, ["expression"]
        ),
    },
    {
        "name": "live_extension",
        "description": "List, create, load, disable, or export persistent live extension artifacts.",
        "inputSchema": session_schema(
            {
                "action": {
                    "type": "string",
                    "enum": ["list", "create", "load", "disable", "export"],
                },
                "name": {"type": "string"},
                "expression": {"type": "string"},
            },
            ["action"],
        ),
    },
    {
        "name": "live_session_stop",
        "description": "Stop the MCP-owned live session.",
        "inputSchema": session_schema({}),
    },
]


class LiveSession:
    def __init__(self, project_root: Path, state_root: Path, name: str = "default") -> None:
        if not isinstance(name, str) or not SAFE_NAME.fullmatch(name):
            raise ValueError("session names must match [A-Za-z0-9][A-Za-z0-9._-]*")
        self.project_root = project_root.resolve()
        self.state_root = state_root.resolve()
        self.name = name
        self.state_dir = self.state_root / "sessions" / name
        self.process: subprocess.Popen[bytes] | None = None
        self.master_fd: int | None = None
        self._base_cursor = 0
        self._transcript = ""
        self._condition = threading.Condition()

    def _running(self) -> bool:
        return self.process is not None and self.process.poll() is None

    def _cursor(self) -> int:
        return self._base_cursor + len(self._transcript)

    def _append(self, value: str) -> None:
        with self._condition:
            self._transcript += value
            if len(self._transcript) > MAX_TRANSCRIPT_CHARS:
                removed = len(self._transcript) - MAX_TRANSCRIPT_CHARS
                self._transcript = self._transcript[removed:]
                self._base_cursor += removed
            self._condition.notify_all()

    def _reader(self, fd: int) -> None:
        while True:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            self._append(chunk.decode("utf-8", errors="replace"))
        with self._condition:
            self._condition.notify_all()

    def _resolve_agent(self, requested: str | None) -> Path:
        candidate = (self.project_root / (requested or "agent/default.scm")).resolve()
        try:
            candidate.relative_to(self.project_root)
        except ValueError as error:
            raise ValueError("agent path escapes the project root") from error
        if not candidate.is_file():
            raise ValueError(f"agent image does not exist: {requested or 'agent/default.scm'}")
        return candidate

    def _segment(self, cursor: int) -> str:
        start = max(cursor, self._base_cursor) - self._base_cursor
        return self._transcript[start:]

    @staticmethod
    def _clean(value: str) -> str:
        value = value.replace("\r\n", "\n").replace("\r", "")
        return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", value)

    def _wait_for_boundary(self, cursor: int, timeout_seconds: float) -> dict[str, Any]:
        deadline = time.monotonic() + timeout_seconds
        with self._condition:
            while True:
                segment = self._segment(cursor)
                clean_segment = self._clean(segment)
                if clean_segment.endswith(APPROVAL_PROMPT):
                    state = "needs_approval"
                    break
                if clean_segment.endswith(PROMPT):
                    state = "ready"
                    break
                if not self._running():
                    state = "stopped"
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    state = "timeout"
                    break
                self._condition.wait(min(remaining, 0.25))
            return {
                "state": state,
                "output": self._clean(self._segment(cursor)),
                "cursor": self._cursor(),
            }

    def _write(self, value: bytes) -> None:
        if not self._running() or self.master_fd is None:
            raise RuntimeError("live session is not running; call live_session_start first")
        os.write(self.master_fd, value)

    def _awaiting_approval(self) -> bool:
        with self._condition:
            return self._clean(self._transcript).endswith(APPROVAL_PROMPT)

    def start(self, agent: str | None = None, mode: str = "auto") -> dict[str, Any]:
        if self._running():
            return {**self.status(), "state": "ready", "output": "Session already running."}
        if mode not in {"auto", "new", "resume"}:
            raise ValueError("mode must be auto, new, or resume")
        image = self._resolve_agent(agent)
        checkpoint_exists = (self.state_dir / "session.json").is_file()
        if mode == "new" and checkpoint_exists:
            raise ValueError(f"session already exists: {self.name}")
        if mode == "resume" and not checkpoint_exists:
            raise ValueError(f"session does not exist: {self.name}")
        self.state_root.mkdir(parents=True, exist_ok=True)
        marker = self._cursor()
        master_fd, slave_fd = pty.openpty()
        terminal_attributes = termios.tcgetattr(slave_fd)
        terminal_attributes[3] &= ~(termios.ECHO | termios.ECHONL)
        termios.tcsetattr(slave_fd, termios.TCSANOW, terminal_attributes)
        environment = os.environ.copy()
        environment.setdefault("TERM", "dumb")
        command = [
            str(self.project_root / "bin/lisp-agent"),
            "--agent",
            str(image),
            "--state-dir",
            str(self.state_root),
            {"auto": "--session", "new": "--new-session", "resume": "--resume"}[mode],
            self.name,
        ]
        try:
            process = subprocess.Popen(
                command,
                cwd=self.project_root,
                env=environment,
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                close_fds=True,
            )
        finally:
            os.close(slave_fd)
        self.process = process
        self.master_fd = master_fd
        threading.Thread(target=self._reader, args=(master_fd,), daemon=True).start()
        result = self._wait_for_boundary(marker, 15)
        result.update(self.status())
        return result

    def status(self) -> dict[str, Any]:
        result = {
            "session": self.name,
            "running": self._running(),
            "pid": self.process.pid if self._running() and self.process else None,
            "cursor": self._cursor(),
            "state_dir": str(self.state_dir),
            "resumable": (self.state_dir / "session.json").is_file(),
        }
        try:
            checkpoint = json.loads((self.state_dir / "session.json").read_text())
            result.update(
                {
                    "session_id": checkpoint.get("id"),
                    "generation": checkpoint.get("generation_id"),
                    "next_turn": checkpoint.get("next_turn"),
                }
            )
        except (OSError, ValueError):
            pass
        return result

    def send(self, text: str, timeout_seconds: float = 180) -> dict[str, Any]:
        if not isinstance(text, str) or not text.strip():
            raise ValueError("text must be a non-empty string")
        if self._awaiting_approval():
            raise RuntimeError("a shell request is waiting; approve or deny it before sending input")
        marker = self._cursor()
        self._write(text.encode("utf-8") + b"\n")
        return self._wait_for_boundary(marker, timeout_seconds)

    def approve(self, approved: bool, timeout_seconds: float = 180) -> dict[str, Any]:
        if not isinstance(approved, bool):
            raise ValueError("approved must be a boolean")
        if not self._awaiting_approval():
            raise RuntimeError("the live session is not waiting for shell approval")
        marker = self._cursor()
        self._write(b"y" if approved else b"n")
        return self._wait_for_boundary(marker, timeout_seconds)

    def read(self, cursor: int | None = None) -> dict[str, Any]:
        with self._condition:
            requested = self._base_cursor if cursor is None else int(cursor)
            return {
                **self.status(),
                "from_cursor": max(requested, self._base_cursor),
                "output": self._clean(self._segment(requested)),
            }

    def stop(self) -> dict[str, Any]:
        if not self._running():
            if self.master_fd is not None:
                try:
                    os.close(self.master_fd)
                except OSError:
                    pass
                self.master_fd = None
            return {**self.status(), "state": "stopped", "output": "Session is not running."}
        assert self.process is not None
        try:
            self._write(b"/quit\n")
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        if self.master_fd is not None:
            try:
                os.close(self.master_fd)
            except OSError:
                pass
            self.master_fd = None
        return {**self.status(), "state": "stopped", "output": "Session stopped."}


def scheme_string(value: str) -> str:
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )
    return f'"{escaped}"'


class McpServer:
    def __init__(self, project_root: Path, state_root: Path, session_factory=LiveSession) -> None:
        self.project_root = project_root.resolve()
        self.state_root = state_root.resolve()
        self.session_factory = session_factory
        self.sessions: dict[str, LiveSession] = {}

    @staticmethod
    def _session_name(arguments: dict[str, Any]) -> str:
        name = arguments.get("session", "default")
        if not isinstance(name, str) or not SAFE_NAME.fullmatch(name):
            raise ValueError("session names must match [A-Za-z0-9][A-Za-z0-9._-]*")
        return name

    def _session(self, arguments: dict[str, Any]) -> LiveSession:
        name = self._session_name(arguments)
        if name not in self.sessions:
            self.sessions[name] = self.session_factory(
                self.project_root, self.state_root, name
            )
        return self.sessions[name]

    def _list_sessions(self) -> dict[str, Any]:
        names = set(self.sessions)
        root = self.state_root / "sessions"
        if root.is_dir():
            names.update(
                path.parent.name
                for path in root.glob("*/session.json")
                if SAFE_NAME.fullmatch(path.parent.name)
            )
        return {
            "sessions": [self._session({"session": name}).status() for name in sorted(names)]
        }

    def _run_command(
        self, session: LiveSession, command: str, arguments: dict[str, Any]
    ) -> dict[str, Any]:
        timeout = float(arguments.get("timeout_seconds", 180))
        return session.send(command, timeout)

    def call_tool(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        if name == "live_sessions_list":
            result = self._list_sessions()
            return {"content": [{"type": "text", "text": json.dumps(result, indent=2)}]}

        session = self._session(arguments)
        if name == "live_session_start":
            result = session.start(arguments.get("agent"), arguments.get("mode", "auto"))
        elif name == "live_session_status":
            result = session.status()
        elif name == "live_session_send":
            result = session.send(
                arguments.get("text"), float(arguments.get("timeout_seconds", 180))
            )
        elif name == "live_session_read":
            result = session.read(arguments.get("cursor"))
        elif name == "live_session_approve":
            if not isinstance(arguments.get("approved"), bool):
                raise ValueError("approved must be a boolean")
            result = session.approve(
                arguments["approved"],
                float(arguments.get("timeout_seconds", 180)),
            )
        elif name == "live_session_set":
            setting = arguments.get("name")
            value = arguments.get("value")
            if setting == "thinking" and value in {"off", "on", "low", "medium", "high"}:
                result = self._run_command(session, f"/thinking {value}", arguments)
            elif setting == "stream" and value in {"off", "on"}:
                result = self._run_command(session, f"/stream {value}", arguments)
            else:
                raise ValueError("unsupported setting value")
        elif name == "live_session_add_prompt":
            text = arguments.get("text")
            if not isinstance(text, str) or not text:
                raise ValueError("text must be a non-empty string")
            expression = (
                "(set! agent-system-prompt (string-append agent-system-prompt "
                + scheme_string("\n\n" + text)
                + "))"
            )
            result = self._run_command(session, f"/eval {expression}", arguments)
        elif name == "live_session_eval":
            expression = arguments.get("expression")
            if not isinstance(expression, str) or not expression.strip():
                raise ValueError("expression must be a non-empty string")
            result = self._run_command(session, f"/eval {expression}", arguments)
        elif name == "live_extension":
            action = arguments.get("action")
            extension_name = arguments.get("name")
            if action == "list":
                command = "/extensions"
            else:
                if not isinstance(extension_name, str) or not re.fullmatch(
                    r"[A-Za-z0-9][A-Za-z0-9._-]*", extension_name
                ):
                    raise ValueError("a safe extension name is required")
                if action == "create":
                    expression = arguments.get("expression")
                    if not isinstance(expression, str) or not expression.strip():
                        raise ValueError("create requires a non-empty expression")
                    command = f"/extension-create {extension_name} {expression}"
                elif action in {"load", "disable", "export"}:
                    command = f"/extension-{action} {extension_name}"
                else:
                    raise ValueError("unsupported extension action")
            result = self._run_command(session, command, arguments)
        elif name == "live_session_stop":
            result = session.stop()
        else:
            raise ValueError(f"unknown tool: {name}")
        return {"content": [{"type": "text", "text": json.dumps(result, indent=2)}]}

    def close(self) -> None:
        for session in self.sessions.values():
            session.stop()

    def handle(self, request: dict[str, Any]) -> dict[str, Any] | None:
        method = request.get("method")
        request_id = request.get("id")
        if method == "initialize":
            version = request.get("params", {}).get("protocolVersion", "2025-06-18")
            result = {
                "protocolVersion": version,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "lisp-agent-harness", "version": "0.1.0"},
            }
        elif method == "tools/list":
            result = {"tools": TOOLS}
        elif method == "tools/call":
            params = request.get("params", {})
            try:
                result = self.call_tool(params.get("name", ""), params.get("arguments") or {})
            except Exception as error:  # MCP tools report operational failures in-band.
                result = {
                    "content": [{"type": "text", "text": str(error)}],
                    "isError": True,
                }
        elif method == "ping":
            result = {}
        elif request_id is None:
            return None
        else:
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32601, "message": f"Method not found: {method}"},
            }
        if request_id is None:
            return None
        return {"jsonrpc": "2.0", "id": request_id, "result": result}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir")
    options = parser.parse_args()
    project_root = Path(__file__).resolve().parents[1]
    state_dir = Path(options.state_dir) if options.state_dir else project_root / ".lisp-agent"
    server = McpServer(project_root, state_dir)
    try:
        for line in sys.stdin:
            if not line.strip():
                continue
            request: dict[str, Any] = {}
            try:
                request = json.loads(line)
                response = server.handle(request)
            except Exception as error:
                request_id = request.get("id") if isinstance(request, dict) else None
                response = {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {"code": -32603, "message": str(error)},
                }
            if response is not None:
                print(json.dumps(response, separators=(",", ":")), flush=True)
    finally:
        server.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
