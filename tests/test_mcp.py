from __future__ import annotations

import json
import os
import queue
import subprocess
import sys
import threading
import unittest
from pathlib import Path


SERVER = Path(__file__).resolve().parents[1] / "mcp" / "terrasys_mcp.py"


class McpTransportTests(unittest.TestCase):
    def start_server(self) -> subprocess.Popen:
        process = subprocess.Popen(
            [sys.executable, str(SERVER)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )

        def cleanup() -> None:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)

        self.addCleanup(cleanup)
        return process

    def test_initialize_responds_before_stdin_is_closed(self) -> None:
        process = self.start_server()
        response_lines: queue.Queue[bytes] = queue.Queue()
        threading.Thread(target=lambda: response_lines.put(process.stdout.readline()), daemon=True).start()
        process.stdin.write(json.dumps({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2024-11-05", "clientInfo": {"name": "测试", "version": "1"}},
        }, ensure_ascii=False).encode("utf-8") + b"\n")
        process.stdin.flush()
        line = response_lines.get(timeout=5)
        self.assertTrue(line.endswith(b"\n"))
        response = json.loads(line)
        self.assertEqual(response["id"], 1)
        self.assertEqual(response["result"]["protocolVersion"], "2024-11-05")

    def exchange(self, messages: bytes) -> list[dict]:
        process = self.start_server()
        stdout, stderr = process.communicate(messages, timeout=5)
        self.assertEqual(process.returncode, 0, stderr.decode("utf-8", errors="replace"))
        self.assertFalse(stderr)
        return [json.loads(line) for line in stdout.splitlines()]

    def test_multiple_messages_and_notification_share_one_stream(self) -> None:
        messages = [
            {"jsonrpc": "2.0", "id": "init", "method": "initialize"},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": "tools", "method": "tools/list"},
        ]
        responses = self.exchange(b"".join(json.dumps(item).encode() + b"\n" for item in messages))
        self.assertEqual([item["id"] for item in responses], ["init", "tools"])
        self.assertIn("terrasys_search", {tool["name"] for tool in responses[1]["result"]["tools"]})

    def test_invalid_frame_does_not_reuse_previous_id_or_break_next_message(self) -> None:
        responses = self.exchange(
            b'{"jsonrpc":"2.0","id":4,"method":"tools/list"}\n'
            b'{invalid}\n'
            b'\xff\n'
            b'[]\n'
            b'{"jsonrpc":"2.0","id":5,"method":"tools/list"}\n'
        )
        self.assertEqual([item["id"] for item in responses], [4, None, None, None, 5])
        self.assertEqual([item["error"]["code"] for item in responses[1:4]], [-32700, -32700, -32600])


if __name__ == "__main__":
    unittest.main()
