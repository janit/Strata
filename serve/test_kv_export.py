"""serve/test_kv_export.py - kv-export: POST /slots/session?action=save (SAVEC) and POST /slots/0?action=import (IMPORT),
solo and with parallel requests (mock engine: no GPU, no pack).

    python -m unittest serve.test_kv_export -v
"""
from __future__ import annotations

import json
import queue
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from serve.frontend import ChatTemplate  # noqa: E402
from serve import server  # noqa: E402
from serve.server import (KV_SESSIONS_KEPT, ByteTokenizer, Service, StrataEngine, fnv1a64_ids,  # noqa: E402
                          kv_session_id, serve)

ROOT = Path(__file__).resolve().parents[1]


class FakeProc:
    """Answers SAVEC / IMPORT / SAVE / RESTORE lines like `strata --serve` does."""

    def __init__(self, engine):
        self.engine = engine
        self.stdin = self
        self.sent: list[str] = []

    def write(self, s):
        self.sent.append(s.strip())
        cmd, _, rest = s.strip().partition(" ")
        e = self.engine
        if e.during:                                # what the server allows while the engine works on this line
            e.during()
        if e.refuse:
            e.lines.put(f"SERR {e.refuse_kind} 0 {e.refuse}\n")
        elif cmd == "SAVEX":
            slot, n, h, base, path = rest.split(" ", 4)
            Path(path).write_bytes(b"s" * 100)
            # the engine knows base 00000000000000aa only: a delta against it, else a full save
            e.lines.put(f"SAVEDX {n} 100 12.5 {e.next_id} {base if base == '00000000000000aa' else '0' * 16}\n")
        elif cmd == "HELD":
            n, h = rest.split(" ")
            e.lines.put(f"HELD {e.held.get((int(n), h), 0)}\n")
        elif cmd == "IMPORT":
            e.lines.put("IMPORTED 50000 1000 1500.0\n")
        elif cmd == "SAVE":
            Path(rest).write_bytes(b"x" * 10)
            e.lines.put("SAVED 7 10 1.0\n")

    def flush(self):
        pass

    def poll(self):
        return None


class FakeEngine(StrataEngine):
    def __init__(self):
        super().__init__("strata", ["--max-context", "65536"], lazy=True)
        self.max_context = 65536
        self.ended = False
        self.lines = queue.Queue()
        self.refuse = None
        self.refuse_kind = "invalid"
        self.during = None
        self.next_id = "00000000000000bb"
        self.held = {}                              # HELD: (n, hash hex) -> tokens the engine says it holds
        self.silence_s = 30.0
        self.proc = FakeProc(self)
        self.solo()

    def solo(self):
        self.batch = 0

    def parallel(self, n):
        """The admission state start() makes for --batch n."""
        self.batch = n
        self.slot_busy = [False] * n
        self.slot_held = [[] for _ in range(n)]
        self.slot_cv = threading.Condition()
        self.waiting = 0
        self.admitting = 0
        self.wait_lens = []
        self.ctl_epoch = 0
        self.ctl = threading.Lock()
        self.wlock = threading.Lock()


class Helpers(unittest.TestCase):
    def test_session_header_order_is_viiworks(self):
        # viiwork's sessionKey (internal/proxy) routes by X-Session-Affinity first
        self.assertEqual(kv_session_id({"X-Session-Affinity": "a", "X-Session-Id": "b"}), "a")
        self.assertEqual(kv_session_id({"X-Session-Id": "b"}), "b")
        # viiwork takes the first non-empty header as it stands, so a blank affinity hides the id there too
        self.assertIsNone(kv_session_id({"X-Session-Affinity": " ", "X-Session-Id": "b"}))
        self.assertEqual(kv_session_id({"X-Session-Affinity": "", "X-Session-Id": "b"}), "b")
        self.assertIsNone(kv_session_id({}))
        self.assertIsNone(kv_session_id({"X-Session-Id": "has space"}))
        self.assertIsNone(kv_session_id({"X-Session-Id": "ünï"}))
        # at most 256 bytes, never cut short (two long ids that start alike would share one remembered prompt)
        self.assertEqual(len(kv_session_id({"X-Session-Id": "x" * 256})), 256)
        self.assertIsNone(kv_session_id({"X-Session-Id": "x" * 257}))

    def test_ids_hash_matches_the_engine(self):
        # the same vector is pinned in src/core/conversation_file_test.cpp (session_ids_fnv1a64)
        self.assertEqual(fnv1a64_ids([0, 1, -1, 151643]), 0x2401b33d3e943579)
        self.assertEqual(fnv1a64_ids([]), 0xcbf29ce484222325)


class KvExport(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.TemporaryDirectory()
        cls.engine = FakeEngine()
        cls.svc = Service(cls.engine, ByteTokenizer(), ChatTemplate(ROOT / "serve/chat_template.jinja"))
        cls.svc.slot_save_path = cls.dir.name
        cls.httpd = serve(cls.svc, port=0)
        cls.base = f"http://127.0.0.1:{cls.httpd.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        cls.dir.cleanup()

    def setUp(self):
        self.engine.solo()
        self.engine.refuse = None
        self.engine.refuse_kind = "invalid"
        self.engine.during = None
        self.engine.proc = FakeProc(self.engine)
        self.svc.__dict__.pop("kv_sessions", None)
        self.svc.__dict__.pop("kv_sessions_bytes", None)

    def post(self, path, body):
        req = urllib.request.Request(self.base + path, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            with e:
                return e.code, json.loads(e.read())

    def save(self, session="s1", filename="s1.bin"):
        return self.post("/slots/session?action=save", {"session": session, "filename": filename})

    def test_sessions_kept_are_the_most_recent(self):
        for i in range(KV_SESSIONS_KEPT + 5):
            self.svc.kv_note(f"s{i}", [i])
        self.svc.kv_note("s10", [10, 11])               # used again: moves to the newest end
        self.svc.kv_note(None, [1])                     # no session: nothing kept
        kept = self.svc.kv_sessions
        self.assertEqual(len(kept), KV_SESSIONS_KEPT)
        self.assertNotIn("s0", kept)
        self.assertEqual(list(kept["s10"]), [10, 11])
        self.assertEqual(next(reversed(kept)), "s10")
        self.assertEqual(self.svc.kv_sessions_bytes, sum(4 * len(v) for v in kept.values()))

    def test_no_session_is_kept_without_a_slot_save_path(self):
        self.svc.slot_save_path = None
        try:
            self.svc.kv_note("s1", [1, 2, 3])
            for path in ("/slots/session?action=save", "/slots/session?action=held", "/slots/0?action=import"):
                code, _ = self.post(path, {"session": "s1", "filename": "s1.bin"})
                self.assertEqual(code, 501, path)
        finally:
            self.svc.slot_save_path = self.dir.name
        self.assertNotIn("kv_sessions", self.svc.__dict__)

    def test_sessions_kept_fit_their_byte_budget(self):
        old = server.KV_SESSIONS_BYTES
        server.KV_SESSIONS_BYTES = 4 * 1000             # 1000 tokens
        try:
            for i in range(5):
                self.svc.kv_note(f"s{i}", range(300))   # 1200 bytes each: three fit
            self.assertEqual(list(self.svc.kv_sessions), ["s2", "s3", "s4"])
            self.svc.kv_note("s3", range(100))          # the same session again, shorter: counted once
            self.assertEqual(self.svc.kv_sessions_bytes, 4 * 700)
            self.svc.kv_note("big", range(5000))        # alone over the budget: kept, everything else goes
            self.assertEqual(list(self.svc.kv_sessions), ["big"])
            self.assertEqual(self.svc.kv_sessions_bytes, 4 * 5000)
        finally:
            server.KV_SESSIONS_BYTES = old

    def test_solo_save_names_the_conversation_by_its_prompt(self):
        self.svc.kv_note("s1", [5, 6, 7])
        code, body = self.save()
        self.assertEqual(code, 200, body)
        self.assertEqual(body["id_slot"], -1)
        self.assertEqual(body["n_saved"], 3)
        path = str(Path(self.dir.name) / "s1.bin")
        self.assertEqual(self.engine.proc.sent, [f"SAVEX -1 3 {fnv1a64_ids([5, 6, 7]):016x} {0:016x} {path}"])
        self.assertEqual((body["save_id"], body["base"], body["delta"]), ("00000000000000bb", None, False))

    def test_save_against_a_base(self):
        self.svc.kv_note("s1", [5, 6, 7])
        code, body = self.post("/slots/session?action=save", {"session": "s1", "filename": "d.bin",
                                                              "base": "00000000000000aa"})
        self.assertEqual(code, 200, body)
        self.assertEqual((body["save_id"], body["base"], body["delta"]), ("00000000000000bb", "00000000000000aa", True))
        self.assertIn(" 00000000000000aa ", self.engine.proc.sent[0])
        code, body = self.post("/slots/session?action=save", {"session": "s1", "filename": "d.bin",
                                                              "base": "00000000000000cc"})
        self.assertEqual((code, body["base"], body["delta"]), (200, None, False))   # unknown base: a full save
        for bad in ("AA", "00000000000000AA", 5, "0x00000000000000"):
            code, _ = self.post("/slots/session?action=save", {"session": "s1", "filename": "d.bin", "base": bad})
            self.assertEqual(code, 400, bad)

    def test_an_answer_out_of_step_ends_the_engine(self):
        self.svc.kv_note("s1", [1])
        orig = FakeProc.write
        def bad(proc, s):
            proc.sent.append(s.strip())
            proc.engine.lines.put("SAVEDX 1 100 12.5 nothex!!nothex!! 0000000000000000\n")
        FakeProc.write = bad
        try:
            code, _ = self.save()
        finally:
            FakeProc.write = orig
        self.assertEqual(code, 500)
        self.assertTrue(self.engine.ended)
        self.engine.ended = False

    def test_unknown_session_is_404_and_reaches_no_engine(self):
        code, _ = self.save("nobody")
        self.assertEqual(code, 404)
        code, _ = self.post("/slots/session?action=save", {"session": 7, "filename": "x.bin"})
        self.assertEqual(code, 404)
        self.assertEqual(self.engine.proc.sent, [])

    def test_a_conversation_no_longer_held_is_409(self):
        self.svc.kv_note("s1", [1])
        self.engine.refuse = "that conversation is no longer held there"
        code, body = self.save()
        self.assertEqual(code, 409, body)
        self.engine.refuse = "the batch slot is decoding"
        self.assertEqual(self.save()[0], 409)

    def test_state_refusals_are_409_and_others_keep_their_status(self):
        # a well-formed save is refused ("invalid") only for the state of that conversation
        self.svc.kv_note("s1", [1])
        for why in ("no complete session to save", "the batch slot's conversation has pictures"):
            self.engine.refuse = why
            code, body = self.save()
            self.assertEqual(code, 409, why)
            self.assertEqual(body["error"]["kind"], "invalid")
        self.engine.refuse, self.engine.refuse_kind = "no space left on device", "storage"
        code, body = self.save()
        self.assertEqual(code, 507)
        self.assertEqual(body["error"]["kind"], "storage")

    def test_an_unload_waits_for_a_save_or_an_import(self):
        # parallel requests do not hold the FIFO, but unload() takes it: a save or an import must hold it too, or an
        # idle unload could end the engine in the middle of one
        Path(self.dir.name, "in.bin").write_bytes(b"f")
        for parallel in (0, 2):
            if parallel:
                self.engine.parallel(parallel)
            seen = []
            self.engine.during = lambda: seen.append(self.svc.unload())
            self.svc.kv_note("s1", [1, 2, 3])
            self.assertEqual(self.save()[0], 200)
            self.assertEqual(self.post("/slots/0?action=import", {"filename": "in.bin"})[0], 200)
            self.assertEqual(seen, ["busy", "busy"], parallel)
            with self.svc.status_lock:
                self.assertEqual(self.svc.status["queued"], 0)
                self.assertFalse(self.svc.status.get("busy"))
            self.assertFalse(self.svc.fifo.locked())

    def test_a_save_or_an_import_counts_as_activity_for_the_idle_unload(self):
        Path(self.dir.name, "in.bin").write_bytes(b"f")
        self.engine.parallel(2)
        self.svc.kv_note("s1", [1])
        for call in (lambda: self.save(), lambda: self.post("/slots/0?action=import", {"filename": "in.bin"})):
            self.svc.last_request_at = 0.0
            self.assertEqual(call()[0], 200)
            self.assertGreater(self.svc.last_request_at, 0.0)

    def test_session_save_reclaim_retries_a_save_by_session(self):
        # --session-save-reclaim: an unpublished RAM refusal is tried again, with the same SAVEX line
        from unittest import mock
        self.svc.kv_note("s1", [1, 2])
        tries = []

        def during():
            tries.append(1)
            if len(tries) == 1:
                self.engine.refuse, self.engine.refuse_kind = ("not enough RAM to save the session (10 MiB plus a "
                                                               "floor of 10 MiB needed, 5 available)"), "memory"
            else:
                self.engine.refuse = None
        self.engine.during = during
        self.engine.session_save_reclaim = True
        try:
            with mock.patch("serve.session_save_retry.available_mib", return_value=1 << 20), \
                    mock.patch("serve.session_save_retry.POLL_SECONDS", 0.01):
                code, body = self.save()
        finally:
            del self.engine.session_save_reclaim
        self.assertEqual(code, 200, body)
        self.assertEqual(len(tries), 2)
        self.assertEqual(len(set(self.engine.proc.sent)), 1)
        self.assertTrue(self.engine.proc.sent[0].startswith("SAVEX -1 2 "))

    def test_session_endpoint_only_saves_and_checks_the_name(self):
        self.svc.kv_note("s1", [1])
        self.assertEqual(self.post("/slots/session?action=restore", {"session": "s1", "filename": "a.bin"})[0], 400)
        for bad in ("../x.bin", "a/b.bin", "", None):
            self.assertEqual(self.save(filename=bad)[0], 400, bad)
        self.assertEqual(self.engine.proc.sent, [])

    def held(self, session="s1"):
        return self.post("/slots/session?action=held", {"session": session})

    def test_held_asks_the_engine_by_the_sessions_last_prompt(self):
        self.svc.kv_note("s1", [5, 6, 7])
        h = f"{fnv1a64_ids([5, 6, 7]):016x}"
        self.engine.held[(3, h)] = 50000
        code, body = self.held()
        self.assertEqual(code, 200, body)
        self.assertEqual(body, {"session": "s1", "n_held": 50000})
        self.assertEqual(self.engine.proc.sent, [f"HELD 3 {h}"])
        self.engine.held.clear()                        # evicted
        self.assertEqual(self.held()[1]["n_held"], 0)
        self.assertFalse(self.svc.status["busy"], "a check is not work")

    def test_held_of_a_session_never_seen_is_0_and_reaches_no_engine(self):
        self.assertEqual(self.held("nobody"), (200, {"session": "nobody", "n_held": 0}))
        self.assertEqual(self.held(7)[1]["n_held"], 0)
        self.assertEqual(self.engine.proc.sent, [])

    def test_held_with_parallel_requests_takes_and_gives_back_the_lines(self):
        e = self.engine
        e.parallel(2)
        self.svc.kv_note("s1", [1, 2])
        e.held[(2, f"{fnv1a64_ids([1, 2]):016x}")] = 9
        self.assertEqual(self.held(), (200, {"session": "s1", "n_held": 9}))
        self.assertFalse(e.ctl.locked(), "the control lines are given back")

    def test_held_answer_out_of_step_ends_the_engine(self):
        self.svc.kv_note("s1", [1])
        self.engine.proc.write = lambda s: self.engine.lines.put("HELD x\n")
        code, _ = self.held()
        self.assertEqual(code, 500)
        self.assertTrue(self.engine.ended)
        self.engine.ended = False

    def test_parallel_save_takes_the_idle_slot_holding_the_conversation(self):
        e = self.engine
        e.parallel(3)
        ids = [1, 2, 3]
        e.slot_held[0] = [9, 9, 9, 9]                   # another conversation
        e.slot_held[1] = ids + [4, 5]                   # this one, with its reply
        e.slot_held[2] = ids + [4, 5, 6, 7]             # this one, longer - but decoding
        e.slot_busy[2] = True
        self.svc.kv_note("s1", ids)
        code, body = self.save()
        self.assertEqual(code, 200, body)
        self.assertEqual(body["id_slot"], 1)
        self.assertTrue(e.proc.sent[0].startswith(f"SAVEX 1 3 {fnv1a64_ids(ids):016x} {0:016x} "))
        self.assertFalse(e.ctl.locked(), "the control lines are given back")
        self.assertEqual(e.ctl_epoch, 1)

    def test_parallel_save_falls_back_to_the_live_session(self):
        e = self.engine
        e.parallel(2)
        e.slot_held[0] = [7, 7]
        self.svc.kv_note("s1", [1, 2])
        code, body = self.save()
        self.assertEqual(code, 200, body)
        self.assertEqual(body["id_slot"], -1)

    def test_parallel_save_releases_the_lines_on_a_refusal(self):
        e = self.engine
        e.parallel(2)
        self.svc.kv_note("s1", [1])
        e.refuse = "that conversation is no longer held there"
        self.assertEqual(self.save()[0], 409)
        self.assertFalse(e.ctl.locked())

    def test_import_parks_solo_and_with_parallel_requests(self):
        Path(self.dir.name, "in.bin").write_bytes(b"f")
        path = str(Path(self.dir.name) / "in.bin")
        for parallel in (0, 2):
            self.engine.proc = FakeProc(self.engine)
            if parallel:
                self.engine.parallel(parallel)
            code, body = self.post("/slots/0?action=import", {"filename": "in.bin"})
            self.assertEqual(code, 200, (parallel, body))
            self.assertEqual(body["n_imported"], 50000)
            self.assertEqual(self.engine.proc.sent, [f"IMPORT {path}"])
        self.assertFalse(self.engine.ctl.locked())

    def test_import_of_a_missing_file_is_404_and_reaches_no_engine(self):
        for parallel in (0, 2):
            if parallel:
                self.engine.parallel(parallel)
            code, _ = self.post("/slots/0?action=import", {"filename": "nothing.bin"})
            self.assertEqual(code, 404)
        self.assertEqual(self.engine.proc.sent, [])

    def test_import_refused_by_the_engine_keeps_its_kind(self):
        Path(self.dir.name, "in.bin").write_bytes(b"f")
        self.engine.parallel(2)
        self.engine.refuse = "session file: saved with another model (model fingerprint differs)"
        code, body = self.post("/slots/0?action=import", {"filename": "in.bin"})
        self.assertEqual(code, 400)
        self.assertEqual(body["error"]["kind"], "invalid")
        self.assertFalse(self.engine.ctl.locked())

    def test_save_and_restore_stay_refused_with_parallel_requests(self):
        self.engine.parallel(2)
        Path(self.dir.name, "in.bin").write_bytes(b"f")
        for action in ("save", "restore"):
            code, _ = self.post(f"/slots/0?action={action}", {"filename": "in.bin"})
            self.assertEqual(code, 501, action)
        self.assertEqual(self.engine.proc.sent, [])


if __name__ == "__main__":
    unittest.main()
