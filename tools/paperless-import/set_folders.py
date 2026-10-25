#!/usr/bin/env python3
"""Give every imported document a "Dropbox folder" custom field.

PAPERLESS_FILENAME_FORMAT (paperless.nix) uses it to store each file under its
original Dropbox folder, so /var/lib/paperless/media/documents mirrors Dropbox.

The folder comes from the existing "Dropbox path" field that import.py set.
Paperless sanitises text fields before they reach a filename template, which
turns "/" into "-", so the folder is stored with U+2044 (FRACTION SLASH) as the
separator instead; the template turns it back into "/".

Additive and safe to re-run: documents that already have the right value are
skipped. Undo by deleting the "Dropbox folder" field in Paperless.

    set_folders.py             show what would change
    set_folders.py --apply     write it
"""

import argparse
import collections
import importlib
import posixpath
import sys

# import.py is not importable by name ("import" is a keyword).
_importer = importlib.import_module("import")
HOST, Paperless = _importer.HOST, _importer.Paperless

PATH_FIELD = "Dropbox path"
FOLDER_FIELD = "Dropbox folder"
SEPARATOR = "⁄"


def field_id(api, name, create=False):
    existing = {f["name"]: f["id"] for f in api._all("custom_fields")}
    if name in existing or not create:
        return existing.get(name)
    made = api.session.post(f"{HOST}/api/custom_fields/",
                            json={"name": name, "data_type": "longtext"}, timeout=30)
    made.raise_for_status()
    return made.json()["id"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()

    api = Paperless()
    path_id = field_id(api, PATH_FIELD)
    folder_id = field_id(api, FOLDER_FIELD, create=args.apply)
    if path_id is None:
        sys.exit(f'no "{PATH_FIELD}" custom field in Paperless')

    wanted = collections.defaultdict(list)   # encoded folder -> document ids
    without_path = 0
    already = 0
    documents = api._all("documents")
    for doc in documents:
        values = {f["field"]: f["value"] for f in doc["custom_fields"]}
        path = values.get(path_id)
        if not path:
            without_path += 1
            continue
        folder = posixpath.dirname(path).replace("/", SEPARATOR)
        if folder_id is not None and values.get(folder_id) == folder:
            already += 1
            continue
        wanted[folder].append(doc["id"])

    todo = sum(len(ids) for ids in wanted.values())
    print(f"{len(documents)} documents: {todo} to set across {len(wanted)} folders, "
          f"{already} already set, {without_path} without a Dropbox path (go to inbox/)")
    for folder, ids in sorted(wanted.items())[:10]:
        print(f"  {len(ids):4}  {folder.replace(SEPARATOR, '/')}")
    if not args.apply:
        print("dry run; re-run with --apply to write")
        return

    for n, (folder, ids) in enumerate(sorted(wanted.items()), 1):
        reply = api.session.post(f"{HOST}/api/documents/bulk_edit/", json={
            "documents": ids,
            "method": "modify_custom_fields",
            "parameters": {"add_custom_fields": {str(folder_id): folder}, "remove_custom_fields": []},
        }, timeout=120)
        if reply.status_code != 200:
            sys.exit(f"HTTP {reply.status_code} on {folder}: {reply.text[:300]}")
        if n % 50 == 0 or n == len(wanted):
            print(f"  {n}/{len(wanted)} folders")


if __name__ == "__main__":
    main()
