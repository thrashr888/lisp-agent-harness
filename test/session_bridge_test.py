#!/usr/bin/env python3

import json
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from session_bridge import McpServer  # noqa: E402


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


class ExtensionToolMappingTest(unittest.TestCase):
    def test_every_extension_action_maps_to_the_live_repl(self):
        class RecordingSession:
            def __init__(self):
                self.commands = []

            def send(self, command, timeout):
                self.commands.append(command)
                return {"state": "ready", "output": command, "cursor": 1}

        session = RecordingSession()
        server = McpServer(session)
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


if __name__ == "__main__":
    unittest.main()
