#!/bin/bash
set -euo pipefail

# Times szt against other disk usage tools on one folder with hyperfine,
# each tool with its default settings, and writes the results to
# bench/results-<folder name>.json (and .md) for bench/chart.py.
#
#   brew install dust gdu dua-cli ncdu diskus hyperfine
#   bench/run.sh ~/Projects

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: $0 <folder> [runs]"
  exit 1
fi
FOLDER="$(cd "$1" && pwd)"
RUNS="${2:-5}"
NAME="results-$(basename "$FOLDER")"

for tool in szt du ncdu gdu-go dust dua diskus hyperfine; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: '$tool' not found. Install the tools with:"
    echo "  brew install dust gdu dua-cli ncdu diskus hyperfine"
    exit 1
  fi
done

cd "$(dirname "$0")"
echo "Benchmarking $FOLDER ($RUNS runs each, after one warm-up run)"
szt "$FOLDER" --lines 1 --color never | tail -1

# --ignore-failure: du and others exit nonzero when some folder is unreadable.
hyperfine --shell=none --ignore-failure --warmup 1 --runs "$RUNS" \
  --export-json "$NAME.json" --export-markdown "$NAME.md" \
  --command-name szt "szt '$FOLDER'" \
  --command-name dua "dua '$FOLDER'" \
  --command-name dust "dust '$FOLDER'" \
  --command-name gdu "gdu-go --non-interactive --no-progress '$FOLDER'" \
  --command-name diskus "diskus '$FOLDER'" \
  --command-name ncdu "ncdu -0 -o /dev/null '$FOLDER'" \
  --command-name du "du -sk '$FOLDER'"

echo
echo "Results: bench/$NAME.json and bench/$NAME.md"
echo "Chart:   python3 bench/chart.py bench/$NAME.json \"<title>\" \"<subtitle>\" docs/benchmark"
