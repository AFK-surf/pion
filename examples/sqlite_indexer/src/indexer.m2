///| Source file statistics and the SQLite schema / queries of the index.

import "json"

/// One indexed source file.
pub struct FileRow {
  path : String
  lines : Int
  bytes : Int
  pub_fns : Int
  sha256 : String
}

/// One row of the "largest files" query.
pub struct TopFile {
  path : String
  lines : Int64
  pub_fns : Int64
}

/// Aggregates over the whole `files` table.
pub struct Totals {
  files : Int64
  lines : Int64
  bytes : Int64
}

impl json::ToJson for TopFile {
  fn to_json(self : TopFile) -> json::JsonValue {
    json::JObj([
      json::field("path", json::JStr(self.path)),
      json::field("lines", json::JInt(self.lines)),
      json::field("pub_fns", json::JInt(self.pub_fns)),
    ])
  }
}

impl json::ToJson for Totals {
  fn to_json(self : Totals) -> json::JsonValue {
    json::JObj([
      json::field("files", json::JInt(self.files)),
      json::field("lines", json::JInt(self.lines)),
      json::field("bytes", json::JInt(self.bytes)),
    ])
  }
}

pub let SCHEMA_SQL : String = "DROP TABLE IF EXISTS files; CREATE TABLE files (path TEXT PRIMARY KEY, lines INTEGER NOT NULL, bytes INTEGER NOT NULL, pub_fns INTEGER NOT NULL, sha256 TEXT NOT NULL)"
pub let INSERT_SQL : String = "INSERT INTO files (path, lines, bytes, pub_fns, sha256) VALUES (?, ?, ?, ?, ?)"
pub let TOTALS_SQL : String = "SELECT COUNT(*), SUM(lines), SUM(bytes) FROM files"
pub let TOP_SQL : String = "SELECT path, lines, pub_fns FROM files ORDER BY lines DESC, path ASC LIMIT 5"

/// Number of lines (`\n`-terminated, plus a final unterminated one), as `wc -l`
/// counts them for newline-terminated files.
pub fn count_lines(text : String) -> Int {
  let n = text.length()
  let mut lines = 0
  let mut i = 0
  while i < n {
    if text.code_unit_at(i) == 10 {
      lines = lines + 1
    }
    i = i + 1
  }
  if n > 0 && text.code_unit_at(n - 1) != 10 {
    lines = lines + 1
  }
  lines
}

/// Number of lines whose first non-blank text is `pub fn `.
pub fn count_pub_fns(text : String) -> Int {
  let n = text.length()
  let mut count = 0
  let mut at_line_start = true
  let mut i = 0
  while i < n {
    let c = text.code_unit_at(i)
    if c == 10 {
      at_line_start = true
      i = i + 1
    } else if at_line_start && (c == 32 || c == 9) {
      i = i + 1
    } else {
      if at_line_start && i + 7 <= n && text.slice(i, i + 7) == "pub fn " {
        count = count + 1
      }
      at_line_start = false
      i = i + 1
    }
  }
  count
}

/// Statistics of one file's contents.
pub fn file_row(path : String, text : String) -> FileRow {
  FileRow::{
    path: path,
    lines: count_lines(text),
    bytes: text.length(),
    pub_fns: count_pub_fns(text),
    sha256: sha256_hex(text),
  }
}

fn is_indexed_source(name : String) -> Bool {
  name.ends_with(".m2") || name.ends_with(".mbt")
}

/// Every `.m2` / `.mbt` file under `dir` (recursively, sorted), skipping dot entries.
pub fn collect_sources(world : World, dir : String, out : Array[String]) -> Unit {
  let entries = fs_list_dir(world, dir)
  for name in entries {
    if name.length() == 0 || name.code_unit_at(0) == 46 {
      continue
    }
    let p = dir + "/" + name
    if fs_is_dir(world, p) {
      collect_sources(world, p, out)
    } else if is_indexed_source(name) {
      out.push(p)
    }
  }
}

/// Creates the `files` table (replacing an old one).
pub fn create_schema(db : Db) -> Result[Unit, String] {
  db_exec(db, SCHEMA_SQL)
}

/// Inserts `rows` with one parameterized statement inside a single transaction.
pub fn insert_rows(db : Db, rows : Array[FileRow]) -> Result[Unit, String] {
  db_exec(db, "BEGIN")?
  let st = db_prepare(db, INSERT_SQL)?
  for r in rows {
    let res = insert_one(st, r)
    match res {
      Ok(_) => ()
      Err(e) => {
        stmt_finalize(st)
        let _ = db_exec(db, "ROLLBACK")
        return Err(e)
      }
    }
  }
  stmt_finalize(st)
  db_exec(db, "COMMIT")
}

fn insert_one(st : Stmt, r : FileRow) -> Result[Unit, String] {
  stmt_bind_text(st, 1, r.path)?
  stmt_bind_int64(st, 2, r.lines.to_int64())?
  stmt_bind_int64(st, 3, r.bytes.to_int64())?
  stmt_bind_int64(st, 4, r.pub_fns.to_int64())?
  stmt_bind_text(st, 5, r.sha256)?
  let more = stmt_step(st)?
  if more {
    return Err("INSERT unexpectedly returned a row")
  }
  stmt_reset(st)
}

/// `SELECT COUNT(*), SUM(lines), SUM(bytes) FROM files`.
pub fn query_totals(db : Db) -> Result[Totals, String] {
  let st = db_prepare(db, TOTALS_SQL)?
  let res = match stmt_step(st) {
    Ok(true) =>
    Ok(Totals::{
      files: stmt_column_int64(st, 0),
      lines: stmt_column_int64(st, 1),
      bytes: stmt_column_int64(st, 2),
    })
    Ok(false) => Err("totals query returned no row")
    Err(e) => Err(e)
  }
  stmt_finalize(st)
  res
}

/// The five longest files (ties broken by path).
pub fn query_top(db : Db) -> Result[Array[TopFile], String] {
  let st = db_prepare(db, TOP_SQL)?
  let out : Array[TopFile] = []
  while true {
    match stmt_step(st) {
      Ok(true) =>
      out.push(TopFile::{
        path: stmt_column_text(st, 0),
        lines: stmt_column_int64(st, 1),
        pub_fns: stmt_column_int64(st, 2),
      })
      Ok(false) => break
      Err(e) => {
        stmt_finalize(st)
        return Err(e)
      }
    }
  }
  stmt_finalize(st)
  Ok(out)
}
