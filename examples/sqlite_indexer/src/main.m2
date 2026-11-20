///| sqlite_indexer <dir> <db>: indexes every `.m2` / `.mbt` file under <dir>
///| (lines, bytes, `pub fn` count, SHA-256) into a SQLite database through
///| pure-m2 libsqlite3 bindings, then prints the query results as JSON.

import "json"

/// The JSON report printed on success.
pub struct Report {
  sqlite_version : String
  root : String
  db : String
  indexed : Int
  totals : Totals
  top : Array[TopFile]
  scan_ms : Int64
  db_ms : Int64
}

impl json::ToJson for Report {
  fn to_json(self : Report) -> json::JsonValue {
    let top : Array[json::JsonValue] = []
    for t in self.top {
      top.push(t.to_json())
    }
    json::JObj([
      json::field("sqlite_version", json::JStr(self.sqlite_version)),
      json::field("root", json::JStr(self.root)),
      json::field("db", json::JStr(self.db)),
      json::field("indexed", json::JInt(self.indexed.to_int64())),
      json::field("totals", self.totals.to_json()),
      json::field("top", json::JArr(top)),
      json::field("scan_ms", json::JInt(self.scan_ms)),
      json::field("db_ms", json::JInt(self.db_ms)),
    ])
  }
}

fn scan(world : World, root : String) -> Result[Array[FileRow], String] {
  let paths : Array[String] = []
  collect_sources(world, root, paths)
  let rows : Array[FileRow] = []
  for p in paths {
    match fs_read(world, p) {
      Ok(text) => rows.push(file_row(p, text))
      Err(e) => return Err("read " + p + ": " + e)
    }
  }
  Ok(rows)
}

fn index_into(db : Db, rows : Array[FileRow]) -> Result[(Totals, Array[TopFile]), String] {
  create_schema(db)?
  insert_rows(db, rows)?
  let totals = query_totals(db)?
  let top = query_top(db)?
  Ok((totals, top))
}

fn run(world : World, root : String, db_path : String) -> Result[Report, String] {
  if !fs_is_dir(world, root) {
    return Err("not a directory: " + root)
  }
  let t0 = clock_now_ms(world)
  let rows = scan(world, root)?
  let t1 = clock_now_ms(world)
  let db = db_open(db_path)?
  let res = index_into(db, rows)
  let closed = db_close(db)
  let (totals, top) = res?
  closed?
  let t2 = clock_now_ms(world)
  if totals.files != rows.length().to_int64() {
    return Err(
      "row count mismatch: scanned " +
      rows.length().to_string() +
      ", table has " +
      totals.files.to_string(),
    )
  }
  Ok(Report::{
    sqlite_version: sqlite_version(),
    root: root,
    db: db_path,
    indexed: rows.length(),
    totals: totals,
    top: top,
    scan_ms: t1 - t0,
    db_ms: t2 - t1,
  })
}

pub fn main(world : World) -> Int {
  let args = world_args(world)
  if args.length() != 3 {
    io_eprintln(world, "usage: sqlite_indexer <dir> <db>")
    return 2
  }
  match run(world, args[1], args[2]) {
    Ok(rep) => {
      io_println(world, json::encode(rep))
      0
    }
    Err(e) => {
      io_eprintln(world, json::stringify(json::JObj([json::field("error", json::JStr(e))])))
      1
    }
  }
}
