"""Fake ElevenLabs /stream/with-timestamps server for Fast Narrate's --selftest-stream.
Each word gets 0.25s; audio is silence, sent as 3 chunks of 0.5s with chunk-relative timings."""
import base64, json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

RATE = 24000

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        text = body["text"]
        words = text.split(" ")
        # absolute start time of every character: word k starts at k*0.25s
        starts, t = [], 0.0
        for k, w in enumerate(words):
            for i, _ in enumerate(w + (" " if k < len(words) - 1 else "")):
                starts.append(k * 0.25 + i * 0.25 / (len(w) + 1))
        total = len(words) * 0.25
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        chunk = 0.5
        n = int(total / chunk + 0.999)
        for c in range(n):
            lo, hi = c * chunk, min((c + 1) * chunk, total)
            idx = [i for i, s in enumerate(starts) if lo <= s < hi]
            obj = {
                "audio_base64": base64.b64encode(b"\x00\x00" * int((hi - lo) * RATE)).decode(),
                "alignment": {
                    "characters": [text[i] for i in idx],
                    "character_start_times_seconds": [round(starts[i] - lo, 4) for i in idx],
                    "character_end_times_seconds": [round(starts[i] - lo + 0.05, 4) for i in idx],
                },
            }
            self.wfile.write((json.dumps(obj) + "\n").encode())
            self.wfile.flush()

srv = HTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8765), H)
srv.serve_forever()
