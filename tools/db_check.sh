#!/bin/sh
# The mysql store against a real MariaDB (or MySQL), on a throwaway server.
#
#   sh tools/db_check.sh [workdir]            (run from the repository root)
#   CH_SUITES=storage_spec sh tools/db_check.sh   only those suites' statements
#   DB_SOCKET=/path/sock sh tools/db_check.sh     a server already running (root, no password)
#
# Needs lua5.4, python3 with PyMySQL (pip install pymysql; PYTHON= another one), and mariadbd,
# mariadb-install-db and mariadb (or mysqld / mysql) unless DB_SOCKET is set.
# The server it starts has its own data directory under workdir (a new
# temporary directory if not given), listens on a socket only, and is shut
# down and deleted at the end. Nothing else on the machine is touched.
#
# What it checks (docs/developer.md, "Real database check"):
#   1. install/sql/crimson_hitman.sql imports into an empty utf8mb4 database,
#      and again on top (every statement idempotent), and into a latin1 one;
#      every table InnoDB, every text column utf8mb4_unicode_ci.
#   2. What MySQLStore.migrate sends to a database an old version left at
#      its oldest (each table its key only, MyISAM, latin1, escrow's old
#      `portion`) runs, and leaves the same tables as a fresh install.
#   3. Every statement the store sends during the server suite, run in order
#      on the real server beside tests/harness/mysql_exec.lua's answers:
#      refusals either side fail; rows and counts that differ are listed.
#      Every distinct statement is PREPAREd against the schema.
#   4. The reserved-word list in tests/harness/reserved_words.lua holds every
#      word this server refuses as a column name.
# Exit status 1 when any of these fails.

set -u
here=$(pwd)
[ -f tests/run.lua ] || { echo "run from the repository root" >&2; exit 2; }
work=${1:-$(mktemp -d)}
mkdir -p "$work"
work=$(cd "$work" && pwd)
status=0
python=${PYTHON:-python3}
"$python" -c "import pymysql" 2>/dev/null || { echo "needs PyMySQL: pip install pymysql (or PYTHON=/path/to/python)" >&2; exit 2; }
started=

if [ -z "${DB_SOCKET:-}" ]; then
    server=$(command -v mariadbd || command -v mysqld)
    install=$(command -v mariadb-install-db || command -v mysql_install_db)
    [ -n "$server" ] && [ -n "$install" ] || { echo "no mariadbd / mysqld found" >&2; exit 2; }
    rm -rf "$work/data"
    "$install" --no-defaults --datadir="$work/data" --user="$(id -un)" \
        --auth-root-authentication-method=normal --skip-test-db >"$work/install.log" 2>&1 \
        || { cat "$work/install.log" >&2; exit 2; }
    "$server" --no-defaults --datadir="$work/data" --socket="$work/sock" --skip-networking \
        --pid-file="$work/pid" --user="$(id -un)" --innodb-buffer-pool-size=64M \
        --performance-schema=OFF --log-error="$work/server.log" >/dev/null 2>&1 &
    started=1
    DB_SOCKET="$work/sock"
    i=0
    until [ -S "$DB_SOCKET" ]; do
        i=$((i + 1)); [ $i -gt 60 ] && { cat "$work/server.log" >&2; exit 2; }
        sleep 0.5
    done
fi

client=$(command -v mariadb || command -v mysql)
sql() { "$client" --no-defaults -S "$DB_SOCKET" -uroot "$@"; }

finish() {
    if [ -n "$started" ]; then
        kill "$(cat "$work/pid")" 2>/dev/null
        while [ -S "$work/sock" ]; do sleep 0.2; done
        rm -rf "$work/data" "$work/sock"
    fi
}
trap finish EXIT

echo "── server ───────────────────────────────────────────────"
sql -N -e "SELECT VERSION(), @@sql_mode"

echo "── 1. install/sql ───────────────────────────────────────"
sql -e "DROP DATABASE IF EXISTS ch_install; CREATE DATABASE ch_install CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        DROP DATABASE IF EXISTS ch_latin; CREATE DATABASE ch_latin CHARACTER SET latin1;"
for pass in first again; do
    if sql ch_install < crimson-hitman/install/sql/crimson_hitman.sql; then echo "  utf8mb4 database, $pass: ok"
    else echo "  FAIL utf8mb4 database, $pass"; status=1; fi
done
if sql ch_latin < crimson-hitman/install/sql/crimson_hitman.sql; then echo "  latin1 database: ok"
else echo "  FAIL latin1 database"; status=1; fi
bad=$(sql -N -e "SELECT CONCAT(TABLE_SCHEMA, '.', TABLE_NAME, ' ', ENGINE, ' ', TABLE_COLLATION) FROM information_schema.TABLES
                 WHERE TABLE_SCHEMA IN ('ch_install', 'ch_latin') AND (ENGINE <> 'InnoDB' OR TABLE_COLLATION <> 'utf8mb4_unicode_ci')
                 UNION ALL SELECT CONCAT(TABLE_SCHEMA, '.', TABLE_NAME, '.', COLUMN_NAME, ' ', COLLATION_NAME) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA IN ('ch_install', 'ch_latin') AND COLLATION_NAME IS NOT NULL AND COLLATION_NAME <> 'utf8mb4_unicode_ci'")
sql -N -e "SELECT CONCAT('  tables: ', COUNT(*)) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'ch_install'"
if [ -n "$bad" ]; then echo "  FAIL not InnoDB / utf8mb4_unicode_ci:"; echo "$bad"; status=1
else echo "  every table InnoDB, every text column utf8mb4_unicode_ci"; fi

echo "── 2. migrate an old database ───────────────────────────"
DB_TRACE_MIGRATE=1 CH_SUITES=none lua5.4 tools/db_trace.lua "$work/migrate.jsonl" >"$work/migrate_trace.log" 2>&1 \
    || { tail -20 "$work/migrate_trace.log"; status=1; }
sql -e "DROP DATABASE IF EXISTS ch_migrate; CREATE DATABASE ch_migrate CHARACTER SET latin1"
"$python" tools/db_replay.py "$work/migrate.jsonl" --migrate --reference ch_install \
    --socket "$DB_SOCKET" --database ch_migrate || status=1

echo "── 3. the suite's statements, replayed ──────────────────"
lua5.4 tools/db_trace.lua "$work/trace.jsonl" >"$work/trace.log" 2>&1
tail -1 "$work/trace.log"
sql -e "DROP DATABASE IF EXISTS ch_replay; CREATE DATABASE ch_replay CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
"$python" tools/db_replay.py "$work/trace.jsonl" --socket "$DB_SOCKET" --database ch_replay \
    --report "$work/replay.txt" > /dev/null || status=1
sed -n '1,/^mismatches/p' "$work/replay.txt"
echo "  (full report, the mismatches by test: $work/replay.txt)"

echo "── 4. reserved words ────────────────────────────────────"
"$python" tools/db_replay.py --reserved --socket "$DB_SOCKET" --database ch_install none || status=1

cd "$here"
[ $status -eq 0 ] && echo "db_check: passed" || echo "db_check: FAILED"
exit $status
