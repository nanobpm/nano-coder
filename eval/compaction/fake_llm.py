"""A fake OpenAI-compatible endpoint for checking the eval harness itself.

It plays an "oracle" agent that reads its context perfectly and uses the
history tools whenever they are offered, but writes a summary that loses
every detail. So with it, standard compaction should fail the buried cases
and smart compaction should pass them. If it does not, the harness (or the
feature) is broken. It says nothing about real models.
"""
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOSSY_SUMMARY = "The user and the agent worked on the lease crate and then did several unrelated follow-ups. Details were not recorded."

# Question keyword -> pattern the oracle searches for.
SEARCHES = [("method", "no method named"), ("branch", "branch"), ("command", "--features"), ("mutex", "mutex"), ("ticket", "ticket")]


def reply(body):
    messages = body.get("messages", [])
    tools = {t["function"]["name"] for t in body.get("tools", [])}
    system = messages[0].get("content", "") if messages else ""
    if "compacting an AI agent's conversation" in system:
        return {"content": LOSSY_SUMMARY}
    last = messages[-1]
    question = next((m["content"] for m in reversed(messages) if m["role"] == "user"), "")
    if last["role"] == "user" and "history_search" in tools:
        pattern = next((p for word, p in SEARCHES if word in question.lower()), question.split()[0])
        return {"tool_calls": [{"id": "call_oracle", "type": "function",
                                "function": {"name": "history_search", "arguments": json.dumps({"pattern": pattern})}}]}
    # Answer from everything visible (the oracle reads context perfectly).
    visible = []
    for m in messages[1:]:
        if isinstance(m.get("content"), str):
            visible.append(m["content"])
        for call in m.get("tool_calls") or []:
            visible.append(call["function"]["arguments"])
    text = re.sub(r"never \d+", "", "\n".join(visible))
    return {"content": "From the conversation:\n" + text[-20000:]}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        message = {"role": "assistant", "content": None, **reply(body)}
        payload = json.dumps({
            "id": "fake", "object": "chat.completion", "model": body.get("model", "oracle"),
            "choices": [{"index": 0, "message": message, "finish_reason": "tool_calls" if message.get("tool_calls") else "stop"}],
            "usage": {"prompt_tokens": 100, "completion_tokens": 20, "total_tokens": 120},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def start():
    """Serve on a free port in a background thread; returns the base URL."""
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}/v1"
