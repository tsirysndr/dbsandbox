-- | Table rows are checked against the declared schema. A PostgreSQL table
-- | cannot be passed to these SQLite-only, synchronous operations.
module Drizzle.Query (class TableRow, class TableRowList, select, upsert, deleteWhere) where

import Prelude
import Drizzle.Database (Database)
import Drizzle.Dialect (SQLite)
import Drizzle.Schema (Table, Column)
import Drizzle.SQL (SQL)
import Effect (Effect)
import Prim.Row as Row
import Prim.RowList (class RowToList, RowList, Cons, Nil)

class TableRow (cols :: Row Type) (row :: Row Type) | cols -> row

instance (RowToList cols cl, TableRowList cl row) => TableRow cols row

class TableRowList (cols :: RowList Type) (row :: Row Type) | cols -> row

instance TableRowList Nil ()
instance (TableRowList tail rest, Row.Cons name a rest row) => TableRowList (Cons name (Column SQLite a) tail) row

foreign import selectImpl :: forall cols row. Database SQLite -> Table SQLite cols -> SQL -> Effect (Array (Record row))

select :: forall cols row. TableRow cols row => Database SQLite -> Table SQLite cols -> SQL -> Effect (Array (Record row))
select = selectImpl

foreign import upsertImpl :: forall cols row. Database SQLite -> Table SQLite cols -> Record row -> Effect Unit

-- | Conflict handling uses the table's primary key and updates the full row.
upsert :: forall cols row. TableRow cols row => Database SQLite -> Table SQLite cols -> Record row -> Effect Unit
upsert = upsertImpl

foreign import deleteWhere :: forall cols. Database SQLite -> Table SQLite cols -> SQL -> Effect Unit
