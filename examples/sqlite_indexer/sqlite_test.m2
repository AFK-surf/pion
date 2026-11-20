///| sqlite_indexer tests: real libsqlite3 on an in-memory database.

fn mem_db() -> Db {
  match db_open(":memory:") {
    Ok(db) => db
    Err(e) => {
      debug_assert(false, "open :memory: " + e)
      Db::{ handle: ptr_null() }
    }
  }
}

fn ok_unit(r : Result[Unit, String], what : String) -> Unit {
  match r {
    Ok(_) => ()
    Err(e) => {
      debug_assert(false, what + ": " + e)
    }
  }
}

test "libsqlite3 is linked" {
  let v = sqlite_version()
  debug_assert(v.starts_with("3."), "sqlite version " + v)
}

test "file statistics" {
  debug_assert(count_lines("") == 0, "empty")
  debug_assert(count_lines("a\nb\n") == 2, "terminated")
  debug_assert(count_lines("a\nb") == 2, "unterminated last line")
  let src = "pub fn a() -> Unit {}\n  pub fn b() -> Unit {}\nfn c() -> Unit {}\n// pub fn d\nlet x = \"pub fn e\"\n"
  debug_assert(count_pub_fns(src) == 2, "pub fn count " + count_pub_fns(src).to_string())
  let r = file_row("x.m2", "abc")
  debug_assert(r.bytes == 3 && r.lines == 1, "row stats")
  debug_assert(
    r.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    "sha256 " + r.sha256
  )
  // Non-ASCII text: byte length and hash cover the UTF-8 bytes.
  let u = file_row("u.m2", "键值\n")
  debug_assert(u.bytes == 7 && u.lines == 1, "utf8 bytes " + u.bytes.to_string())
}

test "create, insert, query and clean up in :memory:" {
  let db = mem_db()
  ok_unit(create_schema(db), "schema")
  let rows = [
    file_row("a.m2", "pub fn a() -> Int {\n  1\n}\n"),
    file_row("b.mbt", "x\n"),
    file_row("c.m2", "pub fn c() -> Unit {}\npub fn d() -> Unit {}\n// 注释\n\n"),
  ]
  ok_unit(insert_rows(db, rows), "insert")
  match query_totals(db) {
    Ok(t) => {
      debug_assert(t.files == 3L, "files " + t.files.to_string())
      debug_assert(t.lines == 8L, "lines " + t.lines.to_string())
      debug_assert(t.bytes == (rows[0].bytes + rows[1].bytes + rows[2].bytes).to_int64(), "bytes")
    }
    Err(e) => {
      debug_assert(false, "totals: " + e)
    }
  }
  match query_top(db) {
    Ok(top) => {
      debug_assert(top.length() == 3, "top rows")
      debug_assert(top[0].path == "c.m2" && top[0].lines == 4L && top[0].pub_fns == 2L, "top[0]")
      debug_assert(top[1].path == "a.m2" && top[2].path == "b.mbt", "order")
    }
    Err(e) => {
      debug_assert(false, "top: " + e)
    }
  }
  // Duplicate primary key fails and rolls the whole transaction back.
  match insert_rows(db, [file_row("z.m2", "z\n"), file_row("a.m2", "dup\n")]) {
    Ok(_) => {
      debug_assert(false, "duplicate path accepted")
    }
    Err(e) => {
      debug_assert(e.contains("UNIQUE"), "constraint error: " + e)
    }
  }
  match query_totals(db) {
    Ok(t) => {
      debug_assert(t.files == 3L, "rollback kept 3 rows")
    }
    Err(e) => {
      debug_assert(false, "totals after rollback: " + e)
    }
  }
  match db_exec(db, "SELECT * FROM missing_table") {
    Ok(_) => {
      debug_assert(false, "missing table accepted")
    }
    Err(e) => {
      debug_assert(e.contains("no such table"), "exec error: " + e)
    }
  }
  ok_unit(db_exec(db, "DROP TABLE files"), "drop")
  ok_unit(db_close(db), "close")
}
