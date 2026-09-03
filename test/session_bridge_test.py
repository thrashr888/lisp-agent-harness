#!/usr/bin/env python3

import json
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from session_bridge import LiveSession, McpServer  # noqa: E402


class FakeOllamaHandler(BaseHTTPRequestHandler):
    calls = 0

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        self.rfile.read(length)
        type(self).calls += 1
        if type(self).calls == 1:
            payload = {
                "message": {
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [
                        {
                            "id": "call_shell",
                            "function": {
                                "name": "shell",
                                "arguments": {"command": "printf approved"},
                            },
                        }
                    ],
                },
                "done": True,
            }
        else:
            payload = {
                "message": {"role": "assistant", "content": "shell approved"},
                "done": True,
            }
        body = (json.dumps(payload) + "\n").encode()
        self.send_response(200)
        self.send_header("content-type", "application/x-ndjson")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


class McpBridgeTest(unittest.TestCase):
    def setUp(self):
        FakeOllamaHandler.calls = 0
        self.ollama = HTTPServer(("127.0.0.1", 0), FakeOllamaHandler)
        self.ollama_thread = threading.Thread(
            target=self.ollama.serve_forever, daemon=True
        )
        self.ollama_thread.start()
        self.state_dir = Path(tempfile.mkdtemp(prefix="lisp-agent-mcp-test-"))
        self.process = subprocess.Popen(
            [
                "python3",
                str(ROOT / "scripts/session_bridge.py"),
                "--state-dir",
                str(self.state_dir),
            ],
            cwd=ROOT,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.next_id = 1
        initialized = self.rpc(
            "initialize",
            {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}},
        )
        self.assertEqual(initialized["protocolVersion"], "2025-06-18")

    def tearDown(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=5)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if stream is not None:
                stream.close()
        self.ollama.shutdown()
        self.ollama.server_close()
        shutil.rmtree(self.state_dir, ignore_errors=True)

    def rpc(self, method, params=None):
        request_id = self.next_id
        self.next_id += 1
        request = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            request["params"] = params
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()
        response = json.loads(self.process.stdout.readline())
        self.assertEqual(response["id"], request_id)
        self.assertNotIn("error", response)
        return response["result"]

    def call(self, name, arguments=None):
        result = self.rpc(
            "tools/call", {"name": name, "arguments": arguments or {}}
        )
        self.assertFalse(result.get("isError"), result)
        return json.loads(result["content"][0]["text"])

    def test_codex_can_operate_one_live_session(self):
        tools = self.rpc("tools/list")["tools"]
        self.assertIn("live_session_send", {tool["name"] for tool in tools})

        started = self.call("live_session_start", {"agent": "test/session-agent.scm"})
        self.assertTrue(started["running"])
        self.assertEqual(started["state"], "ready")
        self.assertIn("thinking off", started["output"])

        no_request = self.rpc(
            "tools/call",
            {"name": "live_session_approve", "arguments": {"approved": True}},
        )
        self.assertTrue(no_request.get("isError"))
        self.assertIn("not waiting", no_request["content"][0]["text"])

        response = self.call("live_session_send", {"text": "hello"})
        self.assertEqual(response["state"], "ready")
        self.assertIn("[mcp-test] hello", response["output"])

        setting = self.call(
            "live_session_set", {"name": "thinking", "value": "on"}
        )
        self.assertIn("thinking on", setting["output"])

        prompt = self.call("live_session_add_prompt", {"text": "Call me Paul."})
        self.assertIn("generation 3", prompt["output"])

        extensions = self.call("live_extension", {"action": "list"})
        self.assertEqual(extensions["state"], "ready")

        transcript = self.call("live_session_read", {"cursor": 0})
        self.assertIn("[mcp-test] hello", transcript["output"])

        port = self.ollama.server_address[1]
        shell_settings = self.call(
            "live_session_eval",
            {
                "expression": (
                    f'(begin (set! agent-model "fake") '
                    f'(set! agent-base-url "http://127.0.0.1:{port}") '
                    "(set! agent-tools '(shell)) "
                    "(set! agent-shell-policy 'ask))"
                )
            },
        )
        self.assertIn("generation 4", shell_settings["output"])

        approval_boundary = self.call(
            "live_session_send", {"text": "run the requested shell", "timeout_seconds": 5}
        )
        self.assertEqual(approval_boundary["state"], "needs_approval")
        self.assertIn("printf approved", approval_boundary["output"])

        # The bridge sends only this one byte. If the terminal still required
        # Enter, this call would time out instead of reaching the next prompt.
        approved = self.call(
            "live_session_approve", {"approved": True, "timeout_seconds": 5}
        )
        self.assertEqual(approved["state"], "ready")
        self.assertIn("shell approved", approved["output"])

        stopped = self.call("live_session_stop")
        self.assertFalse(stopped["running"])

    def test_named_sessions_run_independently_and_resume(self):
        alpha = self.call(
            "live_session_start",
            {
                "session": "alpha",
                "mode": "new",
                "agent": "test/session-agent.scm",
                "prompt": "alpha opening",
            },
        )
        beta = self.call(
            "live_session_start",
            {"session": "beta", "mode": "new", "agent": "test/session-agent.scm"},
        )
        self.assertNotEqual(alpha["pid"], beta["pid"])
        self.assertIn("[mcp-test] alpha opening", alpha["output"])
        self.assertEqual(alpha["next_turn"], 2)

        self.assertIn(
            "[mcp-test] alpha message",
            self.call(
                "live_session_send",
                {"session": "alpha", "text": "alpha message"},
            )["output"],
        )
        self.assertIn(
            "[mcp-test] beta message",
            self.call(
                "live_session_send",
                {"session": "beta", "text": "beta message"},
            )["output"],
        )
        self.call(
            "live_session_set",
            {"session": "alpha", "name": "thinking", "value": "on"},
        )

        sessions = self.call("live_sessions_list")["sessions"]
        self.assertEqual([entry["session"] for entry in sessions], ["alpha", "beta"])
        self.assertTrue(all(entry["running"] for entry in sessions))

        self.call("live_session_stop", {"session": "alpha"})
        resumed = self.call(
            "live_session_start",
            {"session": "alpha", "mode": "resume", "agent": "test/session-agent.scm"},
        )
        self.assertIn("session alpha · resumed · turn 3", resumed["output"])
        self.assertIn("generation 2", resumed["output"])
        self.assertEqual(resumed["next_turn"], 3)
        self.assertEqual(resumed["generation"], 2)
        self.assertTrue(
            self.call("live_session_status", {"session": "beta"})["running"]
        )

        self.call("live_session_stop", {"session": "alpha"})
        existing = self.rpc(
            "tools/call",
            {
                "name": "live_session_start",
                "arguments": {
                    "session": "alpha",
                    "mode": "new",
                    "agent": "test/session-agent.scm",
                },
            },
        )
        self.assertTrue(existing.get("isError"))
        self.assertIn("already exists", existing["content"][0]["text"])

        missing = self.rpc(
            "tools/call",
            {
                "name": "live_session_start",
                "arguments": {
                    "session": "missing",
                    "mode": "resume",
                    "agent": "test/session-agent.scm",
                },
            },
        )
        self.assertTrue(missing.get("isError"))
        self.assertIn("does not exist", missing["content"][0]["text"])


class ExtensionToolMappingTest(unittest.TestCase):
    def test_every_extension_action_maps_to_the_live_repl(self):
        class RecordingSession:
            def __init__(self):
                self.commands = []

            def send(self, command, timeout):
                self.commands.append(command)
                return {"state": "ready", "output": command, "cursor": 1}

        session = RecordingSession()
        state_root = Path(tempfile.mkdtemp(prefix="lisp-agent-recording-test-"))
        server = McpServer(
            ROOT, state_root, lambda project_root, state_dir, name: session
        )
        server.call_tool("live_extension", {"action": "list"})
        server.call_tool(
            "live_extension",
            {"action": "create", "name": "terse", "expression": '(set! agent-system-prompt "Terse")'},
        )
        server.call_tool("live_extension", {"action": "load", "name": "terse"})
        server.call_tool("live_extension", {"action": "disable", "name": "terse"})
        server.call_tool("live_extension", {"action": "export", "name": "snapshot"})
        self.assertEqual(
            session.commands,
            [
                "/extensions",
                '/extension-create terse (set! agent-system-prompt "Terse")',
                "/extension-load terse",
                "/extension-disable terse",
                "/extension-export snapshot",
            ],
        )
        shutil.rmtree(state_root, ignore_errors=True)


class HotReloadTest(unittest.TestCase):
    def test_running_process_activates_valid_saves_and_rejects_invalid_ones(self):
        project_root = Path(tempfile.mkdtemp(prefix="lisp-agent-watch-test-"))
        session = None
        try:
            (project_root / "bin").mkdir()
            (project_root / "agent").mkdir()
            (project_root / "extensions").mkdir()
            (project_root / "src").symlink_to(ROOT / "src", target_is_directory=True)
            shutil.copy2(ROOT / "bin/lisp-agent", project_root / "bin/lisp-agent")
            agent_path = project_root / "agent/default.scm"
            source = (ROOT / "test/session-agent.scm").read_text()
            agent_path.write_text(source)

            session = LiveSession(project_root, project_root / ".lisp-agent")
            started = session.start()
            self.assertEqual(started["state"], "ready")
            cursor = started["cursor"]

            updated = source.replace("[mcp-test] ", "[hot-reloaded] ")
            agent_path.write_text(updated)
            valid_notice = self.wait_for_text(session, cursor, "agent image reloaded")
            self.assertIn("generation 2", valid_notice)

            response = session.send("hello", 5)
            self.assertIn("[hot-reloaded] hello", response["output"])

            cursor = response["cursor"]
            invalid = updated.replace("(define agent-name", "(define missing-agent-name")
            agent_path.write_text(invalid)
            rejected_notice = self.wait_for_text(session, cursor, "change rejected")
            self.assertIn("generation 2 remains active", rejected_notice)
            time.sleep(0.6)
            self.assertEqual(
                session.read(cursor)["output"].count("change rejected"), 1
            )

            response = session.send("still there", 5)
            self.assertIn("[hot-reloaded] still there", response["output"])
        finally:
            if session is not None:
                session.stop()
            shutil.rmtree(project_root, ignore_errors=True)

    @staticmethod
    def wait_for_text(session, cursor, expected):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            output = session.read(cursor)["output"]
            if expected in output:
                return output
            time.sleep(0.05)
        raise AssertionError(f"timed out waiting for {expected!r}; output={output!r}")


if __name__ == "__main__":
    unittest.main()
