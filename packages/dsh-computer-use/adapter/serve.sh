#!/bin/sh
# Entry point the DSH MCP client launches: `serve.sh --socket <path> --mode background`.
#
# It exists so the patch never has to name an interpreter path. The adapter is a
# stdlib-only Python package, so `python3` is enough; when it is absent the
# script says so and exits non-zero instead of letting the MCP client report an
# opaque spawn failure.
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

PYTHON=${CMM_COMPUTER_USE_PYTHON:-}
if [ -z "$PYTHON" ]; then
  PYTHON=$(command -v python3 || true)
fi
if [ -z "$PYTHON" ] || [ ! -x "$PYTHON" ]; then
  echo "cmm-computer-use: python3 not found; install the Xcode Command Line Tools (xcode-select --install) or set CMM_COMPUTER_USE_PYTHON" >&2
  exit 78
fi

cd "$DIR"
exec "$PYTHON" -B -m cmm_computer_use.mcp_server "$@"
