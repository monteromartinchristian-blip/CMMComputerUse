#!/usr/bin/env python3
"""Assert that `npm pack --dry-run --json` produced the tarball we publish.

Reads the JSON npm wrote and checks the file list against what the package
needs at runtime. A missing module here is a tarball that installs and then
fails to load, which is exactly the class of defect a `files` list causes.

    scripts/check-tarball.py <pack.json>
"""
from __future__ import annotations

import json
import sys

REQUIRED = {
    "package.json",
    "cordis.patch.yml",
    "index.js",
    "runtime.mjs",
    "dist/client.js",
    "icon.svg",
    "locale/en.json",
    "locale/es.json",
    "adapter/serve.sh",
    "adapter/cmm_computer_use/__init__.py",
    "adapter/cmm_computer_use/client.py",
    "adapter/cmm_computer_use/mcp_server.py",
    "README.md",
    "CHANGELOG.md",
    "LICENSE",
}

FORBIDDEN_PREFIXES = ("client.template.js", "scripts/", "tests/", "build/")


def main(path: str) -> int:
    data = json.load(open(path))[0]
    files = {entry["path"] for entry in data["files"]}
    missing = REQUIRED - files
    leaked = {name for name in files if name.startswith(FORBIDDEN_PREFIXES)}
    print("  tarball: %s - %d files - %d bytes"
          % (data["filename"], data["entryCount"], data["size"]))
    for name in sorted(files):
        print("   ", name)
    if missing:
        print("  MISSING:", ", ".join(sorted(missing)))
    if leaked:
        print("  NOT PUBLISHABLE:", ", ".join(sorted(leaked)))
    return 1 if (missing or leaked) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
