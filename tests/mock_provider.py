"""Deterministic local provider for integration tests and native app verification."""
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Provider(BaseHTTPRequestHandler):
    requests = []

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/v1/models":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"data": [
                {"id": "fritz-test", "name": "Fritz Test Model"},
                {"id": "slow-test", "name": "Slow Test Model"},
                {"id": "error-test", "name": "Error Test Model"},
                {"id": "disconnect-test", "name": "Disconnected Stream"},
            ]}).encode())
        else:
            self.send_error(404)

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        type(self).requests.append(payload)
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        if payload["model"] == "error-test":
            self.send_error(401)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        try:
            pieces = ["Hello ", "from Fritz.\n\n", "```rust\n", 'fn main() { println!("Hello, Fritz!"); }', "\n```\n\n", "A native chat foundation, ready for your next idea."]
            for text in pieces:
                if payload["model"] == "slow-test":
                    time.sleep(0.5)
                data = json.dumps({"choices": [{"delta": {"content": text}}]})
                self.wfile.write(f"data: {data}\r\n\r\n".encode())
                self.wfile.flush()
                time.sleep(0.025)
                if payload["model"] == "disconnect-test":
                    return
            self.wfile.write(b'data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"total_tokens":42}}\n\n')
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Provider)
    print(server.server_address[1], flush=True)
    server.serve_forever()
