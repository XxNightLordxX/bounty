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
or the name of a file in `photos/` each, never an image).
`contracts/<id>.json` holds one contract each, with its escrow, hitmen,
amendments and messages, so a write touches only the contract that
changed.

`audit-<day>.jsonl` holds the audit log, one file per day (UTC) and one row
per line. The flush adds new rows to the end of the day's file, and a money
write never touches it. A day's file is deleted once the whole day is older
than `Config.Audit.RetentionDays`. A `store.json` from an older version that
still holds the log is moved into these files on the first start. If a
day's file is named in `store.json` but reads back empty at a start, it is
left untouched (the read may have failed) and that day's new rows go to
`audit-<day>.1.jsonl` beside it; both are read at every start.

Nothing above is needed in `mysql` or `memory` mode.

`photos/` holds the kill photos kept on this server
(`Config.Completion.PhotoStorage = 'server'`, the default), in **every**
database mode: one file each, named for the photo's own handle
(`ph….webp`, `.jpg` or `.png`), written when a kill is verified and deleted
when the client deletes it, leaves it open too long, never opens it, or it
is otherwise let go of. The server must be able to write here; it creates
the folder if it can, and the folder ships with this resource for a server
build that cannot. Each start removes any photo file no record names. Back
it up with the rest of `data/` only if you mean to keep photos across a
restore; in `memory` mode every photo is forgotten at a restart, and the
files go with it at the next start.
