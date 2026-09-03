#!/bin/sh
# Every check, in one place.
#
#   lua5.4 tests/run.lua          server logic against a stubbed runtime
#   lua5.4 tests/static_check.lua source-level rules a unit test cannot see
#   node    tests/ui/run.js       the real app.js against a scripted server
#
# Run from the repository root.

set -e
status=0

echo "── server suite ─────────────────────────────────────────"
lua5.4 crimson-bounty/tests/run.lua || status=1

echo "── static checks ────────────────────────────────────────"
lua5.4 crimson-bounty/tests/static_check.lua || status=1

echo "── ui suite ─────────────────────────────────────────────"
if command -v node >/dev/null 2>&1; then
    node crimson-bounty/tests/ui/run.js || status=1
else
    echo "node not installed; skipping the ui suite"
fi

exit $status
