# Data directory

This directory exists so that `Config.Database.Mode = 'json'` works on a
fresh install.

FiveM's `SaveResourceFile` writes a file; it does **not** create the
directories above it. Without `data/` and `data/contracts/` already present,
every write fails silently — escrow would be taken from players and never
recorded, and a restart would lose it. The resource refuses to start in json
mode rather than run that way, and the message names this directory.

`store.json` holds the index — the sequence, which contracts have a file,
which days have an audit file, and whether `records.json` has been written.
`records.json` holds the records: the ledger, pending payouts (money owed to
players who were offline), the stats, the informant reveals, the kill photo
records (a handle, a state and at most a link or the name of a file in
`photos/` each, never an image), the review queue (money events no rule
could settle, kept until staff resolve them with `/ch-review`) and the
settings staff changed from the admin panel (`/hitmanadmin`), applied over
`config.lua` at every start. It is written
only when one of those changes, so a money write never rewrites the history
it carries; a `store.json` from an older version that still holds them is
moved into it on the first start. `contracts/<id>.json` holds one contract
each, with its escrow, hitmen, amendments and messages, so a write touches
only the contract that changed. `store.json.prev` and `records.json.prev` are
those two files as the last start read them: a missing or unreadable
`store.json` or `records.json` stops the start rather than lose what they
held, and these are what to restore from. `heartbeat.json` is when the server
was last seen running; where a crash left it empty, a start dates the
downtime from its last whole copy, else from the newest audit row or the time
`store.json` was last written, and says so in the console.

Each of `store.json`, `records.json`, `contracts/<id>.json`, `heartbeat.json`
and a day's audit file, when it is written whole, is written as `<file>.new`
and then renamed over `<file>`, so a crash part-way through a write tears the
copy and never the file. On Windows, where a rename will not replace a file,
`<file>` is moved aside to `<file>.old` for the moment the rename takes and
removed after it. A start that finds one of them missing or torn, with a
whole `.new` or `.old` beside it, puts that back, keeps a torn one as
`<file>.torn`, and says so in the console; only where there is no whole copy
does it stop or set the contract aside as described above. A `.new` or `.old`
beside a good file is a write that never finished, and is left alone, with
one exception: a whole `store.json.new` at least as new as `store.json` (its
`seq` no lower) is the index a new contract was being named in when the
server stopped, so it is used and put in place, and the console says so. On
a server that cannot rename files here, each is written in place after its
whole `.new` copy, which then stays beside it for a start to put back, and
the console says so once.

A start also lists `contracts/` (where the server build can list a folder).
A contract's file that `store.json` does not name and that holds escrow not
yet settled, or a contract still running, is what a crash between writing a
new contract and naming it leaves: it is taken back in, and the console
names it. Any other file there that the index does not name (a finished
contract a prune had not yet removed) is left exactly where it is; nothing
here is ever deleted for not being named. To drop a contract for good, take
its id out of `store.json` and move its file out of `contracts/` too.

A contract file that could not be written (one held open by a backup tool,
an antivirus or an editor) is kept in memory and tried again at every flush,
while every other contract is still written; the console names it at most
once every five minutes until it lands.

`audit-<day>.jsonl` holds the audit log, one file per day (UTC) and one row
per line. The flush adds new rows to the end of the day's file, and a money
write never touches it. A day's file is deleted once the whole day is older
than `Config.Audit.RetentionDays`. A `store.json` from an older version that
still holds the log is moved into these files on the first start. If a
day's file is named in `store.json` but reads back empty at a start, it is
left untouched (the read may have failed) and that day's new rows go to
`audit-<day>.1.jsonl` beside it; both are read at every start.

Nothing above is needed in `mysql` or `memory` mode.

**Keep this folder when you update the resource**, in every mode. Deleting
the old resource folder and extracting the new one deletes it with it: in
`json` mode that is the whole store, every open contract's escrow included,
and in every mode `photos/` holds the kill photos kept for clients and the
files behind links in players' Photos. Copy the new version over the old
folder, or move `data/` aside and back. In `json` mode the server also
remembers, outside this folder, that the store has run, and refuses to start
on an empty one rather than start empty without a word (see the README,
*Updating*).

`photos/` holds the kill photos kept on this server
(`Config.Completion.PhotoStorage = 'server'`, the default), in **every**
database mode: one file each, named for the photo's own handle
(`ph….webp`, `.jpg` or `.png`), written when a kill is verified and deleted
when the client deletes it, leaves it open too long, never opens it, or it
is otherwise let go of. One saved to the client's phone through a link this
server serves stays while their Photos keeps it, and one kept for them in
the app moves to `photos/kept/` until they delete it. The server must be
able to write here; it creates the folders if it can, and `photos/` ships
with this resource for a server build that cannot. Each start removes any
photo file no record names. `photos/.mode` says which storage mode's records
name the files: after `Config.Database.Mode` is switched, the files are left
alone (the other store still names them) until the mode is switched back or
`.mode` is deleted. Back
it up with the rest of `data/` only if you mean to keep photos across a
restore; in `memory` mode every photo is forgotten at a restart, and the
files go with it at the next start.
