#!/usr/bin/env python3
"""free-flow: a small local stdio MCP server for the Free Flow dictation app.

Reads dictation history, stats and the dictionary from the app's own data folder,
adds dictionary entries and transcribes files through the app's engine.

Protocol: newline-delimited JSON-RPC 2.0 on stdin/stdout. Logs go to stderr only.
Python 3.9+, standard library only.
"""

import datetime
import json
import os
import sqlite3
import subprocess
import sys
import time
import urllib.parse
import uuid
from pathlib import Path

SERVER_NAME = "free-flow"
SERVER_VERSION = "1.0.0"
PROTOCOL_VERSION = "2024-11-05"
BUNDLE_ID = "com.jaydenghiyam.FreeFlow"

HEARTBEAT_STALE_SEC = 15.0
APPLE_EPOCH = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)

WPM_NOTE = (
    "wpm is your average speaking speed while dictating. wpmTopPercent compares that speed "
    "against keyboard typing speeds: a value of 5 means you dictate faster than 95% of typists type."
)


# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

def log(*parts):
    print("[free-flow]", *parts, file=sys.stderr, flush=True)


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def pretty(value):
    return json.dumps(value, ensure_ascii=False, indent=2)


class ToolError(Exception):
    """Raised by a tool; returned to the client as an isError result."""


def base_dir():
    override = os.environ.get("FREE_FLOW_DATA", "").strip()
    if override:
        return Path(os.path.expanduser(override))
    return Path.home() / "Library" / "Application Support" / BUNDLE_ID


def mcp_dir():
    return base_dir() / "mcp"


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def parse_iso(value):
    """Parses ISO 8601 (with or without Z, fractions or time). Naive values are local time."""
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.endswith("Z") or text.endswith("z"):
        text = text[:-1] + "+00:00"
    # Python 3.9 fromisoformat only accepts 3 or 6 fractional digits.
    if "." in text:
        head, _, tail = text.partition(".")
        digits = ""
        rest = ""
        for i, ch in enumerate(tail):
            if ch.isdigit():
                digits += ch
            else:
                rest = tail[i:]
                break
        digits = (digits + "000000")[:6]
        text = head + "." + digits + rest
    try:
        parsed = datetime.datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.astimezone()  # interpret naive as local time
    return parsed


def write_json_atomic(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    # Hidden .tmp name: the app ignores hidden files and anything not ending in .json.
    tmp = path.parent / (".{}.{}.tmp".format(path.stem, uuid.uuid4().hex[:8]))
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)


def read_json_file(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as exc:
        log("could not read", path, exc)
        return None


# ---------------------------------------------------------------------------
# Argument helpers
# ---------------------------------------------------------------------------

def arg_int(args, name, default, low, high):
    value = args.get(name, default)
    if value is None:
        value = default
    if isinstance(value, bool):
        raise ToolError("'{}' must be an integer".format(name))
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    if isinstance(value, str) and value.strip().lstrip("-").isdigit():
        value = int(value.strip())
    if not isinstance(value, int):
        raise ToolError("'{}' must be an integer".format(name))
    if value < low or value > high:
        raise ToolError("'{}' must be between {} and {}".format(name, low, high))
    return value


def arg_bool(args, name, default):
    value = args.get(name, default)
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, str) and value.lower() in ("true", "false"):
        return value.lower() == "true"
    raise ToolError("'{}' must be true or false".format(name))


def arg_str(args, name, required=False):
    value = args.get(name)
    if value is None:
        if required:
            raise ToolError("'{}' is required".format(name))
        return None
    if not isinstance(value, str):
        raise ToolError("'{}' must be a string".format(name))
    return value


# ---------------------------------------------------------------------------
# History (SwiftData SQLite store, read-only)
# ---------------------------------------------------------------------------

COLUMN_KEYS = {
    "text": ["ZTEXT"],
    "enhanced": ["ZENHANCEDTEXT"],
    "timestamp": ["ZTIMESTAMP"],
    "duration": ["ZDURATION"],
    "status": ["ZTRANSCRIPTIONSTATUS"],
    "id": ["ZID"],
    "mode": ["ZMODENAME", "ZPOWERMODENAME"],
}


class HistoryStore:
    def __init__(self, path):
        self.path = path
        self.conn = None
        self.warning = None
        self.table = None
        self.cols = {}

    def _connect(self, immutable):
        uri = "file:" + urllib.parse.quote(str(self.path)) + "?mode=ro"
        if immutable:
            uri += "&immutable=1"
        conn = sqlite3.connect(uri, uri=True, timeout=2.0)
        conn.execute("PRAGMA busy_timeout = 2000")
        conn.execute("PRAGMA query_only = 1")
        return conn

    def open(self):
        """Opens read-only; on failure retries with immutable=1 (WAL side files unreadable)."""
        last_error = None
        for immutable in (False, True):
            conn = None
            try:
                conn = self._connect(immutable)
                tables = [row[0] for row in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type = 'table'")]
            except sqlite3.Error as exc:
                last_error = exc
                log("store open failed (immutable={}):".format(immutable), exc)
                if conn is not None:
                    conn.close()
                continue
            self.conn = conn
            if immutable:
                self.warning = ("Opened the history store in immutable mode because a normal read-only "
                                "open failed; results may be slightly stale.")
                log(self.warning)
            return tables
        raise ToolError("Could not open the history store at {}: {}".format(self.path, last_error))

    def discover(self):
        tables = self.open()
        table = next((t for t in tables if t.upper() == "ZTRANSCRIPTION"), None)
        if table is None:
            raise ToolError("The history store has no ZTRANSCRIPTION table. Tables found: {}".format(
                ", ".join(sorted(tables)) or "(none)"))
        self.table = table
        quoted = '"' + table.replace('"', '""') + '"'
        columns = [row[1] for row in self.conn.execute("PRAGMA table_info({})".format(quoted))]
        upper = {c.upper(): c for c in columns}
        for key, candidates in COLUMN_KEYS.items():
            for candidate in candidates:
                if candidate in upper:
                    self.cols[key] = upper[candidate]
                    break
        missing = [k for k in ("text", "timestamp") if k not in self.cols]
        if missing:
            raise ToolError(
                "Unexpected history store schema: missing {} in table {}. Columns found: {}".format(
                    ", ".join(COLUMN_KEYS[k][0] for k in missing), table, ", ".join(columns)))

    def q(self, key):
        return '"' + self.cols[key].replace('"', '""') + '"'

    def select_list(self):
        keys = ["text", "timestamp"] + [k for k in ("enhanced", "duration", "status", "id", "mode") if k in self.cols]
        return keys, ", ".join(self.q(k) for k in keys)

    def table_sql(self):
        return '"' + self.table.replace('"', '""') + '"'

    def close(self):
        if self.conn is not None:
            self.conn.close()


def render_uuid(value):
    if value is None:
        return None
    if isinstance(value, (bytes, bytearray, memoryview)):
        raw = bytes(value)
        if len(raw) == 16:
            return str(uuid.UUID(bytes=raw))
        return raw.hex()
    return str(value)


def apple_seconds_to_iso(value):
    if value is None:
        return None
    try:
        moment = APPLE_EPOCH + datetime.timedelta(seconds=float(value))
    except (TypeError, ValueError, OverflowError):
        return None
    return moment.astimezone().isoformat(timespec="seconds")


def iso_to_apple_seconds(value):
    parsed = parse_iso(value)
    if parsed is None:
        raise ToolError("'since' must be an ISO 8601 date such as 2026-10-01 or 2026-10-01T09:00:00")
    return (parsed - APPLE_EPOCH).total_seconds()


def row_to_item(keys, row, include_raw, matched_in=None):
    data = dict(zip(keys, row))
    raw = data.get("text") or ""
    enhanced = data.get("enhanced") or ""
    item = {
        "id": render_uuid(data.get("id")),
        "time": apple_seconds_to_iso(data.get("timestamp")),
        "durationSec": round(float(data["duration"]), 2) if data.get("duration") is not None else None,
        "status": data.get("status") or "completed",
        "text": enhanced if enhanced.strip() else raw,
    }
    if data.get("mode"):
        item["mode"] = data["mode"]
    if include_raw:
        item["raw"] = raw
    if matched_in:
        item["matchedIn"] = matched_in
    return item


def open_history():
    path = base_dir() / "default.store"
    if not path.exists():
        return None
    store = HistoryStore(path)
    try:
        store.discover()
    except Exception:
        store.close()
        raise
    return store


def tool_get_history(args):
    limit = arg_int(args, "limit", 20, 1, 200)
    since = arg_str(args, "since")
    include_raw = arg_bool(args, "include_raw", False)
    since_seconds = iso_to_apple_seconds(since) if since else None

    store = open_history()
    if store is None:
        return {"count": 0, "items": [], "note": "No history yet: {} does not exist.".format(base_dir() / "default.store")}
    try:
        keys, select = store.select_list()
        sql = "SELECT {} FROM {}".format(select, store.table_sql())
        params = []
        if since_seconds is not None:
            sql += " WHERE {} >= ?".format(store.q("timestamp"))
            params.append(since_seconds)
        sql += " ORDER BY {} DESC LIMIT ?".format(store.q("timestamp"))
        params.append(limit)
        rows = store.conn.execute(sql, params).fetchall()
        result = {"count": len(rows), "items": [row_to_item(keys, r, include_raw) for r in rows]}
        if store.warning:
            result["warning"] = store.warning
        return result
    except sqlite3.Error as exc:
        raise ToolError("Could not read history: {}".format(exc))
    finally:
        store.close()


def like_escape(text):
    return text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def tool_search_history(args):
    query = arg_str(args, "query", required=True).strip()
    if not query:
        raise ToolError("'query' must not be empty")
    if len(query) > 500:
        raise ToolError("'query' must be 500 characters or fewer")
    limit = arg_int(args, "limit", 20, 1, 200)

    store = open_history()
    if store is None:
        return {"count": 0, "items": [], "note": "No history yet: {} does not exist.".format(base_dir() / "default.store")}
    try:
        needle = query.casefold()

        def contains(haystack):
            return 1 if haystack is not None and needle in str(haystack).casefold() else 0

        # Unicode-aware case-insensitive match. SQLite's LIKE folds ASCII only.
        store.conn.create_function("flow_contains", 1, contains, deterministic=True)
        keys, select = store.select_list()
        text_cols = [store.q("text")] + ([store.q("enhanced")] if "enhanced" in store.cols else [])
        pattern = "%" + like_escape(query) + "%"
        if query.isascii():
            clause = " OR ".join("{} LIKE ? ESCAPE '\\'".format(c) for c in text_cols)
            params = [pattern] * len(text_cols)
        else:
            clause = " OR ".join("flow_contains({}) = 1".format(c) for c in text_cols)
            params = []
        sql = "SELECT {} FROM {} WHERE ({}) ORDER BY {} DESC LIMIT ?".format(
            select, store.table_sql(), clause, store.q("timestamp"))
        params.append(limit)
        rows = store.conn.execute(sql, params).fetchall()
        items = []
        for row in rows:
            data = dict(zip(keys, row))
            enhanced = data.get("enhanced") or ""
            shown = enhanced if enhanced.strip() else (data.get("text") or "")
            matched_in = "text" if contains(shown) else "raw"
            items.append(row_to_item(keys, row, include_raw=(matched_in == "raw"), matched_in=matched_in))
        result = {"query": query, "count": len(items), "items": items}
        if store.warning:
            result["warning"] = store.warning
        return result
    except sqlite3.Error as exc:
        raise ToolError("Could not search history: {}".format(exc))
    finally:
        store.close()


# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------

SUMMARY_FIELDS = [
    "totalWords", "totalDictations", "wpm", "wpmTopPercent", "dayStreak", "longestDayStreak",
    "weekStreak", "wordsThisMonth", "monthChangePercent", "monthChangeUp", "wordsCorrected",
    "dictionaryFixes", "categories", "appsUsed",
]


def iter_stat_records(path):
    try:
        handle = open(path, "r", encoding="utf-8")
    except FileNotFoundError:
        return
    with handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if isinstance(record, dict):
                yield record


def record_is_counted(record):
    words = record.get("words") or 0
    return record.get("status", "completed") == "completed" and isinstance(words, (int, float)) and words > 0


def record_local_date(record):
    moment = parse_iso(record.get("ts"))
    if moment is None:
        return None
    tz = record.get("tz")
    if isinstance(tz, (int, float)):
        moment = moment.astimezone(datetime.timezone(datetime.timedelta(minutes=int(tz))))
    else:
        moment = moment.astimezone()
    return moment.date()


def tool_get_stats(args):
    days = arg_int(args, "days", 30, 1, 3650)
    summary_path = base_dir() / "flow-stats-summary.json"
    log_path = base_dir() / "flow-stats.jsonl"

    summary = read_json_file(summary_path)
    result = {}
    notes = []
    if isinstance(summary, dict):
        for field in SUMMARY_FIELDS:
            result[field] = summary.get(field)
        if summary.get("updatedAt"):
            result["summaryUpdatedAt"] = summary.get("updatedAt")
    else:
        notes.append("No stats summary yet ({} is missing). Totals below are computed from the log.".format(
            summary_path.name))

    today = datetime.date.today()
    start = today - datetime.timedelta(days=days - 1)
    daily = {start + datetime.timedelta(days=i): 0 for i in range(days)}
    apps = {}
    window_words = 0
    window_dictations = 0
    all_words = 0
    all_dictations = 0
    saw_log = log_path.exists()

    for record in iter_stat_records(log_path):
        if not record_is_counted(record):
            continue
        words = int(record.get("words") or 0)
        all_words += words
        all_dictations += 1
        day = record_local_date(record)
        if day is None or day < start or day > today:
            continue
        daily[day] = daily.get(day, 0) + words
        window_words += words
        window_dictations += 1
        bundle = record.get("app") or "unknown"
        entry = apps.setdefault(bundle, {"bundleID": bundle, "name": record.get("appName") or bundle,
                                         "words": 0, "dictations": 0})
        entry["words"] += words
        entry["dictations"] += 1
        if record.get("appName"):
            entry["name"] = record["appName"]

    if not isinstance(summary, dict):
        result["totalWords"] = all_words
        result["totalDictations"] = all_dictations
    if not saw_log:
        notes.append("No dictation log yet ({} is missing).".format(log_path.name))

    result["window"] = {
        "days": days,
        "from": start.isoformat(),
        "to": today.isoformat(),
        "words": window_words,
        "dictations": window_dictations,
    }
    result["daily"] = [{"date": d.isoformat(), "words": w} for d, w in sorted(daily.items())]
    result["topApps"] = sorted(apps.values(), key=lambda a: (-a["words"], a["name"].lower()))[:10]
    result["notes"] = [WPM_NOTE] + notes
    return result


# ---------------------------------------------------------------------------
# Dictionary
# ---------------------------------------------------------------------------

def tool_get_dictionary(args):
    query = arg_str(args, "query")
    include_auto = arg_bool(args, "include_auto", True)
    path = base_dir() / "flow-dictionary-export.json"
    data = read_json_file(path)
    if data is None:
        return {"count": 0, "entries": [],
                "note": "No dictionary export yet ({} is missing). Open Free Flow once to create it.".format(path.name)}
    raw_entries = data.get("entries") if isinstance(data, dict) else data
    if not isinstance(raw_entries, list):
        raise ToolError("{} has an unexpected format".format(path.name))

    needle = query.strip().casefold() if query else ""
    entries = []
    for item in raw_entries:
        if not isinstance(item, dict):
            continue
        source = item.get("source") or "manual"
        if not include_auto and source == "auto":
            continue
        phrase = item.get("phrase") or ""
        replacement = item.get("replacement")
        if needle and needle not in phrase.casefold() and needle not in (replacement or "").casefold():
            continue
        entries.append({
            "phrase": phrase,
            "replacement": replacement,
            "starred": bool(item.get("starred")),
            "source": source,
            "frequencyUsed": item.get("frequencyUsed") or 0,
            "createdAt": item.get("createdAt"),
        })

    def created_key(entry):
        parsed = parse_iso(entry.get("createdAt"))
        return parsed.timestamp() if parsed else 0.0

    entries.sort(key=created_key, reverse=True)
    entries.sort(key=lambda e: not e["starred"])  # stable: starred first, then newest
    result = {"count": len(entries), "entries": entries}
    if isinstance(data, dict) and data.get("updatedAt"):
        result["exportUpdatedAt"] = data["updatedAt"]
    return result


# ---------------------------------------------------------------------------
# App bridge (heartbeat, inbox, outbox)
# ---------------------------------------------------------------------------

def heartbeat_age():
    """Seconds since the app's last heartbeat, or None if there is none or its process is gone."""
    path = mcp_dir() / "heartbeat.json"
    data = read_json_file(path)
    if not isinstance(data, dict):
        return None
    pid = data.get("pid")
    if isinstance(pid, int) and pid > 0:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return None
        except PermissionError:
            pass
    updated = data.get("updatedAtEpoch")
    if not isinstance(updated, (int, float)):
        parsed = parse_iso(data.get("updatedAt"))
        if parsed is not None:
            updated = parsed.timestamp()
        else:
            try:
                updated = path.stat().st_mtime
            except OSError:
                return None
    return max(0.0, time.time() - float(updated))


def app_is_running():
    age = heartbeat_age()
    return age is not None and age <= HEARTBEAT_STALE_SEC


def launch_app_and_wait(seconds=20.0):
    try:
        subprocess.run(["open", "-g", "-b", BUNDLE_ID], check=True, timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    except FileNotFoundError:
        raise ToolError("Could not launch Free Flow: the 'open' command is not available.")
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or b"").decode("utf-8", "replace").strip()
        raise ToolError("Could not launch Free Flow ({}). Is the app installed?".format(detail or exc.returncode))
    except subprocess.TimeoutExpired:
        raise ToolError("Launching Free Flow timed out.")
    deadline = time.time() + seconds
    while time.time() < deadline:
        age = heartbeat_age()
        if age is not None and age <= 3.0:
            return
        time.sleep(0.5)
    raise ToolError("Free Flow did not start within {} seconds. Open it once by hand and try again.".format(int(seconds)))


def outbox_path(job_id):
    return mcp_dir() / "outbox" / "{}.json".format(job_id)


def progress_path(job_id):
    return mcp_dir() / "outbox" / "{}.progress.json".format(job_id)


def take_outbox(job_id):
    path = outbox_path(job_id)
    if not path.exists():
        return None
    data = read_json_file(path)
    if data is None:
        return None  # possibly mid-write; try again next poll
    try:
        path.unlink()
    except OSError:
        pass
    return data


def tool_add_dictionary_entry(args):
    phrase = arg_str(args, "phrase", required=True).strip()
    replacement = arg_str(args, "replacement")
    if replacement is not None:
        replacement = replacement.strip() or None
    if not phrase:
        raise ToolError("'phrase' must not be empty")
    if len(phrase) > 60:
        raise ToolError("'phrase' must be 60 characters or fewer")
    if replacement is not None and len(replacement) > 4000:
        raise ToolError("'replacement' must be 4000 characters or fewer")

    running = app_is_running()
    job_id = str(uuid.uuid4())
    write_json_atomic(mcp_dir() / "inbox" / "dictionary" / "{}.json".format(job_id), {
        "id": job_id,
        "action": "add",
        "phrase": phrase,
        "replacement": replacement,
        "createdAt": now_iso(),
    })

    if not running:
        return {"ok": True, "queued": True, "id": job_id,
                "message": "Queued. Free Flow is not running; the entry will be added next time it opens."}

    deadline = time.time() + 5.0
    while time.time() < deadline:
        result = take_outbox(job_id)
        if result is not None:
            if result.get("ok"):
                return {"ok": True, "phrase": phrase, "replacement": replacement,
                        "message": result.get("message") or "Added"}
            raise ToolError(result.get("error") or "Free Flow could not add the entry.")
        time.sleep(0.25)
    return {"ok": True, "queued": True, "id": job_id,
            "message": "Queued. Free Flow did not confirm within 5 seconds; it will add the entry shortly."}


def tool_transcribe_file(args, progress_token=None):
    raw_path = arg_str(args, "path", required=True).strip()
    if not raw_path:
        raise ToolError("'path' must not be empty")
    cleanup = arg_bool(args, "cleanup", True)
    timeout_sec = arg_int(args, "timeout_sec", 900, 10, 7200)

    path = Path(os.path.expanduser(raw_path))
    if not path.is_absolute():
        raise ToolError("'path' must be absolute or start with ~")
    path = path.resolve()
    if not path.exists():
        raise ToolError("File not found: {}".format(path))
    if not path.is_file():
        raise ToolError("Not a file: {}".format(path))

    if not app_is_running():
        log("app not running; launching it in the background")
        launch_app_and_wait(20.0)

    job_id = str(uuid.uuid4())
    write_json_atomic(mcp_dir() / "inbox" / "transcribe" / "{}.json".format(job_id), {
        "id": job_id,
        "path": str(path),
        "cleanup": cleanup,
        "createdAt": now_iso(),
    })

    started = time.time()
    last_progress = None
    stale_since = None
    while True:
        result = take_outbox(job_id)
        if result is not None:
            try:
                progress_path(job_id).unlink()
            except OSError:
                pass
            if not result.get("ok"):
                raise ToolError(result.get("error") or "Transcription failed.")
            if progress_token is not None:
                send_progress(progress_token, 1.0, "Done")
            return {
                "text": result.get("text") or "",
                "rawText": result.get("rawText") or "",
                "durationSec": result.get("durationSec"),
                "transcriptionId": result.get("transcriptionId"),
                "file": str(path),
            }

        if progress_token is not None:
            info = read_json_file(progress_path(job_id))
            if isinstance(info, dict):
                value = info.get("progress")
                phase = info.get("phase") or ""
                if isinstance(value, (int, float)):
                    current = (round(float(value), 3), phase)
                    if current != last_progress:
                        last_progress = current
                        send_progress(progress_token, current[0], phase)

        if time.time() - started > timeout_sec:
            raise ToolError("Timed out after {} seconds. The job may still finish in Free Flow; "
                            "check its Files page.".format(timeout_sec))

        if app_is_running():
            stale_since = None
        else:
            stale_since = stale_since or time.time()
            if time.time() - stale_since > 10:
                raise ToolError("Free Flow stopped responding (stale heartbeat) before the transcript was ready.")
        time.sleep(1.0)


def send_progress(token, value, message):
    params = {"progressToken": token, "progress": value, "total": 1.0}
    if message:
        params["message"] = message
    send({"jsonrpc": "2.0", "method": "notifications/progress", "params": params})


# ---------------------------------------------------------------------------
# Tool registry
# ---------------------------------------------------------------------------

TOOLS = [
    {
        "name": "get_history",
        "description": ("Recent Free Flow dictations, newest first. Each item has id, time (local ISO 8601), "
                        "durationSec, status (completed, canceled, failed, pending) and text (the cleaned "
                        "text when cleanup ran, otherwise the raw transcript). Read-only."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "limit": {"type": "integer", "minimum": 1, "maximum": 200, "default": 20,
                          "description": "How many dictations to return."},
                "since": {"type": "string",
                          "description": "Only dictations at or after this ISO 8601 date or time, e.g. 2026-10-01 or 2026-10-01T09:00:00. Local time unless an offset is given."},
                "include_raw": {"type": "boolean", "default": False,
                                "description": "Also return the raw transcript before cleanup as 'raw'."},
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "search_history",
        "description": ("Case-insensitive substring search over Free Flow dictations (both raw and cleaned "
                        "text), newest first. Read-only."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "minLength": 1, "maxLength": 500,
                          "description": "Text to look for."},
                "limit": {"type": "integer", "minimum": 1, "maximum": 200, "default": 20,
                          "description": "Maximum number of matches."},
            },
            "required": ["query"],
            "additionalProperties": False,
        },
    },
    {
        "name": "get_stats",
        "description": ("Dictation stats: totals, speaking speed (wpm), streaks, this month versus last month, "
                        "words corrected, dictionary fixes, categories, plus words per day and top apps for the "
                        "last N days. wpmTopPercent compares your dictation speed against keyboard typing speeds. "
                        "Read-only."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "days": {"type": "integer", "minimum": 1, "maximum": 3650, "default": 30,
                         "description": "Window for the daily series and top apps."},
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "get_dictionary",
        "description": ("Free Flow dictionary: vocabulary words (replacement null) and replacement rules "
                        "(phrase is replaced by replacement). Starred first, then newest. Read-only."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string",
                          "description": "Optional case-insensitive filter on phrase or replacement."},
                "include_auto": {"type": "boolean", "default": True,
                                 "description": "Include words Free Flow learned automatically from your edits."},
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "add_dictionary_entry",
        "description": ("Add a word to the Free Flow dictionary so it is spelled correctly, or add a "
                        "replacement rule when 'replacement' is given. If the app is not running the entry is "
                        "queued and added next time it opens."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "phrase": {"type": "string", "minLength": 1, "maxLength": 60,
                           "description": "The word or phrase, e.g. 'Kubernetes'. For a rule, what you say or what gets misheard; separate variants with commas."},
                "replacement": {"type": "string", "maxLength": 4000,
                                "description": "Optional text that replaces the phrase, e.g. a name spelled a specific way or a snippet."},
            },
            "required": ["phrase"],
            "additionalProperties": False,
        },
    },
    {
        "name": "transcribe_file",
        "description": ("Transcribe an audio or video file and return the text. Uses the app's own engine "
                        "(the server or this Mac). The file also appears in the app's Files page. Launches "
                        "Free Flow in the background if it is not running. Sends progress notifications when "
                        "a progressToken is provided."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string",
                         "description": "Absolute path or a path starting with ~, e.g. ~/Desktop/meeting.m4a."},
                "cleanup": {"type": "boolean", "default": True,
                            "description": "Apply AI cleanup to the transcript. The raw transcript is always returned as rawText."},
                "timeout_sec": {"type": "integer", "minimum": 10, "maximum": 7200, "default": 900,
                                "description": "How long to wait for the result."},
            },
            "required": ["path"],
            "additionalProperties": False,
        },
    },
]

HANDLERS = {
    "get_history": tool_get_history,
    "search_history": tool_search_history,
    "get_stats": tool_get_stats,
    "get_dictionary": tool_get_dictionary,
    "add_dictionary_entry": tool_add_dictionary_entry,
}


def call_tool(params):
    name = params.get("name")
    args = params.get("arguments") or {}
    meta = params.get("_meta") or {}
    if not isinstance(args, dict):
        return tool_error("'arguments' must be an object")
    try:
        if name == "transcribe_file":
            token = meta.get("progressToken") if isinstance(meta, dict) else None
            value = tool_transcribe_file(args, progress_token=token)
        elif name in HANDLERS:
            value = HANDLERS[name](args)
        else:
            return tool_error("Unknown tool: {}".format(name))
    except ToolError as exc:
        return tool_error(str(exc))
    except Exception as exc:  # never crash the server on a tool bug
        log("tool {} failed:".format(name), repr(exc))
        return tool_error("{} failed: {}".format(name, exc))
    return {"content": [{"type": "text", "text": pretty(value)}], "isError": False}


def tool_error(message):
    return {"content": [{"type": "text", "text": message}], "isError": True}


# ---------------------------------------------------------------------------
# JSON-RPC loop
# ---------------------------------------------------------------------------

def handle(message):
    if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
        if isinstance(message, dict) and "id" in message:
            return {"jsonrpc": "2.0", "id": message.get("id"),
                    "error": {"code": -32600, "message": "Invalid Request"}}
        return None
    method = message.get("method")
    msg_id = message.get("id")
    is_notification = "id" not in message
    params = message.get("params") or {}

    if method is None:
        return None  # a response from the client; nothing to do
    if is_notification:
        return None  # notifications/initialized, notifications/cancelled, ...

    if method == "initialize":
        result = {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        }
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        if not isinstance(params, dict):
            return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32602, "message": "Invalid params"}}
        result = call_tool(params)
    else:
        return {"jsonrpc": "2.0", "id": msg_id,
                "error": {"code": -32601, "message": "Method not found: {}".format(method)}}
    return {"jsonrpc": "2.0", "id": msg_id, "result": result}


def main():
    log("server starting; data folder:", base_dir())
    stdin = sys.stdin.buffer
    while True:
        line = stdin.readline()
        if not line:
            break
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            log("parse error:", exc)
            send({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
            continue
        # Requests are processed one at a time, in order.
        if isinstance(message, list):
            replies = [r for r in (handle(m) for m in message) if r is not None]
            if replies:
                send(replies)
            continue
        reply = handle(message)
        if reply is not None:
            send(reply)
    log("stdin closed; exiting")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
