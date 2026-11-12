"""Run tools/db_trace.lua's statements on a real MariaDB / MySQL and put its
answers beside the stand-in's (tests/harness/mysql_exec.lua).

    python3 tools/db_replay.py <trace.jsonl> --socket <sock> --database <db>
                              [--user root] [--report out.txt]

Called by tools/db_check.sh, which says what it checks; docs/developer.md,
"Real database check", says how to run it. Needs PyMySQL (pip install pymysql).

It connects as oxmysql does (utf8mb4, FOUND_ROWS so an UPDATE answers the rows
it matched, the server's sql_mode plus IGNORE_SPACE: docs/developer.md, oxmysql
§3, §5) and, for each line of the trace:

  * reset: drops every crimson_ table, so the next stack starts from none;
  * begin / commit / rollback: the same on the real connection;
  * q: runs the statement and compares.
      - the real server refused one the stand-in ran: FAIL (the bug this hunts);
      - the stand-in refused one the real server ran: FAIL (the stand-in is
        stricter than the server, so a test proves something false);
      - the rows a SELECT answered, the rows an UPDATE / DELETE matched, a
        COUNT(*): a difference is a MISMATCH. A test that writes rows into
        the stand-in by hand (Exec.tables) diverges from here on; these are
        listed, by test, for reading rather than failing the run.

Then every distinct statement shape is PREPAREd with its `?` against the
schema the trace built (syntax, table and column names), and every crimson_
table is checked to be InnoDB and utf8mb4 / utf8mb4_unicode_ci.
Exits 1 when anything FAILs.
"""

import argparse
import collections
import json
import re
import sys

import pymysql
from pymysql.constants import CLIENT


def norm(v):
    if v is None:
        return None
    if isinstance(v, bool):
        return 1 if v else 0
    if isinstance(v, float) and v.is_integer():
        return int(v)
    if isinstance(v, (bytes, bytearray)):
        return v.decode('utf-8', 'replace')
    if hasattr(v, 'is_integer') and not isinstance(v, (int, float)):  # Decimal
        return int(v) if v == int(v) else float(v)
    return v


def row_key(row):
    return tuple(sorted((k, repr(norm(v))) for k, v in row.items() if norm(v) is not None))


def kind_of(sql):
    m = re.match(r'\s*(\w+)', sql)
    return m.group(1).upper() if m else ''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('trace', nargs='?')
    ap.add_argument('--socket', required=True)
    ap.add_argument('--database', required=True)
    ap.add_argument('--user', default='root')
    ap.add_argument('--report', default=None)
    ap.add_argument('--mismatches', default=None,
                    help='write every mismatch here, one JSON object a line')
    ap.add_argument('--show', type=int, default=8, help='examples shown per finding')
    ap.add_argument('--migrate', action='store_true',
                    help='the trace is DB_TRACE_MIGRATE\'s: build the old database, run its ALTERs, '
                         'compare with --reference')
    ap.add_argument('--reference', default=None,
                    help='with --migrate: a database install/sql/crimson_hitman.sql was imported into')
    ap.add_argument('--reserved', action='store_true',
                    help='check tests/harness/reserved_words.lua against this server (trace unused)')
    a = ap.parse_args()
    if a.reserved:
        sys.exit(reserved(a))
    if a.migrate:
        sys.exit(migrate(a))

    conn = pymysql.connect(unix_socket=a.socket, user=a.user, database=a.database,
                           charset='utf8mb4', autocommit=True,
                           client_flag=CLIENT.FOUND_ROWS | CLIENT.MULTI_RESULTS,
                           cursorclass=pymysql.cursors.DictCursor)
    cur = conn.cursor()
    cur.execute("SET SESSION sql_mode = CONCAT(@@sql_mode, ',IGNORE_SPACE')")
    cur.execute('SELECT VERSION() AS v, @@sql_mode AS m')
    info = cur.fetchone()

    counts = collections.Counter()
    fails = collections.defaultdict(list)       # finding -> [(test, shape, detail)]
    mismatches = collections.defaultdict(list)  # test -> [(shape, detail)]
    warns = collections.defaultdict(list)
    shapes = collections.OrderedDict()
    ddl = []

    def drop_all():
        cur.execute("SELECT TABLE_NAME FROM information_schema.TABLES "
                    "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 'crimson%%'")
        names = [r['TABLE_NAME'] for r in cur.fetchall()]
        for n in names:
            cur.execute('DROP TABLE `%s`' % n)

    dump = open(a.mismatches, 'w', encoding='utf-8') if a.mismatches else None
    in_tx = False
    with open(a.trace, encoding='utf-8') as f:
        for line in f:
            rec = json.loads(line)
            k = rec['k']
            if k == 'reset':
                if in_tx:
                    conn.rollback()
                    in_tx = False
                drop_all()
                counts['stacks'] += 1
                continue
            if k == 'begin':
                conn.begin()
                in_tx = True
                continue
            if k in ('commit', 'rollback'):
                (conn.commit if k == 'commit' else conn.rollback)()
                in_tx = False
                continue
            if k == 'warn':
                warns[rec['what']].append((rec.get('test'), rec['shape']))
                continue

            sql, shape, test = rec['sql'], rec['shape'], rec.get('test', '?')
            target = re.search(r'\b(?:FROM|INTO|UPDATE|TABLE(?: IF NOT EXISTS)?)\s+([\w.]+)', shape)
            if target and not (target.group(1).startswith('crimson')
                               or target.group(1).startswith('information_schema')):
                # The stand-in's own tests, on tables of their own (`t`).
                counts['skipped: not a crimson table'] += 1
                continue
            shapes.setdefault(shape, 0)
            shapes[shape] += 1
            verb = kind_of(shape)
            if verb in ('CREATE', 'ALTER'):
                ddl.append(sql)
            counts['statements'] += 1
            try:
                cur.execute(sql)
                real_rows = cur.fetchall() if cur.description else None
                real_count = cur.rowcount
                real_err = None
            except pymysql.MySQLError as e:
                real_err = '%s %s' % (e.args[0], e.args[1] if len(e.args) > 1 else '')
                real_rows, real_count = None, None

            if not rec['ok']:
                if rec.get('refused'):
                    counts['refused by both' if real_err else 'refused by stand-in only'] += 1
                    if not real_err:
                        fails['stand-in refused, real server ran it'].append(
                            (test, shape, rec['err'].splitlines()[-1][:200]))
                elif real_err:
                    counts['stand-in could not read; real refused'] += 1
                    fails['real server refused (stand-in could not read it)'].append((test, shape, real_err))
                continue

            if real_err:
                counts['FAIL real refused'] += 1
                fails['real server refused a statement the stand-in ran'].append((test, shape, real_err))
                continue
            counts['ran on both'] += 1

            detail = None
            if 'information_schema' in shape:
                # The stand-in answers these from what it parsed, roughly
                # (no index keys, no collation rows): not compared.
                counts['information_schema, not compared'] += 1
                continue
            if 'rows' in rec and real_rows is not None:
                sim = [] if rec.get('empty') else rec['rows']
                if isinstance(sim, dict):
                    sim = []
                # The stand-in answers every column whatever the SELECT
                # names; only the ones the real server answered are compared.
                names = [d[0] for d in cur.description or []]
                sim = [{c: x.get(c) for c in names} for x in sim]
                if verb == 'SELECT' and 'COUNT(' in shape.upper() and len(real_rows) == 1 and not sim:
                    pass
                elif 'ORDER BY' in shape.upper():
                    s, r = [row_key(x) for x in sim], [row_key(x) for x in real_rows]
                    if s != r:
                        detail = ('order only' if sorted(s) == sorted(r) else 'rows') + \
                                 ': stand-in %d rows, real %d' % (len(s), len(r))
                        if sorted(s) != sorted(r):
                            only_s = set(s) - set(r)
                            only_r = set(r) - set(s)
                            if only_s and only_r:
                                a1, b1 = dict(next(iter(only_s))), dict(next(iter(only_r)))
                                diff = {c: (a1.get(c), b1.get(c)) for c in set(a1) | set(b1)
                                        if a1.get(c) != b1.get(c)}
                                detail += '; first differing columns ' + json.dumps(diff)[:300]
                else:
                    s = collections.Counter(row_key(x) for x in sim)
                    r = collections.Counter(row_key(x) for x in real_rows)
                    if s != r:
                        detail = 'rows: stand-in %d, real %d' % (sum(s.values()), sum(r.values()))
                        only_s, only_r = s - r, r - s
                        if only_s and only_r:
                            a1, b1 = dict(next(iter(only_s))), dict(next(iter(only_r)))
                            diff = {c: (a1.get(c), b1.get(c)) for c in set(a1) | set(b1)
                                    if a1.get(c) != b1.get(c)}
                            detail += '; first differing columns ' + json.dumps(diff)[:300]
            elif 'n' in rec:
                n = rec['n']
                if real_rows is not None:
                    real_n = norm(list(real_rows[0].values())[0]) if real_rows else None
                else:
                    real_n = real_count
                if norm(n) != real_n:
                    detail = 'answer: stand-in %r, real %r' % (n, real_n)
            if detail:
                counts['mismatch'] += 1
                mismatches[test].append((shape, detail))
                if dump:
                    dump.write(json.dumps({'test': test, 'shape': shape, 'detail': detail}) + '\n')
            else:
                counts['agreed'] += 1

    if in_tx:
        conn.rollback()

    # Every shape, prepared against the schema the trace built last. A fresh
    # build of every CREATE / ALTER it sent, in order, comes first.
    drop_all()
    ddl_fail = []
    for sql in ddl:
        try:
            cur.execute(sql)
        except pymysql.MySQLError as e:
            ddl_fail.append((sql.strip().splitlines()[0][:120], str(e.args)))
    prep_fail = []
    for shape in shapes:
        if kind_of(shape) in ('CREATE', 'ALTER'):
            continue
        try:
            cur.execute('PREPARE ch_check FROM %s', (shape,))
            cur.execute('DEALLOCATE PREPARE ch_check')
        except pymysql.MySQLError as e:
            prep_fail.append((shape, '%s %s' % (e.args[0], e.args[1] if len(e.args) > 1 else '')))

    cur.execute("SELECT TABLE_NAME, ENGINE, TABLE_COLLATION FROM information_schema.TABLES "
                "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 'crimson%%' ORDER BY 1")
    tables = cur.fetchall()
    bad_tables = [t for t in tables if t['ENGINE'] != 'InnoDB' or t['TABLE_COLLATION'] != 'utf8mb4_unicode_ci']
    cur.execute("SELECT TABLE_NAME, COLUMN_NAME, CHARACTER_SET_NAME, COLLATION_NAME FROM information_schema.COLUMNS "
                "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 'crimson%%' AND CHARACTER_SET_NAME IS NOT NULL "
                "AND (CHARACTER_SET_NAME <> 'utf8mb4' OR COLLATION_NAME <> 'utf8mb4_unicode_ci')")
    bad_columns = cur.fetchall()

    out = []
    w = out.append
    w('server: %s  sql_mode: %s' % (info['v'], info['m']))
    w('trace: %s' % a.trace)
    for key in sorted(counts):
        w('  %-40s %d' % (key, counts[key]))
    w('distinct statement shapes: %d; prepared: %d failed' % (len(shapes), len(prep_fail)))
    for shape, err in prep_fail:
        w('  PREPARE FAIL  %s\n      %s' % (shape[:300], err))
    w('schema built from the trace\'s CREATE/ALTER (%d statements): %d failed' % (len(ddl), len(ddl_fail)))
    for s, e in ddl_fail:
        w('  DDL FAIL  %s  %s' % (s, e))
    w('tables: %d; not InnoDB/utf8mb4_unicode_ci: %d; text columns not utf8mb4_unicode_ci: %d'
      % (len(tables), len(bad_tables), len(bad_columns)))
    for t in bad_tables:
        w('  TABLE  %r' % t)
    for c in bad_columns:
        w('  COLUMN %r' % c)
    for what, items in fails.items():
        w('FAIL %s: %d' % (what, len(items)))
        seen = set()
        for test, shape, detail in items:
            if (shape, detail) in seen:
                continue
            seen.add((shape, detail))
            if len(seen) > a.show:
                break
            w('  [%s]\n    %s\n    %s' % (test, shape[:400], detail))
    for what, items in warns.items():
        w('WARN %s: %d' % (what, len(items)))
        for test, shape in items[:a.show]:
            w('  [%s] %s' % (test, shape[:300]))
    w('mismatches (rows or counts differ; read, by test): %d in %d tests'
      % (sum(len(v) for v in mismatches.values()), len(mismatches)))
    for test, items in list(mismatches.items()):
        w('  [%s] %d' % (test, len(items)))
        for shape, detail in items[:3]:
            w('      %s\n        %s' % (shape[:200], detail))

    text = '\n'.join(out) + '\n'
    if a.report:
        with open(a.report, 'w', encoding='utf-8') as f:
            f.write(text)
    sys.stdout.write(text)
    failed = bool(fails) or bool(prep_fail) or bool(ddl_fail) or bool(bad_tables) or bool(bad_columns)
    sys.exit(1 if failed else 0)


def shape_of(cur, db):
    """Every crimson_ table of one database: engine, collation, columns, indexes."""
    cur.execute("SELECT TABLE_NAME, ENGINE, TABLE_COLLATION FROM information_schema.TABLES "
                "WHERE TABLE_SCHEMA = %s AND TABLE_NAME LIKE 'crimson%%'", (db,))
    out = {r['TABLE_NAME']: {'engine': r['ENGINE'], 'collation': r['TABLE_COLLATION'],
                             'columns': {}, 'indexes': {}} for r in cur.fetchall()}
    cur.execute("SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, EXTRA, "
                "CHARACTER_SET_NAME, COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = %s "
                "AND TABLE_NAME LIKE 'crimson%%'", (db,))
    for r in cur.fetchall():
        out[r['TABLE_NAME']]['columns'][r['COLUMN_NAME']] = (
            r['COLUMN_TYPE'], r['IS_NULLABLE'], r['COLUMN_DEFAULT'], r['EXTRA'],
            r['CHARACTER_SET_NAME'], r['COLLATION_NAME'])
    cur.execute("SELECT TABLE_NAME, INDEX_NAME, NON_UNIQUE, "
                "GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS cols FROM information_schema.STATISTICS "
                "WHERE TABLE_SCHEMA = %s AND TABLE_NAME LIKE 'crimson%%' GROUP BY 1, 2, 3", (db,))
    for r in cur.fetchall():
        out[r['TABLE_NAME']]['indexes'][r['INDEX_NAME']] = (r['NON_UNIQUE'], r['cols'])
    return out


def migrate(a):
    """An old version's database, at its oldest, migrated as MySQLStore.migrate
    would, and compared with a fresh install."""
    conn = pymysql.connect(unix_socket=a.socket, user=a.user, database=a.database,
                           charset='utf8mb4', autocommit=True, client_flag=CLIENT.FOUND_ROWS,
                           cursorclass=pymysql.cursors.DictCursor)
    cur = conn.cursor()
    cur.execute("SET SESSION sql_mode = CONCAT(@@sql_mode, ',IGNORE_SPACE')")
    ref = shape_of(cur, a.reference)
    old, alters, again = None, [], None
    with open(a.trace, encoding='utf-8') as f:
        for line in f:
            rec = json.loads(line)
            if rec['k'] == 'old':
                old = rec
            elif rec['k'] == 'alter':
                alters.append(rec['sql'])
            elif rec['k'] == 'again':
                again = rec['n']
    out, failed = [], False
    w = out.append
    for name, key in sorted(old['keys'].items()):
        col = ref[name]['columns'][key]
        extra = ' AUTO_INCREMENT' if 'auto_increment' in col[3] else ''
        cols = ['`%s` %s NOT NULL%s PRIMARY KEY' % (key, col[0], extra)]
        renamed = old.get('renamed', {}).get(name, {})
        for was in renamed:
            cols.append('`%s` VARCHAR(16) NOT NULL' % was)
        cur.execute('CREATE TABLE `%s` (%s) ENGINE=MyISAM DEFAULT CHARSET=latin1' % (name, ', '.join(cols)))
        value = '1' if 'int' in col[0] else "'old1'"
        cur.execute('INSERT INTO `%s` (`%s`%s) VALUES (%s%s)' % (
            name, key, ''.join(', `%s`' % c for c in renamed), value,
            ''.join(", 'whole'" for _ in renamed)))
    ran = 0
    for sql in alters:
        try:
            cur.execute(sql)
            ran += 1
        except pymysql.MySQLError as e:
            failed = True
            w('  ALTER FAIL  %s\n      %s' % (sql, e.args))
    got = shape_of(cur, a.database)
    diffs = []
    for name in sorted(set(ref) | set(got)):
        r, g = ref.get(name), got.get(name)
        if not r or not g:
            diffs.append('%s: only in %s' % (name, 'the fresh install' if r else 'the migrated one'))
            continue
        for what in ('engine', 'collation'):
            if r[what] != g[what]:
                diffs.append('%s %s: fresh %s, migrated %s' % (name, what, r[what], g[what]))
        for c in sorted(set(r['columns']) | set(g['columns'])):
            if r['columns'].get(c) != g['columns'].get(c):
                diffs.append('%s.%s: fresh %s, migrated %s' % (name, c, r['columns'].get(c), g['columns'].get(c)))
        for i in sorted(set(r['indexes']) | set(g['indexes'])):
            if r['indexes'].get(i) != g['indexes'].get(i):
                diffs.append('%s index %s: fresh %s, migrated %s' % (name, i, r['indexes'].get(i), g['indexes'].get(i)))
    cur.execute('SELECT line_portion FROM crimson_escrow')
    kept = [x['line_portion'] for x in cur.fetchall()]
    w('migrate: %d tables made as an old version left them (MyISAM, latin1, the key only)' % len(old['keys']))
    w('  ALTERs run: %d of %d; a second migrate would send: %s' % (ran, len(alters), again))
    w('  differences from a fresh install: %d' % len(diffs))
    for d in diffs:
        w('    ' + d)
    w('  crimson_escrow.portion renamed with its value kept: %s' % (kept == ['whole']))
    failed = failed or bool(diffs) or kept != ['whole'] or again != 0
    text = '\n'.join(out) + '\n'
    if a.report:
        with open(a.report, 'w', encoding='utf-8') as f:
            f.write(text)
    sys.stdout.write(text)
    return 1 if failed else 0


def reserved(a):
    """Every keyword this server knows, tried as an unquoted column name: the
    ones it refuses must all be in tests/harness/reserved_words.lua."""
    import subprocess
    lua = ("package.path='./?.lua;'..package.path "
           "for _, w in ipairs(require('tests.harness.reserved_words').mariadb) do print(w) end")
    listed = set(subprocess.check_output(['lua5.4', '-e', lua], text=True).split())
    conn = pymysql.connect(unix_socket=a.socket, user=a.user, database=a.database, charset='utf8mb4')
    cur = conn.cursor()
    try:
        cur.execute('SELECT WORD FROM information_schema.KEYWORDS')
        words = {r[0].upper() for r in cur.fetchall() if re.match(r'^[A-Za-z_][A-Za-z0-9_]*$', r[0])}
    except pymysql.MySQLError:
        words = set()   # MySQL 8 and MariaDB before 10.6: only the list itself is tried
    refused = set()
    for w in sorted(words | listed):
        try:
            cur.execute('CREATE TEMPORARY TABLE ch_rw (%s INT)' % w)
            cur.execute('DROP TEMPORARY TABLE ch_rw')
        except pymysql.MySQLError:
            refused.add(w)
    missing = sorted(refused - listed)
    print('  keywords tried: %d; refused as a column name: %d; listed: %d'
          % (len(words | listed), len(refused), len(listed)))
    print('  refused here but not listed: %s' % (', '.join(missing) or 'none'))
    print('  listed but taken here (other versions\' words): %s' % (', '.join(sorted(listed - refused)) or 'none'))
    return 1 if missing else 0


if __name__ == '__main__':
    main()
