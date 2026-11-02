#!/usr/bin/env python3
"""Rebuilds extensions/index.json. Run after adding or changing an extension.

The app reads this index from GitHub to fill the market and uses the hashes to verify each download.
"""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "extensions"
SKIP = {"index.json", "README.md"}


def describe(folder: Path) -> dict:
    manifest = json.loads((folder / "extension.json").read_text(encoding="utf-8"))
    files = [
        {"path": path.relative_to(folder).as_posix(), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        for path in sorted(folder.rglob("*"))
        if path.is_file() and not path.name.startswith(".")
    ]
    return {
        "id": manifest["id"],
        "folder": folder.name,
        "version": manifest["version"],
        "name": manifest["name"],
        "description": manifest["description"],
        "category": manifest["category"],
        "regions": manifest.get("regions", ["global"]),
        "icon": manifest["icon"],
        "files": files,
    }


def main() -> None:
    folders = sorted(path for path in ROOT.iterdir() if path.is_dir() and not path.name.startswith("."))
    index = {"schema": 1, "extensions": [describe(folder) for folder in folders]}
    (ROOT / "index.json").write_text(json.dumps(index, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"indexed {len(folders)} extensions")


if __name__ == "__main__":
    main()
