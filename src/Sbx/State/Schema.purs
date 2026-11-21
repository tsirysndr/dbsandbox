module Sbx.State.Schema where

import Drizzle.Dialect (SQLite)
import Drizzle.Schema (Table, Column, notNull, primaryKey)
import Drizzle.SQLite.Schema as S

type StateColumns =
  ( tool :: Column SQLite String
  , database :: Column SQLite String
  , os :: Column SQLite String
  , version :: Column SQLite String
  , port :: Column SQLite Int
  , user :: Column SQLite String
  , password :: Column SQLite String
  , db :: Column SQLite String
  , branch :: Column SQLite String
  , cpus :: Column SQLite Int
  , mem :: Column SQLite Int
  )

states :: Table SQLite StateColumns
states = S.table "sandboxes"
  { tool: primaryKey (notNull (S.text "tool"))
  , database: notNull (S.text "database")
  , os: notNull (S.text "os")
  , version: notNull (S.text "version")
  , port: notNull (S.integer "port")
  , user: notNull (S.text "user")
  , password: notNull (S.text "password")
  , db: notNull (S.text "db")
  , branch: notNull (S.text "branch")
  , cpus: notNull (S.integer "cpus")
  , mem: notNull (S.integer "mem")
  }

selections :: Table SQLite (tool :: Column SQLite String, branch :: Column SQLite String)
selections = S.table "selections" { tool: primaryKey (notNull (S.text "tool")), branch: notNull (S.text "branch") }

branches :: Table SQLite (tool :: Column SQLite String, parent :: Column SQLite String, name :: Column SQLite String, running :: Column SQLite Boolean)
branches = S.table "branches" { tool: primaryKey (notNull (S.text "tool")), parent: notNull (S.text "parent"), name: notNull (S.text "name"), running: notNull (S.integerBoolean "running") }

imports :: Table SQLite (tool :: Column SQLite String)
imports = S.table "legacy_imports" { tool: primaryKey (notNull (S.text "tool")) }
