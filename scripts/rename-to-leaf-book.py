#!/usr/bin/env python3
# Word-boundary rename for the Pinkha vocabulary migration:
#   Document  -> Leaf       documents  -> leaves
#   Database  -> Book       databases  -> books
#   Folder    -> Shelf      folders    -> shelves
#   Workspace -> Library    workspace  -> library
#
# Protects Notion-specific names (NotionDatabase, child_database,
# ChildDatabase, notion_database), DocumentDataModel (Realm/Craft),
# `db_path` (SQLite file path, not the Pinkha Book), and English
# words derived from "document" (documentation/-ed/-ing). See
# docs/VOCABULARY.md for the full rationale.
#
# Usage:
#   ./scripts/rename-docs-dbs.py PATH [PATH ...]
#   ./scripts/rename-docs-dbs.py --dry-run PATH

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

EXTENSIONS = {".rs", ".swift", ".udl", ".toml", ".sql", ".md",
              ".xcstrings", ".yml", ".yaml", ".sh", ".rb", ".py"}

SKIP_DIRS = {"target", ".build", ".git", "DerivedData",
             "node_modules", ".swiftpm", "build"}

PROTECTIONS = [
    # Notion-specific: their API uses "database" as terminology.
    ("NotionDatabase", "NOTION_DATABASE_SENT_P"),
    ("notion_database", "notion_database_SENT_s"),
    ("child_database", "child_database_SENT_s"),
    ("ChildDatabase", "CHILD_DATABASE_SENT_P"),
    # Realm / Craft external term.
    ("DocumentDataModel", "DOC_DATA_MODEL_SENT"),
    # English doc-comment words that derive from "document". Without
    # these the regex would rewrite "documentation" to "pageation",
    # "documented" to "pageed", etc.
    ("documentation", "DOCUMENTATION_SENT_W"),
    ("documented", "DOCUMENTED_SENT_W"),
    ("documenting", "DOCUMENTING_SENT_W"),
    # Storage-layer terms that refer to SQLite, not the Pinkha
    # domain Database. The Bear/Craft import paths use these too.
    ("db_path", "DB_PATH_SENT_S"),
    ("dbg!", "DBG_BANG_SENT"),
    ("dbg::", "DBG_COLONCOLON_SENT"),
]


def _w(pat: str) -> re.Pattern[str]:
    # Custom word boundary: alpha-num on either side disqualifies the
    # match, but `_` is treated as a separator. This lets us catch
    # snake_case compound identifiers like `delete_database_cascade`
    # while leaving `documentation` alone.
    return re.compile(r"(?<![A-Za-z0-9])" + pat + r"(?![A-Za-z0-9])")


REPLACEMENTS: list[tuple[re.Pattern[str] | str, str]] = [
    # PascalCase: plain substring (case-sensitive, distinct from the
    # lowercase identifiers, so no risk of corrupting English words
    # like "documentation"). NotionDatabase/ChildDatabase/
    # DocumentDataModel are stashed via PROTECTIONS, so plain
    # substring is safe here. Plurals first to avoid half-eating "s".
    ("Documents", "Leaves"),
    ("Document", "Leaf"),
    ("Databases", "Books"),
    ("Database", "Book"),
    ("Folders", "Shelves"),
    ("Folder", "Shelf"),
    ("Workspace", "Library"),
    # snake_case: word-boundary aware so "documentation" / "documented"
    # / "documenting" (all stashed via PROTECTIONS anyway, but
    # defence-in-depth) are not touched. The custom _w() treats `_`
    # as a separator so compound identifiers like `delete_book_cascade`
    # are caught.
    (_w("documents"), "leaves"),
    (_w("document"), "leaf"),
    (_w("databases"), "books"),
    (_w("database"), "book"),
    (_w("folders"), "shelves"),
    (_w("folder"), "shelf"),
    (_w("workspace"), "library"),
    # Pinkha-domain abbreviations in compound identifiers only.
    # Standalone `doc` and `db` are left alone to keep `#[doc]`
    # attrs, `cargo doc`, `dbg::` paths intact. `db_path` (SQLite
    # file path) is stashed under a protection sentinel before this
    # pass, so the `db` left here only ever means a Pinkha Book.
    (re.compile(r"(?<![A-Za-z0-9])doc(?=_)"), "leaf"),    # doc_id, doc_count
    (re.compile(r"(?<=_)doc(?![A-Za-z0-9])"), "leaf"),    # with_doc, _doc_foo
    (re.compile(r"(?<![A-Za-z0-9])docs(?=_)"), "leaves"), # docs_*
    (re.compile(r"(?<=_)docs(?![A-Za-z0-9])"), "leaves"), # _docs
    (re.compile(r"(?<![A-Za-z0-9])db(?=_)"), "book"),     # db_id, db_meta
    (re.compile(r"(?<=_)db(?![A-Za-z0-9])"), "book"),     # with_db
    (re.compile(r"(?<![A-Za-z0-9])dbs(?=_)"), "books"),   # dbs_*
    (re.compile(r"(?<=_)dbs(?![A-Za-z0-9])"), "books"),   # _dbs
]


def rename_text(text: str) -> str:
    for src, sent in PROTECTIONS:
        text = text.replace(src, sent)
    for pat, repl in REPLACEMENTS:
        if isinstance(pat, str):
            text = text.replace(pat, repl)
        else:
            text = pat.sub(repl, text)
    for src, sent in PROTECTIONS:
        text = text.replace(sent, src)
    return text


def should_skip(rel: Path) -> bool:
    return bool(set(rel.parts) & SKIP_DIRS)


def process_file(path: Path, dry_run: bool) -> bool:
    try:
        original = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, FileNotFoundError):
        return False
    new = rename_text(original)
    if new == original:
        return False
    if not dry_run:
        path.write_text(new, encoding="utf-8")
    return True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+", type=Path)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    changed: list[Path] = []
    for root in args.paths:
        if root.is_file():
            files = [root]
        else:
            files = [
                p for p in root.rglob("*")
                if p.is_file()
                and p.suffix in EXTENSIONS
                and not should_skip(p.relative_to(root))
            ]
        for f in files:
            if process_file(f, args.dry_run):
                changed.append(f)

    print(f"{'[dry-run] ' if args.dry_run else ''}{len(changed)} files changed")
    for f in changed[:50]:
        print(f"  {f}")
    if len(changed) > 50:
        print(f"  ...and {len(changed) - 50} more")
    return 0


if __name__ == "__main__":
    sys.exit(main())
