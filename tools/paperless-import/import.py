#!/usr/bin/env python3
"""Import a folder tree into Paperless-ngx through its REST API.

Read-only on the source tree. Each file is uploaded with:
  - a tag for its category (the top-level folder, or the folder below
    "category_parent" from config.json)
  - the batch tag, so the whole import can be selected (or undone) later
  - a document type, correspondent or extra tag where its folder makes that
    certain (see RULES); otherwise those are left empty rather than guessed
  - its original relative path in a "Dropbox path" custom field

No year tags: Paperless reads the date from the document itself.

Uploads are throttled (a few in flight at a time) and every outcome is appended
to a state file, so the run can be stopped and restarted without re-uploading.

    import.py --dry-run                  list what would happen, upload nothing
    import.py --only <category>          one category
    import.py                            everything
    import.py --report                   summarise the state file
"""

import argparse
import collections
import hashlib
import json
import sys
import time
from pathlib import Path

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

TOKEN_FILE = Path.home() / ".config/paperless/token"
# Everything personal stays outside this public repo: the config (host,
# folder names, rules; see config.example.json) and the run state, which
# lists every document path.
CONFIG_FILE = Path.home() / ".config/paperless-import/config.json"
STATE_FILE = Path.home() / ".local/state/paperless-import/state.jsonl"
CONFIG = json.loads(CONFIG_FILE.read_text())
HOST = CONFIG["host"]
PATH_FIELD = "Dropbox path"

DOCUMENTS = {".pdf", ".jpg", ".jpeg", ".png", ".tif", ".tiff", ".webp", ".gif"}
# Converted by Tika + Gotenberg on the server.
OFFICE = {".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".odt", ".ods", ".odp", ".rtf", ".eml"}

SKIP_DIRS = {".git", ".venv", "venv", "node_modules", "site-packages", "__pycache__",
             ".dropbox.cache", ".dropbox"}
SKIP_CATEGORIES = set(CONFIG.get("skip_categories", []))

BATCH_TAG = "dropbox-import"
# Category tag = folder name, except where the folder name is a poor tag.
TAG_NAMES = CONFIG.get("tag_names", {})
# Folder prefix (lower case, relative to the root) -> metadata that folder
# makes certain. Every matching rule applies.
RULES = [(prefix, rule) for prefix, rule in CONFIG.get("rules", [])]

MAX_IN_FLIGHT = 3
POLL_SECONDS = 5
TASK_TIMEOUT = 45 * 60


def category_of(parts):
    """<parent>/a/b/c.pdf -> a; x/c.pdf -> x. <parent> is category_parent."""
    if parts[0] == CONFIG.get("category_parent"):
        return parts[1].lower() if len(parts) > 2 else "docs"
    return parts[0].lower() if len(parts) > 1 else "dropbox-root"


def metadata_for(parts):
    """Tags, document type and correspondent for a file, from its folders."""
    category = category_of(parts)
    meta = {"tags": [TAG_NAMES.get(category, category), BATCH_TAG], "type": None, "correspondent": None}
    folder = "/".join(parts[:-1]).lower() + "/"
    for prefix, rule in RULES:
        if folder.startswith(prefix + "/"):
            if "tag" in rule and rule["tag"] not in meta["tags"]:
                meta["tags"].append(rule["tag"])
            meta["type"] = rule.get("type", meta["type"])
            meta["correspondent"] = rule.get("correspondent", meta["correspondent"])
    return category, meta


def describe(meta):
    extra = [f"{key}={meta[key]}" for key in ("type", "correspondent") if meta[key]]
    return " + ".join([t for t in meta["tags"] if t != BATCH_TAG] + extra)


def collect(root, only):
    """Yield (path, relative path, metadata), in a stable order."""
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        rel = path.relative_to(root)
        parts = rel.parts
        if any(p in SKIP_DIRS for p in parts[:-1]):
            continue
        if path.suffix.lower() not in DOCUMENTS | OFFICE:
            continue
        category, meta = metadata_for(parts)
        if category in SKIP_CATEGORIES or (only and category not in only):
            continue
        yield path, str(rel), meta


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_state():
    """Latest record per relative path."""
    state = {}
    if STATE_FILE.exists():
        for line in STATE_FILE.read_text().splitlines():
            if line.strip():
                record = json.loads(line)
                state[record["path"]] = record
    return state


def record(entry):
    with STATE_FILE.open("a") as handle:
        handle.write(json.dumps(entry, ensure_ascii=False) + "\n")


class Paperless:
    def __init__(self):
        self.session = requests.Session()
        # Slow or flaky links: retry reads and gateway errors instead of dying.
        # Only GETs — a retried upload is handled explicitly in main().
        retry = Retry(total=6, backoff_factor=2, status_forcelist=[502, 503, 504], allowed_methods=["GET"])
        self.session.mount("https://", HTTPAdapter(max_retries=retry))
        self.session.headers["Authorization"] = "Token " + TOKEN_FILE.read_text().strip()
        self.session.headers["Accept"] = "application/json; version=10"
        self.ids = {}
        self.field_id = None

    def _all(self, endpoint):
        url, items = f"{HOST}/api/{endpoint}/?page_size=200", []
        while url:
            page = self.session.get(url, timeout=30)
            page.raise_for_status()
            body = page.json()
            items += body["results"]
            # The API hands back http:// links from behind the reverse proxy.
            url = body["next"] and body["next"].replace("http://", "https://", 1)
        return items

    def object_id(self, endpoint, name):
        """Id of the tag / document type / correspondent with this name, created if missing."""
        if endpoint not in self.ids:
            self.ids[endpoint] = {o["name"].lower(): o["id"] for o in self._all(endpoint)}
        known = self.ids[endpoint]
        if name.lower() not in known:
            made = self.session.post(f"{HOST}/api/{endpoint}/", json={"name": name}, timeout=30)
            made.raise_for_status()
            known[name.lower()] = made.json()["id"]
        return known[name.lower()]

    def path_field(self):
        if self.field_id is None:
            existing = {f["name"]: f["id"] for f in self._all("custom_fields")}
            if PATH_FIELD not in existing:
                made = self.session.post(f"{HOST}/api/custom_fields/",
                                         json={"name": PATH_FIELD, "data_type": "longtext"}, timeout=30)
                made.raise_for_status()
                existing[PATH_FIELD] = made.json()["id"]
            self.field_id = existing[PATH_FIELD]
        return self.field_id

    def upload(self, path, rel, meta):
        data = [("tags", str(self.object_id("tags", t))) for t in meta["tags"]]
        if meta["type"]:
            data.append(("document_type", str(self.object_id("document_types", meta["type"]))))
        if meta["correspondent"]:
            data.append(("correspondent", str(self.object_id("correspondents", meta["correspondent"]))))
        data.append(("custom_fields", json.dumps({str(self.path_field()): rel})))
        with path.open("rb") as handle:
            reply = self.session.post(f"{HOST}/api/documents/post_document/",
                                      data=data, files={"document": (path.name, handle)}, timeout=600)
        if reply.status_code != 200:
            raise RuntimeError(f"HTTP {reply.status_code}: {reply.text[:300]}")
        return reply.json()

    def task(self, task_id):
        reply = self.session.get(f"{HOST}/api/tasks/", params={"task_id": task_id}, timeout=90)
        reply.raise_for_status()
        results = reply.json()["results"]
        return results[0] if results else None


def failure_reason(task):
    for key in ("result_message", "result", "result_data"):
        if task.get(key):
            return json.dumps(task[key], ensure_ascii=False)[:400] if not isinstance(task[key], str) else task[key][:400]
    return "no reason given"


def settle(api, in_flight, block):
    """Poll in-flight uploads; return once there is room (or all are done, if block)."""
    while in_flight:
        for rel, entry in list(in_flight.items()):
            try:
                task = api.task(entry["task_id"])
            except requests.RequestException as error:
                # The server keeps processing regardless; ask again next round.
                print(f"  (status check failed, will retry: {type(error).__name__})", flush=True)
                time.sleep(30)
                continue
            status = (task or {}).get("status", "pending").lower()
            waited = time.time() - entry["started"]
            if status == "success":
                entry.update(status="success", documents=task.get("related_document_ids", []),
                             seconds=round(waited))
            elif status in ("failure", "revoked"):
                reason = failure_reason(task)
                entry.update(status="duplicate" if "duplicate" in reason.lower() else "failure",
                             error=reason, seconds=round(waited))
            elif waited > TASK_TIMEOUT:
                entry.update(status="timeout", seconds=round(waited))
            else:
                continue
            del in_flight[rel]
            entry.pop("started")
            record(entry)
            print(f"  {entry['status']:9} {entry.get('seconds', 0):4}s  {rel}"
                  + (f"\n            {entry['error']}" if entry.get("error") else ""), flush=True)
        if not in_flight or (not block and len(in_flight) < MAX_IN_FLIGHT):
            return
        time.sleep(POLL_SECONDS)


def report():
    counts = collections.Counter(r["status"] for r in load_state().values())
    for status, count in counts.most_common():
        print(f"{count:6}  {status}")
    for r in load_state().values():
        if r["status"] in ("failure", "timeout", "upload-error"):
            print(f"\n{r['status']}: {r['path']}\n    {r.get('error', '')}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=Path.home() / "Dropbox")
    parser.add_argument("--only", action="append", help="category to import (repeatable)")
    parser.add_argument("--limit", type=int, help="stop after this many uploads")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--report", action="store_true")
    args = parser.parse_args()
    if args.report:
        return report()

    state = load_state()
    done = {"success", "duplicate", "duplicate-local"}
    seen = {r["sha256"]: r["path"] for r in state.values() if r["status"] in done and "sha256" in r}
    plan, summary = [], collections.Counter()
    for path, rel, meta in collect(args.root, args.only):
        if state.get(rel, {}).get("status") in done:
            summary["already done"] += 1
            continue
        digest = sha256(path)
        if digest in seen and seen[digest] != rel:
            summary["duplicate of another file"] += 1
            if not args.dry_run:
                record({"path": rel, "sha256": digest, "status": "duplicate-local", "same_as": seen[digest]})
            continue
        seen[digest] = rel
        plan.append((path, rel, meta, digest))
        summary["to upload"] += 1

    if args.limit:
        plan = plan[:args.limit]
    by_tags = collections.Counter(describe(meta) for _, _, meta, _ in plan)
    if args.dry_run:
        for _, rel, meta, _ in plan:
            print(f"{describe(meta):46} {rel}")
        print()
    for label, count in sorted(by_tags.items()):
        print(f"{count:6}  {label}")
    megabytes = sum(p.stat().st_size for p, _, _, _ in plan) / 1e6
    print(f"\n{len(plan)} files to upload, {megabytes:.0f} MB; " +
          ", ".join(f"{count} {label}" for label, count in summary.items() if label != "to upload"))
    if args.dry_run or not plan:
        return

    api, in_flight, started = Paperless(), {}, time.time()
    # Uploads left in flight by an interrupted run: pick their tasks up again.
    for rel, entry in state.items():
        if entry["status"] == "uploaded":
            in_flight[rel] = dict(entry, started=time.time())
    try:
        for number, (path, rel, meta, digest) in enumerate(plan, 1):
            if rel in in_flight:
                continue
            settle(api, in_flight, block=len(in_flight) >= MAX_IN_FLIGHT)
            entry = {"path": rel, "sha256": digest, **meta}
            try:
                entry.update(status="uploaded", task_id=api.upload(path, rel, meta))
            except Exception as error:  # keep going; the file is reported and retried on rerun
                entry.update(status="upload-error", error=str(error)[:400])
                print(f"  upload-error       {rel}\n            {entry['error']}", flush=True)
                record(entry)
                continue
            record(entry)
            in_flight[rel] = dict(entry, started=time.time())
            print(f"[{number}/{len(plan)}] sent  {rel}", flush=True)
        settle(api, in_flight, block=True)
    except KeyboardInterrupt:
        print("\nInterrupted. Uploads already sent keep processing on the server; rerun to resume.")
        sys.exit(130)
    print(f"\nFinished in {(time.time() - started) / 60:.1f} min.")
    report()


if __name__ == "__main__":
    main()
