///| Zero-glue SQLite3 bindings: `extern "C"` straight into the system libsqlite3.

extern "C" fn sq3_libversion() -> Ptr = "sqlite3_libversion"
extern "C" fn sq3_open(filename : Ptr, pp_db : Ptr) -> Int = "sqlite3_open"
extern "C" fn sq3_close(db : Ptr) -> Int = "sqlite3_close"
extern "C" fn sq3_exec(db : Ptr, sql : Ptr, callback : Ptr, arg : Ptr, errmsg : Ptr) -> Int = "sqlite3_exec"
extern "C" fn sq3_prepare_v2(db : Ptr, sql : Ptr, n_byte : Int, pp_stmt : Ptr, pz_tail : Ptr) -> Int = "sqlite3_prepare_v2"
extern "C" fn sq3_bind_text(stmt : Ptr, idx : Int, text : Ptr, n : Int, destructor : Ptr) -> Int = "sqlite3_bind_text"
extern "C" fn sq3_bind_int64(stmt : Ptr, idx : Int, v : Int64) -> Int = "sqlite3_bind_int64"
extern "C" fn sq3_step(stmt : Ptr) -> Int = "sqlite3_step"
extern "C" fn sq3_reset(stmt : Ptr) -> Int = "sqlite3_reset"
extern "C" fn sq3_column_text(stmt : Ptr, col : Int) -> Ptr = "sqlite3_column_text"
extern "C" fn sq3_column_int64(stmt : Ptr, col : Int) -> Int64 = "sqlite3_column_int64"
extern "C" fn sq3_finalize(stmt : Ptr) -> Int = "sqlite3_finalize"
extern "C" fn sq3_errmsg(db : Ptr) -> Ptr = "sqlite3_errmsg"
extern "C" fn sq3_free(p : Ptr) -> Unit = "sqlite3_free"

pub let SQLITE_OK : Int = 0
pub let SQLITE_ROW : Int = 100
pub let SQLITE_DONE : Int = 101

/// An open database connection (`sqlite3*`).
pub struct Db {
  handle : Ptr
}

/// A prepared statement (`sqlite3_stmt*`) and its connection, for error text.
pub struct Stmt {
  handle : Ptr
  db : Ptr
}

/// Version string of the linked libsqlite3, e.g. `3.43.2`.
pub fn sqlite_version() -> String {
  cstr_to_str(sq3_libversion())
}

fn db_error(db : Ptr, what : String, rc : Int) -> String {
  what + " failed (rc=" + rc.to_string() + "): " + cstr_to_str(sq3_errmsg(db))
}

/// `SQLITE_TRANSIENT`: SQLite copies bound text before the call returns.
fn transient() -> Ptr {
  ptr_offset(ptr_null(), -1L)
}

/// Opens (or creates) the database at `path`; `:memory:` gives an in-memory one.
pub fn db_open(path : String) -> Result[Db, String] {
  let pp = ptr_alloc(8L)
  let rc = sq3_open(path.as_cstr(), pp)
  let h = ptr_read_ptr(pp, 0L)
  ptr_free(pp)
  if rc != SQLITE_OK {
    let msg = if ptr_is_null(h) { "out of memory" } else { cstr_to_str(sq3_errmsg(h)) }
    let _ = sq3_close(h)
    return Err("sqlite3_open(" + path + ") failed (rc=" + rc.to_string() + "): " + msg)
  }
  Ok(Db::{ handle: h })
}

/// Closes the connection; every statement must be finalized first.
pub fn db_close(db : Db) -> Result[Unit, String] {
  let rc = sq3_close(db.handle)
  if rc != SQLITE_OK {
    return Err(db_error(db.handle, "sqlite3_close", rc))
  }
  Ok(())
}

/// Runs one or more `;`-separated statements without results.
pub fn db_exec(db : Db, sql : String) -> Result[Unit, String] {
  let errp = ptr_alloc(8L)
  let rc = sq3_exec(db.handle, sql.as_cstr(), ptr_null(), ptr_null(), errp)
  let em = ptr_read_ptr(errp, 0L)
  ptr_free(errp)
  if rc != SQLITE_OK {
    let msg = cstr_to_str(em)
    sq3_free(em)
    return Err("sqlite3_exec failed (rc=" + rc.to_string() + "): " + msg + " in `" + sql + "`")
  }
  Ok(())
}

/// Compiles one SQL statement.
pub fn db_prepare(db : Db, sql : String) -> Result[Stmt, String] {
  let pp = ptr_alloc(8L)
  let rc = sq3_prepare_v2(db.handle, sql.as_cstr(), -1, pp, ptr_null())
  let h = ptr_read_ptr(pp, 0L)
  ptr_free(pp)
  if rc != SQLITE_OK {
    return Err(db_error(db.handle, "sqlite3_prepare_v2(`" + sql + "`)", rc))
  }
  Ok(Stmt::{ handle: h, db: db.handle })
}

/// Binds text to the 1-based parameter `idx` (copied by SQLite).
pub fn stmt_bind_text(st : Stmt, idx : Int, v : String) -> Result[Unit, String] {
  let rc = sq3_bind_text(st.handle, idx, v.as_cstr(), v.length(), transient())
  if rc != SQLITE_OK {
    return Err(db_error(st.db, "sqlite3_bind_text", rc))
  }
  Ok(())
}

/// Binds an integer to the 1-based parameter `idx`.
pub fn stmt_bind_int64(st : Stmt, idx : Int, v : Int64) -> Result[Unit, String] {
  let rc = sq3_bind_int64(st.handle, idx, v)
  if rc != SQLITE_OK {
    return Err(db_error(st.db, "sqlite3_bind_int64", rc))
  }
  Ok(())
}

/// Advances the statement: `Ok(true)` with a row, `Ok(false)` when done.
pub fn stmt_step(st : Stmt) -> Result[Bool, String] {
  let rc = sq3_step(st.handle)
  if rc == SQLITE_ROW {
    Ok(true)
  } else if rc == SQLITE_DONE {
    Ok(false)
  } else {
    Err(db_error(st.db, "sqlite3_step", rc))
  }
}

/// Rewinds the statement so it can run again with new bindings.
pub fn stmt_reset(st : Stmt) -> Result[Unit, String] {
  let rc = sq3_reset(st.handle)
  if rc != SQLITE_OK {
    return Err(db_error(st.db, "sqlite3_reset", rc))
  }
  Ok(())
}

/// Text of 0-based result column `col` (`""` for NULL).
pub fn stmt_column_text(st : Stmt, col : Int) -> String {
  cstr_to_str(sq3_column_text(st.handle, col))
}

/// Integer value of 0-based result column `col`.
pub fn stmt_column_int64(st : Stmt, col : Int) -> Int64 {
  sq3_column_int64(st.handle, col)
}

/// Destroys the statement.
pub fn stmt_finalize(st : Stmt) -> Unit {
  let _ = sq3_finalize(st.handle)
}
