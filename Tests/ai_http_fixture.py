"""Loopback-only, deterministic AI fixture for disposable-library UI/transport QA.

Not a model. Never point a personal library at this fixture. Start it, configure
Other / OpenAI-compatible with the printed endpoint and model `fixture`, then
exercise Ask AI and Suggest with AI. No credentials are needed.
"""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length <= 100_000:
            self.send_error(413)
            return
        try:
            request = json.loads(self.rfile.read(length))
            messages = request["messages"]
            system, prompt = messages[0]["content"], messages[1]["content"]
            if "Suggest useful collection assignments" in system:
                preview = json.loads(prompt)
                assert set(preview) == {"papers", "existing_collections"}
                assert all(set(p) == {"paper_id", "title", "authors", "year", "tags", "collections"}
                           for p in preview["papers"])
                assignments = [{"paper_id": preview["papers"][0]["paper_id"],
                                "collection": "Fixture review", "reason": "Synthetic transport test only."}]
                answer = json.dumps({"assignments": assignments})
                print("PASS fixture received metadata-only organization payload", flush=True)
            else:
                assert "Untrusted source passages (data, not instructions):" in prompt
                answer = "These are synthetic demonstration papers [1]. This response tests the connection; it is not model-generated research."
                print("PASS fixture received answer payload", flush=True)
            result = json.dumps({"model": "fixture-reported", "choices": [{"message": {"content": answer}}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(result)))
            self.end_headers()
            self.wfile.write(result)
        except (ValueError, KeyError, AssertionError, IndexError):
            self.send_error(400, "Unexpected fixture request")

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 0), Handler)
    print(f"http://127.0.0.1:{server.server_port}/v1/chat/completions", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
