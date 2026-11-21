# Drizzle bindings

Local PureScript package following `rocksky/purescript/packages/drizzle`:
phantom dialect types, typed column/schema records, SQL fragments with bound
parameters, and schema-checked select/upsert rows. The shared Dialect, Schema,
SQL and SQLite.Schema modules follow those bindings. The Bun SQLite driver and
query operations are synchronous `Effect` functions; SQLite transactions cannot
accept an asynchronous callback accidentally.

`Drizzle.Database.all` is the low-level SQL escape hatch: callers must annotate
its result shape to match their SELECT projection. Prefer `Drizzle.Query.select`
for ordinary table queries. Only SQL literals belong in `raw`; user values use
`param` and `template`.
