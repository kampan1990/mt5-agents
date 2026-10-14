import json
import threading
import urllib.request

import pytest

from bot.dashboard_server import make_server, read_events


@pytest.fixture
def served(tmp_path):
    journal = tmp_path / "trades.jsonl"
    server = make_server(str(journal), "127.0.0.1", 0)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield journal, f"http://127.0.0.1:{server.server_port}"
    server.shutdown()
    server.server_close()


def get(url):
    with urllib.request.urlopen(url, timeout=5) as r:
        return r.status, r.headers, r.read().decode()


def test_page_is_served_as_a_full_document(served):
    _, base = served
    status, headers, body = get(base + "/")
    assert status == 200 and headers["Content-Type"].startswith("text/html")
    assert body.startswith("<!doctype html>") and "<title>Claude Futures Bot</title>" in body
    assert "/api/events" in body


def test_events_incremental_and_tolerates_partial_line(served):
    journal, base = served
    assert json.loads(get(base + "/api/events")[2]) == {"events": [], "next": 0}      # no log yet
    journal.write_text('{"ts":"2025-01-01T00:00:00+00:00","event":"start"}\n'
                       '{"ts":"2025-01-01T01:00:00+00:00","event":"equity","equity":1}\n'
                       '{"ts":"2025-01-01T02:00:00+00:00","event":"eq')                  # half-written last line
    first = json.loads(get(base + "/api/events?after=0")[2])
    assert [e["event"] for e in first["events"]] == ["start", "equity"] and first["next"] == 2
    with journal.open("a") as f:
        f.write('uity","equity":2}\n')                                                    # the line is completed
    second = json.loads(get(base + f"/api/events?after={first['next']}")[2])
    assert [e["equity"] for e in second["events"]] == [2] and second["next"] == 3


def test_bad_params_and_unknown_paths(served):
    _, base = served
    assert json.loads(get(base + "/api/events?after=abc")[2])["next"] == 0
    with pytest.raises(urllib.error.HTTPError) as e:
        get(base + "/etc/passwd")
    assert e.value.code == 404


def test_server_binds_localhost_by_default():
    import inspect
    assert inspect.signature(make_server).parameters["host"].default == "127.0.0.1"
    assert read_events.__module__ == "bot.dashboard_server"
