#!/usr/bin/env python3
"""Deterministic OpenAI-compatible mock for harness benchmarks.

Serves /v1/chat/completions (streaming and not) with a fixed script chosen by
how many tool results the request already contains, so every harness sees the
same model behaviour: glob -> read_file -> edit_file -> bash -> grep -> final
answer. Also /v1/models. Usage: mock_openai.py PORT WORKDIR
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
WORK = sys.argv[2]

SCRIPT = [
    ("glob", {"pattern": "*.txt", "path": WORK}),
    ("read_file", {"path": f"{WORK}/notes.txt"}),
    ("edit_file", {"path": f"{WORK}/notes.txt", "old_string": "beta", "new_string": "gamma"}),
    ("bash", {"command": f"cat {WORK}/notes.txt && ls {WORK} | wc -l"}),
    ("grep", {"pattern": "gam+a", "path": WORK}),
]
FINAL = "Done: notes.txt now says alpha/gamma. " + ("padding " * 200)


def step(body):
    done = sum(1 for m in body.get("messages", []) if m.get("role") == "tool")
    if done < len(SCRIPT):
        name, args = SCRIPT[done]
        return None, {"id": f"call_{done}", "type": "function",
                      "function": {"name": name, "arguments": json.dumps(args)}}
    return FINAL, None


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send_json(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.send_json({"object": "list", "data": [{"id": "mock-model", "object": "model"}]})

    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        text, call = step(body)
        usage = {"prompt_tokens": 1000, "completion_tokens": 50, "total_tokens": 1050}
        if not body.get("stream"):
            msg = {"role": "assistant", "content": text}
            if call:
                msg["tool_calls"] = [call]
            self.send_json({"id": "x", "object": "chat.completion", "model": "mock-model",
                            "choices": [{"index": 0, "message": msg,
                                         "finish_reason": "tool_calls" if call else "stop"}],
                            "usage": usage})
            return
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()

        def ev(obj):
            data = f"data: {obj if isinstance(obj, str) else json.dumps(obj)}\n\n".encode()
            self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")

        def chunk(delta, finish=None):
            ev({"id": "x", "object": "chat.completion.chunk", "model": "mock-model",
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]})

        chunk({"role": "assistant"})
        if call:
            args = call["function"]["arguments"]
            chunk({"tool_calls": [{"index": 0, "id": call["id"], "type": "function",
                                   "function": {"name": call["function"]["name"], "arguments": ""}}]})
            for i in range(0, len(args), 16):
                chunk({"tool_calls": [{"index": 0, "function": {"arguments": args[i:i + 16]}}]})
            chunk({}, "tool_calls")
        else:
            for i in range(0, len(text), 8):
                chunk({"content": text[i:i + 8]})
            chunk({}, "stop")
        ev({"id": "x", "object": "chat.completion.chunk", "choices": [], "usage": usage})
        ev("[DONE]")
        self.wfile.write(b"0\r\n\r\n")


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
