#!/bin/sh
# Every check, in one place.
#
#   lua5.4 tests/run.lua          server logic against a stubbed runtime
#   lua5.4 tests/static_check.lua source-level rules a unit test cannot see
#   node    tests/ui/run.js       the real app.js against a scripted server
#   node    tests/layout/run.js   the real page in a real browser, measured
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

# Layout is the one thing neither of the others can see: the server suite
# has no DOM, and the ui suite's DOM shim has no layout engine, so a control
# that is present, correct and three pixels tall passes both. This renders
# the real page in a real browser and measures it. It skips itself where
# playwright is not installed.
echo "── layout suite ─────────────────────────────────────────"
if command -v node >/dev/null 2>&1; then
    node crimson-bounty/tests/layout/run.js || status=1
else
    echo "node not installed; skipping the layout suite"
fi

exit $status
