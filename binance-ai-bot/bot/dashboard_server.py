"""Tiny read-only dashboard server (stdlib only).

  GET /                      the dashboard page
  GET /api/events?after=N    journal events with index >= N  ->  {"events": [...], "next": M}

It only reads logs/trades.jsonl. It has no authentication and no write endpoints, so it binds to
127.0.0.1 by default; expose it beyond localhost only behind your own auth (e.g. an SSH tunnel).
"""
from __future__ import annotations

import json
import logging
from functools import partial
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

log = logging.getLogger(__name__)
PAGE = Path(__file__).parent / "dashboard" / "index.html"
MAX_EVENTS_PER_REQUEST = 50_000

SHELL = ('<!doctype html><html lang="th"><head><meta charset="utf-8">'
         '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"></head><body>'
         "{body}</body></html>")


def read_events(journal_path: Path, after: int = 0) -> tuple[list[dict], int]:
    """Parse the JSONL journal; skip a half-written last line. Returns (events[after:], total_count)."""
    events: list[dict] = []
    try:
        with journal_path.open(encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    events.append(json.loads(line))
                except ValueError:
                    continue
    except FileNotFoundError:
        pass
    return events[after: after + MAX_EVENTS_PER_REQUEST], len(events)


class Handler(BaseHTTPRequestHandler):
    def __init__(self, journal_path: Path, *args, **kwargs):
        self.journal_path = journal_path
        super().__init__(*args, **kwargs)

    def _send(self, status: int, body: bytes, ctype: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        url = urlsplit(self.path)
        if url.path in ("/", "/index.html"):
            body = SHELL.format(body=PAGE.read_text(encoding="utf-8")).encode()
            self._send(200, body, "text/html; charset=utf-8")
        elif url.path == "/favicon.ico":
            self._send(204, b"", "image/x-icon")
        elif url.path == "/api/events":
            try:
                after = max(0, int(parse_qs(url.query).get("after", ["0"])[0]))
            except ValueError:
                after = 0
            events, total = read_events(self.journal_path, after)
            payload = {"events": events, "next": min(total, after + len(events))}
            self._send(200, json.dumps(payload).encode(), "application/json")
        else:
            self._send(404, b"not found", "text/plain")

    def log_message(self, fmt: str, *args) -> None:   # keep the bot's console readable
        log.debug("dashboard: " + fmt, *args)


def make_server(journal_path: str, host: str = "127.0.0.1", port: int = 8765) -> ThreadingHTTPServer:
    return ThreadingHTTPServer((host, port), partial(Handler, Path(journal_path)))
