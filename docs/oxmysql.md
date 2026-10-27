# oxmysql: how it behaves, as crimson-hitman's mysql store relies on it

This is the reference the mysql store (`crimson-hitman/server/storage/mysql.lua`) and the
test harness that stands in for oxmysql (`tests/harness/mysql_exec.lua`,
`natives.lua`, `await_scheduler.lua`) cite as `docs/oxmysql.md §N`. Each section says what
oxmysql does, so a comment that leans on it can be checked here.

## 0. Version and how it was checked

* **OX**: overextended/oxmysql, tag `v2.14.3` (commit `bae715c`). Paths below are in its source.
* **M2**: mysql2 3.24.5, with oxmysql's `patches/mysql2@3.24.5.patch` applied.
* **NP**: named-placeholders 1.1.6, with oxmysql's patch applied.
* **SE**: sql-escaper 1.5.2, the version oxmysql's `bun.lock` pins (mysql2's query formatter).
* **FX**: citizenfx/fivem `data/shared/citizen/scripting/lua/scheduler.lua` and `deferred.lua`
  (the Lua scheduler and promises), and `.../v8/main.js` (the JS runtime).

Behaviour marked **[run]** was observed by running the real oxmysql 2.14.3 source (bundled
as its own build bundles it) under node 22 against MariaDB 10.11.14, through its exports,
with the FiveM globals shimmed and Lua tables sent as FiveM's msgpack sends them. Marked
**[src]**: read from the source only. To check a claim again, read the cited lines in that
version, or run the same call against a scratch database.

---

## 1. The call path

* `MySQL[method].await(sql, params)` calls the export
  `oxmysql[method](nil, sql, params, function(result, error) ... end, resourceName, true)` and
  then `Citizen.Await(p)` (OX `lib/MySQL.lua:15-27, 87-97`). The callback rejects the promise
  when `error` is set, else resolves it with `result`.
* A plain call `MySQL[method](sql, params, cb)` does not wait. It passes `isPromise` as the
  resource's `mysql_option 'return_callback_errors'`, which is off unless the fxmanifest sets
  it (OX `lib/MySQL.lua:6-13, 72-77`).
* The exports return at once; the answer only ever comes through `cb` (OX `src/index.ts:20-102`).
* A call made before oxmysql has a pool waits in `while (!pool) await sleep(0)`
  (OX `src/database/connection.ts:71-72`).
* Lua to JS: a Lua table whose keys are exactly 1..n is a JS array; a table with a nil hole
  is a msgpack map and arrives as a JS object `{"1": a, "3": c}` (FX `scheduler.lua:30-34`,
  lua-cmsgpack `set_array('without_hole')`). `{}` is `[]`.
* JS to Lua: `null`/`undefined` become `nil`, so a NULL column is a key absent from the row;
  an integer within int32 is a Lua integer, any other number a Lua float.

## 2. Placeholders

On `query`, `single`, `scalar`, `update`, `insert` and `transaction` (OX
`src/utils/parseArguments.ts:4-37`), formatted on the client by sql-escaper:

| Case | Behaviour |
|---|---|
| `?` with an array | Positional. Fewer values than `?`: the rest are NULL. More values: raises `Expected N parameters, but received M.` before anything is sent, without yielding. [run] |
| `?` with an object (a Lua table with a hole) | Each `?` takes `params[i + 1] ?? null`: the hole is NULL, extra keys are ignored. [run] |
| `@name` / `:name` | Converted only when the parameters are an **object** and the SQL text holds `:` or `@` anywhere (OX `parseArguments.ts:7-10`). [run] |
| An object and any `:` or `@` in the SQL, even in a `--` comment or a string literal | The named path numbers each `?` from 0 (NP `index.js:50`), so the first `?` gets NULL and every other one the value meant for the one before it. No error. An array with the same SQL is unaffected. [run] |
| nil | NULL. |
| boolean | `true` / `false`, stored as 1 / 0, never NULL (SE). |
| a sequence table as one value | Expanded to `a, b, c`: right for `IN (?)` only. |

This resource's SQL never holds `:` or `@` (a rule in `tests/static_check.lua`),
because about twenty of its writes send tables with holes.

## 3. Return shapes

`parseResponse` (OX `src/utils/parseResponse.ts:4-22`). [run]

| Method | Returns |
|---|---|
| `query` SELECT | An array of rows (`{}` when none). |
| `query` INSERT/UPDATE/DELETE | The result header `{ affectedRows, insertId, ... }`. |
| `scalar` | The first column of the first row, or nil (`0` and `false` survive). |
| `insert` | `insertId`; 0 on a table without AUTO_INCREMENT. |
| `update` | `affectedRows`, **matched rows, not changed rows**: mysql2 connects with `FOUND_ROWS` by default (M2 `lib/connection_config.js:286-289`). `UPDATE t SET s = s` answers 1. A DELETE answers the rows deleted. |
| `transaction` | `true` after COMMIT; **`false`** when any statement fails, after a ROLLBACK, with the error printed. It does **not** raise for an SQL error (OX `src/database/rawTransaction.ts:35-91`). It does raise for malformed input (not an array; more values than `?`). A statement matching no row does not fail it. [src] `false` also comes back when COMMIT was sent and its answer was lost, so false does not prove nothing landed. |

## 4. What a column comes back as

Through `query` and the others (OX `src/utils/typeCast.ts:30-71`). [run]

* `TINYINT(1)` / `BOOLEAN`: a boolean, `true` only for 1 (2 reads as false).
* `INT`: a number. `BIGINT`: a number up to 2^53, else a string. `COUNT(*)`: a number.
* `DECIMAL`, `SUM(int)`, `AVG()`: a **string**.
* `DATETIME` / `TIMESTAMP`: milliseconds, read in the FXServer process's time zone.
* `JSON` and `TEXT`: a string, not decoded.

This store's schema uses `INT`, `VARCHAR`, `TEXT` and `TINYINT(1)` only, and reads `COUNT(*)`
through `tonumber`, so none of the string or millisecond shapes reach it.

## 5. Errors

| Situation | What happens |
|---|---|
| SQL error under `.await` (syntax, duplicate key, strict-mode `Data too long`, `Column 'x' cannot be null`, `Out of range value`) | The callback gets `(nil, message)`, the promise is rejected and `Citizen.Await` **raises** (FX `scheduler.lua:85-99`). oxmysql prints nothing itself. The message is `"<resource> was unable to execute a query!\nQuery: <sql>\n<params as JSON>\n<server message>"` (OX `src/logger/index.ts:35-37`): every parameter value is in it. [run] |
| A parse error (too many `?` values) | Raised at once, without yielding. [run] |
| SQL error on a plain call (no `return_callback_errors`) | Printed with `console.error`; **the callback is never called**. [run] |
| SQL error in a transaction | Answers `false`, prints `"<resource> was unable to complete a transaction!..."`, rolls back. [run] |
| Session `sql_mode` | MariaDB's default plus mysql2's `IGNORE_SPACE`: `STRICT_TRANS_TABLES` among them, so an overlong string, an INT past -2^31..2^31-1, a TEXT past 65,535 bytes and a NULL in a NOT NULL column are **refused**, never cut short or wrapped. [run] |

## 6. While the database is down

**At start.** oxmysql tries once, prints `Unable to establish a connection to the database`,
then retries every 30 s for good (OX `src/database/index.ts:5-12`, `pool.ts:28-44`). Every
statement issued meanwhile **waits, with no error and no timeout**, and is answered at the
retry that connects. [run]

**Mid-run, once the pool exists: awaits are never answered.** `getConnection()` runs outside
the `try` in `rawQuery.ts:29` (and in `rawExecute.ts:34`, `rawTransaction.ts:31`). When mysql2
cannot open a connection the export's promise rejects, **`cb` is never called**, and FXServer
prints only an unhandled rejection (FX `v8/main.js:443-470`). [run]

| Scenario | `.await` outcome |
|---|---|
| MariaDB stopped; then `query`, `update`, `transaction` | Never answered. `isReady()` still says true. |
| Issued while down, database back 1.5 s later | Still never answered: a lost call does not come back. |
| A fresh call after the database is back | Answered: the pool recovers by itself. |
| A statement in flight when MariaDB is killed | Raises `Connection lost: The server closed the connection.` It may or may not have committed. |
| The network stops answering, an idle pooled connection reused | Never answered: oxmysql passes no query timeout and mysql2 has none. |

In Lua a coroutine parked in `Citizen.Await` on a promise that never settles is never resumed:
not an error, so a `pcall` around it never returns either (FX `scheduler.lua:85-99`). This is
why the store races every statement against `Config.Database.QueryTimeoutSeconds`, and why a
statement given up on may still land later.

## 7. Every await yields

`Citizen.Await` yields when the promise is still pending, and a successful query's callback
always arrives on a later JS tick, so **every** `.await` yields its coroutine, every time; only
a parse error raises without yielding (FX `scheduler.lua:85-99`, `465-511`). [run]

Meanwhile anything else in the resource may run to its own next yield: other net events (each
its own thread), the `CreateThread` loops, timers, commands, exports called by other
resources. Lua state read before an await can be stale after it.

A plain `MySQL.insert(sql, params)` with no `.await` does not yield; the statement runs inside
oxmysql whatever happens to the caller (OX `src/index.ts:60-68`).

## 8. Pool and concurrency

* mysql2's pool: 10 connections, an unbounded queue (M2 `lib/pool_config.js:11-30`).
* Two awaits run at once on different connections and finish in completion order, not call
  order. [run]
* One coroutine's awaits usually land on the same connection, by luck, not by guarantee: never
  rely on session state (user variables, `LAST_INSERT_ID()`, `GET_LOCK`) across two awaits.
  This store uses none.
* Each `.await` is its own autocommit transaction; only `transaction` groups statements.

## 9. `mysql_connection_string`

Every option value is a string, so `?multipleStatements=false` turns multiple statements ON
(`"false"` is truthy) [run]. `connectTimeout` (oxmysql's default 60 s) covers opening a
connection only; there is no query timeout anywhere. `flags=["-FOUND_ROWS"]` would make
`update` answer changed rows instead of matched ones [src].

## 10. What oxmysql prints

* A statement slower than `mysql_slow_query_warning` (200 ms by default) is printed **with its
  full SQL and every parameter value** (OX `src/logger/index.ts:78-93`). [run]
* A result of 1,000 rows or more: `executed a query with an oversized result set`
  (OX `src/utils/validateResultSet.ts`). [run]

## 11. What this store relies on

* Every `db.*` call yields (§7) and is bounded by `Config.Database.QueryTimeoutSeconds` (§6).
* A failed statement raises (§5); a failed transaction answers false (§3).
* `update` answers matched rows (§3): a compare-and-set `UPDATE ... WHERE id = ? AND state = ?`
  answers 1 only when the row was in that state, and an `UPDATE` setting what is already there
  answers 1 too.
* NULL is a missing key and `TINYINT(1)` a boolean (§1, §4).

## 12. Assumptions that differ from oxmysql

1. **"An await returns or raises."** Not during an outage (§6): a statement that needs a new
   connection while MariaDB cannot be reached is never answered, and a `pcall` cannot catch it.
   The store races each statement against a timeout and treats one given up on as one that may
   still land.
2. **A table with a hole plus a `:` or `@` in the SQL** shifts every value one column (§2), with
   no error. Kept out by the static check.
3. **A stand-in that raises on a failed transaction, keeps the statements before it, stores
   values strict mode refuses, or never yields** is not oxmysql (§3, §5, §7). The harness
   (`mysql_exec.lua`, `await_scheduler.lua`) is held to this file.
4. **Matched rows** (§3): an `UPDATE` that changes nothing still answers 1.
5. **A failed read answers nothing**: it raises (§5).
6. **A plain call with no `.await`** (the audit's and the alerts' writes while the resource stops) is not waited for: a failure
   is only printed by oxmysql and the row is lost; several run at once, so their order may not
   be the call order (§5, §8).
7. **Console exposure.** oxmysql's error message (§5) and its slow-query line (§10) carry every
   parameter value: citizen ids, character names, reasons, message bodies. Anything this
   resource prints or stores from an error is cut to the statement's start and the server's own
   words, never its parameters.
8. **A thousand rows** in one result prints oxmysql's oversized-result warning (§10).
9. **Session state across awaits** is not guaranteed (§8).
10. **Lua `false` as a parameter is 0, not NULL** (§2): bind `nil` for NULL.
11. **A start with the database down** waits silently until oxmysql's next 30 s retry (§6).
