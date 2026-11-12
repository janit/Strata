"""kv-export: a conversation's KV state moved between Strata processes - the Python half.

Everything the server adds for kv-export lives here; serve/server.py keeps only the hooks (KV-EXPORT.md has the whole
API and the formats, which are a contract: the engine's lines, the HTTP answers and the files do not change).

    the session memory       KV_SESSION (the client session of the request a thread serves), kv_session_id(), and
                             KvExport.kv_note(): each session's last prompt, packed, for a save by session
    the engine's lines       session_command() / session_answer(): SAVEC, SAVEX, IMPORT and HELD and their answers,
                             for StrataEngine.session_file (its third argument, `conv`)
    the endpoints            KvExport: POST /slots/session?action=save|held and POST /slots/0?action=import, mixed
                             into server.Service

This module imports nothing from serve.server: server.py imports it.  The two names of server.py the endpoints need,
SessionRefused and slot_filename_problem, are class attributes of server.Service (kv_refused, kv_filename_problem), not
globals here: server.py usually runs as __main__ (python -m serve.server), and upstream modules import serve.server
lazily while serving (serve/replicas.py, serve/split.py), which loads a second copy of server.py.  Each copy's Service
keeps its own SessionRefused - the one its engine raises - where a global here would hold whichever copy came last.

The session memory's limits, KV_SESSIONS_KEPT and KV_SESSIONS_BYTES, are read here: set them on serve.kv_export (a
name re-exported by server.py is a copy, and setting it there changes nothing).
"""
from __future__ import annotations

import array
import collections
import math
import os
import sys
import threading
import time

# kv-export: the client session of the request this thread serves (X-Session-Id / X-Session-Affinity), so the
# conversation it ends in can be saved by name afterwards (POST /slots/session?action=save)
KV_SESSION = threading.local()
KV_SESSIONS_KEPT = 1024
KV_SESSIONS_BYTES = 64 << 20    # their prompts, packed int32: 64 MiB is ~16M tokens (~320 conversations of 50k)


def kv_session_id(headers) -> str | None:
    # the order viiwork routes by (internal/proxy sessionKey): X-Session-Affinity, then X-Session-Id
    # (the first non-empty one as it stands, like viiwork; one with spaces or controls names no session)
    sid = headers.get("X-Session-Affinity") or headers.get("X-Session-Id") or ""
    # a longer id is no session (never cut short: two ids that start alike would share one remembered prompt)
    return sid if sid and len(sid) <= 256 and all(32 < ord(c) < 127 for c in sid) else None


def fnv1a64_ids(ids) -> int:
    """kv-export: FNV-1a 64 over the token ids as little-endian int32, as the engine's SAVEC computes it."""
    data = (ids if isinstance(ids, array.array) and ids.typecode == "i" else array.array("i", ids)).tobytes()
    if sys.byteorder != "little":
        a = array.array("i", data)
        a.byteswap()
        data = a.tobytes()
    h = 0xcbf29ce484222325
    for b in data:
        h = ((h ^ b) * 0x100000001b3) & 0xffffffffffffffff
    return h


# the answers session_answer() reads; SAVED, RESTORED and IMPORTED are the engine's plain session answers
SESSION_ANSWERS = ("HELD", "SAVEDX")


def session_command(action: str, path: str, conv: tuple | None = None) -> tuple[str, str]:
    """StrataEngine.session_file's line to the engine and the answer it waits for: (command line, answer head).
    SAVE / RESTORE as upstream, and kv-export's IMPORT, SAVEC, SAVEX and HELD.  ValueError("invalid session command")
    for anything else, before a line is written."""
    if action not in ("save", "restore", "import", "held") or any(c in path for c in "\r\n\0"):
        raise ValueError("invalid session command")
    if conv is not None and action not in ("save", "held") or action == "held" and (conv is None or len(conv) != 2):
        raise ValueError("invalid session command")
    # kv-export: `conv` = (where, n, hash): SAVEC saves the conversation whose first n ids hash to `hash`
    # (fnv1a64_ids) from batch slot `where` (or the live session, -1, else a parked one), and the engine refuses
    # if it is no longer held there
    # (where, n, hash, base): SAVEX - the same, remembered by the engine, and a delta file against the earlier
    # SAVEX `base` (0: none) when it can; the answer adds "save_id" and "base" (None: a full session file)
    # (n, hash) with "held": HELD - the length of the longest conversation the engine still holds (live, a batch
    # slot or parked) whose first n ids hash to `hash`, 0 for none; read only, `path` unused
    if action == "held":
        cmd = f"HELD {int(conv[0])} {int(conv[1]):016x}\n"
    elif conv is None:
        cmd = f"{action.upper()} {path}\n"
    elif len(conv) == 4:
        cmd = f"SAVEX {int(conv[0])} {int(conv[1])} {int(conv[2]):016x} {int(conv[3]):016x} {path}\n"
    else:
        cmd = f"SAVEC {int(conv[0])} {int(conv[1])} {int(conv[2]):016x} {path}\n"
    want = {"save": "SAVED", "restore": "RESTORED", "import": "IMPORTED", "held": "HELD"}[action]
    if conv is not None and len(conv) == 4:
        want = "SAVEDX"
    return cmd, want


def session_answer(want: str, f: list, count) -> dict:
    """The answer `want` (one of SESSION_ANSWERS), split into fields `f`: HELD <n> -> {"tokens"}; SAVEDX <tokens> <bytes>
    <ms> <save_id> <base> -> {"tokens", "bytes", "ms", "save_id", "base"} (base None: a full session file).  `count` is
    session_file's strict digit reader.  ValueError when malformed: the caller ends the engine (out of step)."""
    if want == "HELD":
        if len(f) != 2:
            raise ValueError
        return {"tokens": count(f[1])}
    if len(f) != 6:
        raise ValueError
    tokens, size, ms = count(f[1]), count(f[2]), float(f[3])
    if not math.isfinite(ms) or ms < 0:
        raise ValueError
    out = {"tokens": tokens, "bytes": size, "ms": ms}
    if not all(len(x) == 16 and all(c in "0123456789abcdef" for c in x) for x in f[4:6]):
        raise ValueError
    out["save_id"], out["base"] = f[4], (f[5] if int(f[5], 16) else None)
    return out


class _NotBound(Exception):
    """KvExport.kv_refused until the class it is mixed into sets its own: never raised."""


class KvExport:
    """kv-export's endpoints, mixed into server.Service (they use its engine, FIFO, status and slot_save_path).
    Service.slot_action dispatches to them: /slots/session to session_save (and session_held), action=import on slot
    0 to session_import; Service.stream() calls kv_note() with each request's session and prompt.

    Service sets kv_refused (server.py's SessionRefused, which its engine raises) and kv_filename_problem (its
    slot_filename_problem, as a staticmethod) - per copy of server.py, see the module docstring."""

    kv_refused: type = _NotBound        # server.Service: SessionRefused
    kv_filename_problem = None          # server.Service: staticmethod(slot_filename_problem)

    def session_save(self, action, filename, session, error, base=None, conv=None) -> tuple[int, dict]:
        """kv-export: POST /slots/session?action=save {"session": ID, "filename": NAME} saves the conversation the
        client session ID last continued (its requests carried X-Session-Id or X-Session-Affinity), wherever it is now:
        the batch slot that holds it, else the live session, else (the engine looks) the conversation cache, where a
        later request of another session parked it.  With parallel requests it takes the control lines like
        an admission.  409 when that conversation is no longer held (another took its slot)."""
        if action == "held":
            return self.session_held(session, error, conv)
        if action != "save":
            return error(400, "/slots/session supports action=save and action=held")
        why = self.kv_filename_problem(filename)
        if why:
            return error(400, f"filename {why}")
        with self.status_lock:
            ids = (self.__dict__.get("kv_sessions") or {}).get(session) if isinstance(session, str) else None
        if not ids:
            return error(404, "no request of that session on this server")
        if base is not None and not (isinstance(base, str) and len(base) == 16 and
                                     all(c in "0123456789abcdef" for c in base)):
            return error(400, "base must be a save_id: 16 lowercase hex digits")
        base_id = int(base, 16) if base else 0
        path = os.path.join(self.slot_save_path, filename)
        name = fnv1a64_ids(ids)                         # ~36 ms per 50k tokens: before the control lines, not inside
        found = {"where": -1}

        def save(eng):
            if not getattr(eng, "batch", 0):
                conv = (-1, len(ids), name, base_id)
                if getattr(eng, "session_save_reclaim", False):
                    from serve.session_save_retry import session_file
                    return session_file(self, "save", path, self.kv_refused, conv=conv)
                return eng.session_file("save", path, conv)
            with eng.slot_cv:                               # the idle slot holding the longest start with these ids
                held = 0
                for b in range(eng.batch):
                    h = eng.slot_held[b]
                    if (not eng.slot_busy[b] and len(h) >= len(ids) and len(h) > held and
                            array.array("i", h[:len(ids)]) == ids):
                        found["where"], held = b, len(h)
            return self.with_control(lambda: eng.session_file("save", path, (found["where"], len(ids), name, base_id)))
        try:
            r = self.session_op("save", save)
        except self.kv_refused as e:
            # the engine refuses a well-formed SAVEC/SAVEX ("invalid") only for the state of that conversation: no
            # longer held, decoding, partial, pictures - a conflict with what the engine holds now, not a bad request
            body = error(409 if e.kind == "invalid" else e.status, str(e))
            body[1]["error"]["kind"] = e.kind
            return body
        except ValueError as e:
            return error(400, str(e))
        if r is None:
            return error(503, "the model is not loaded")
        where = found["where"]
        return 200, {"id_slot": where, "session": session, "filename": filename, "n_saved": r["tokens"],
                     "n_written": r["bytes"], "timings": {"save_ms": r["ms"]}, "save_id": r["save_id"],
                     "base": r["base"], "delta": r["base"] is not None}

    def session_held(self, session, error, conv=None) -> tuple[int, dict]:
        """kv-export: POST /slots/session?action=held {"session": ID} -> {"session", "n_held"}: how many tokens of
        the conversation client session ID last continued the engine still holds (live, in a batch slot or parked;
        the longest one that starts with that session's last prompt here), 0 when none or when this server never
        saw the session.  With {"n": N, "hash": "<16 hex>"} it asks for the conversation whose first N ids hash to
        that (fnv1a64_ids) instead - a replica's own ids, which the session's last prompt here may not start: after
        a compaction elsewhere this server's copy of the session is another branch.  Read only, so a node asks
        before each turn whether to import its replica: the conversation cache evicts oldest first and says
        nothing about which.  With parallel requests it takes the control lines between two admissions, as a
        save does."""
        n, h = conv if conv else (None, None)
        if n is not None or h is not None:
            if (isinstance(n, bool) or not isinstance(n, int) or n <= 0 or not isinstance(h, str) or len(h) != 16 or
                    not all(c in "0123456789abcdef" for c in h)):
                return error(400, "n must be a positive token count and hash 16 lowercase hex digits")
            conv = (n, int(h, 16))
        else:
            with self.status_lock:
                ids = (self.__dict__.get("kv_sessions") or {}).get(session) if isinstance(session, str) else None
            if not ids:
                return 200, {"session": session, "n_held": 0}
            conv = (len(ids), fnv1a64_ids(ids))

        def held(eng):
            if not getattr(eng, "batch", 0):
                return eng.session_file("held", "", conv)
            return self.with_control(lambda: eng.session_file("held", "", conv))
        try:
            r = self.session_op("held", held)
        except self.kv_refused as e:
            body = error(e.status, str(e))
            body[1]["error"]["kind"] = e.kind
            return body
        if r is None:
            return error(503, "the model is not loaded")
        return 200, {"session": session, "n_held": r["tokens"]}

    def kv_note(self, sid, ids) -> None:
        """kv-export: the conversation client session `sid` continues starts with these ids (the last
        KV_SESSIONS_KEPT sessions, at most KV_SESSIONS_BYTES of ids), for POST /slots/session?action=save."""
        if not sid:
            return
        packed = array.array("i", ids)              # 4 bytes a token (a list of ints is ~36)
        with self.status_lock:
            kept = self.__dict__.setdefault("kv_sessions", collections.OrderedDict())
            old = kept.pop(sid, None)
            self.kv_sessions_bytes = self.__dict__.get("kv_sessions_bytes", 0) + packed.itemsize * len(packed) - \
                (old.itemsize * len(old) if old is not None else 0)
            kept[sid] = packed
            # the oldest sessions go first; the newest stays even when it alone is over the budget
            while len(kept) > 1 and (len(kept) > KV_SESSIONS_KEPT or self.kv_sessions_bytes > KV_SESSIONS_BYTES):
                _, gone = kept.popitem(last=False)
                self.kv_sessions_bytes -= gone.itemsize * len(gone)

    def session_op(self, action, fn):
        """kv-export: fn(engine) for a save by session or an import, with the bookkeeping slot_action keeps: counted
        as queued while it waits, under the FIFO (so an unload, idle or asked for, waits for it: parallel requests do
        not hold the FIFO, but unload() takes it), the engine checked as loaded once the FIFO is held, and the idle
        timer told before and after.  None when the model is not loaded."""
        self.last_request_at = time.time()
        with self.status_lock:
            self.status["queued"] += 1
        waiting = True
        try:
            with self.fifo:
                with self.status_lock:
                    self.status["queued"] -= 1
                waiting = False
                if not self.loaded():
                    return None
                # with parallel requests "busy" is theirs to set; a held check is a lookup, not work
                solo = not getattr(self.engine, "batch", 0) and action != "held"
                if solo:
                    with self.status_lock:
                        self.status.update(busy=True, phase={"save": "saving the session",
                                           "import": "importing a session",
                                           "held": "checking a session"}[action], started=time.time(),
                                           first_token=None, prompt_tokens=None, generated=None, max_tokens=None)
                try:
                    return fn(self.engine)
                finally:
                    if solo:
                        with self.status_lock:
                            self.status["busy"] = False
                    self.last_request_at = time.time()
        finally:
            if waiting:
                with self.status_lock:
                    self.status["queued"] -= 1

    def with_control(self, fn):
        """kv-export: fn() while holding the engine's control lines, as an admission does (parallel requests only):
        a session command between two admissions, never inside one.  The slots keep decoding meanwhile."""
        eng = self.engine
        for _ in eng._take_control(threading.Event(), 0):  # heartbeats while an admission holds the lines
            pass
        eng._ctl_held = True                    # session_file() below must not wait for the lines this call holds
        try:
            return fn()
        finally:
            eng._ctl_held = False
            eng.ctl.release()
            with eng.slot_cv:
                eng.slot_cv.notify_all()

    def session_import(self, filename, error) -> tuple[int, dict]:
        """kv-export: POST /slots/0?action=import {"filename": NAME}: the engine parks the file in its conversation
        cache (it never touches the live session or a slot).  With parallel requests it only needs the control lines,
        not the FIFO; without, it is a session command under the FIFO like a restore (slot_action's own path for save
        and restore: the same checks, the same phase, the same answers - "published" too, as there)."""
        why = self.kv_filename_problem(filename)
        if why:
            return error(400, f"filename {why}")
        path = os.path.join(self.slot_save_path, filename)
        try:
            os.lstat(path)                                  # the engine opens it without following a link
        except OSError:
            return error(404, f"no saved session named {filename}")
        batch = getattr(self.engine, "batch", 0)
        try:
            if batch:
                r = self.session_op("import", lambda eng: self.with_control(lambda: eng.session_file("import", path)))
            else:
                r = self.session_op("import", lambda eng: eng.session_file("import", path))
        except self.kv_refused as e:
            body = error(e.status, str(e))
            body[1]["error"]["kind"] = e.kind
            if e.published and not batch:
                body[1]["error"]["published"] = True
            return body
        except ValueError as e:
            return error(400, str(e))
        if r is None:
            return error(503, "the model is not loaded")
        return 200, {"id_slot": 0, "filename": filename, "n_imported": r["tokens"], "n_read": r["bytes"],
                     "timings": {"import_ms": r["ms"]}}
