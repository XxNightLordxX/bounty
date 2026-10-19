# Data directory

This directory exists so that `Config.Database.Mode = 'json'` works on a
fresh install.

FiveM's `SaveResourceFile` writes a file; it does **not** create the
directories above it. Without `data/` and `data/contracts/` already present,
every write fails silently — escrow would be taken from players and never
recorded, and a restart would lose it. The resource refuses to start in json
mode rather than run that way, and the message names this directory.

`store.json` holds the index — the sequence, the ledger, pending payouts,
the stats and the kill photo records (a handle, a state and at most a link
each, never an image). `contracts/<id>.json` holds one contract each, with its
escrow, hitmen, amendments and messages, so a write touches only the
contract that changed.

`audit-<day>.jsonl` holds the audit log, one file per day (UTC) and one row
per line. The flush adds new rows to the end of the day's file, and a money
write never touches it. A day's file is deleted once the whole day is older
than `Config.Audit.RetentionDays`. A `store.json` from an older version that
still holds the log is moved into these files on the first start. If a
day's file is named in `store.json` but reads back empty at a start, it is
left untouched (the read may have failed) and that day's new rows go to
`audit-<day>.1.jsonl` beside it; both are read at every start.

Nothing here is needed in `mysql` or `memory` mode.
