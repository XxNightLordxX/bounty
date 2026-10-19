# Kill photos

Kill photos kept on this server (`Config.Completion.PhotoStorage = 'server'`,
the default) are written here, one file per photo, named for the photo's own
handle. This folder ships with the resource because FiveM's
`SaveResourceFile` writes a file but does not create the folder above it.

Every file here is a photograph of somebody's corpse, seen by nobody but the
client who placed the contract, once. They are deleted when the client
deletes the photo, leaves it open too long, never opens it, or it is
otherwise let go of, and each start removes any file no photo record names.
Files this resource did not name (this one, for instance) are left alone.

Two kinds stay longer, on purpose. A photo the client saved to their phone's
Photos through a link this server serves (`/crimson-hitman/p/<name>`) stays
here for as long as their Photos keeps it. A photo their phone could not
take at all is kept for them in the app, and moves to `kept/` (or, where
that folder cannot be made, gets a `kept-` name here) until they delete it,
or `Config.Completion.KeptPhotoDays` runs out. `/ch-diag` says how many of
each there are and how much space they take.
