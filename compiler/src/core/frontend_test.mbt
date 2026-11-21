///|
fn assert_true(cond : Bool, msg : String) -> Unit {
  if !cond {
    abort("ASSERTION FAILED: " + msg)
  }
}

///|
fn str_contains(haystack : String, needle : String) -> Bool {
  let hlen = haystack.length()
  let nlen = needle.length()
  if nlen == 0 {
    return true
  }
  if nlen > hlen {
    return false
  }
  let mut i = 0
  while i <= hlen - nlen {
    let mut matched = true
    let mut j = 0
    while j < nlen {
      if @core.str_code_at(haystack, i + j) != @core.str_code_at(needle, j) {
        matched = false
        break
      }
      j = j + 1
    }
    if matched {
      return true
    }
    i = i + 1
  }
  false
}

///|
fn check_one(src : String) -> (Bool, String, Array[@core.Diagnostic]) {
  let cr = @core.check_source_files("testpkg", ["test.pion"], [src])
  let json = @core.check_result_to_json(cr.diagnostics)
  (cr.diagnostics.length() == 0, json, cr.diagnostics)
}

///|
test "lexer: literals, comments, line and col tracking" {
  let src =
    "///| header comment\n" +
    "// regular comment\n" +
    "pub val struct Point {\n" +
    "  x : Int\n" +
    "}\n" +
    "let a : Int = 0xFF\n" +
    "let b : Int64 = 42L\n" +
    "let c : Double = 3.14\n" +
    "let d : Byte = b'a'\n" +
    "let e : Char = '\\n'\n" +
    "let f : String = \"hello\\nworld\"\n"
  let lr = @core.lex("sample.pion", src)
  assert_true(lr.diagnostics.length() == 0, "expected 0 lex diagnostics")
  assert_true(lr.tokens[0].span.line == 3, "first token on line 3")
  assert_true(lr.tokens[0].span.col == 1, "first token on col 1")
  assert_true(lr.tokens[0].raw == "pub", "first token is pub")
  assert_true(lr.tokens[1].raw == "val", "second token is val")
}

///|
test "positive: full syntax, generics, methods, closures, exhaustive match, val struct, concurrency, World, debug_assert" {
  let src =
    "pub val struct Msg {\n" +
    "  id : Int\n" +
    "  text : String\n" +
    "}\n" +
    "\n" +
    "pub struct Box[T] {\n" +
    "  value : T\n" +
    "}\n" +
    "\n" +
    "pub fn Box::get[T](self : Box[T]) -> T {\n" +
    "  self.value\n" +
    "}\n" +
    "\n" +
    "pub enum Color {\n" +
    "  Red\n" +
    "  Green\n" +
    "  Blue(Int)\n" +
    "}\n" +
    "\n" +
    "pub fn color_code(c : Color) -> Int {\n" +
    "  match c {\n" +
    "    Red => 1\n" +
    "    Green => 2\n" +
    "    Blue(v) => v\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "pub fn apply(x : Int, f : (Int) -> Int) -> Int {\n" +
    "  f(x)\n" +
    "}\n" +
    "\n" +
    "pub fn main(world : World) -> Int {\n" +
    "  debug_assert(true, \"ok\")\n" +
    "  let b : Box[Int] = Box::{ value: 41 }\n" +
    "  let inc = fn(v : Int) -> Int { v + 1 }\n" +
    "  let n = apply(b.get(), inc)\n" +
    "  let ch : Channel[Msg] = Channel::new(8)\n" +
    "  let m : Mutex[Int] = Mutex::new(0)\n" +
    "  let a = AtomicInt::new(0)\n" +
    "  let msg = Msg::{ id: n, text: \"hi\" }\n" +
    "  scope(world, fn(s : Scope) -> Unit {\n" +
    "    spawn(s, fn() -> Unit {\n" +
    "      let _ = ch.send(msg)\n" +
    "      let _ = a.fetch_add(1)\n" +
    "      let cur = m.lock()\n" +
    "      m.set(cur + 1)\n" +
    "      m.unlock()\n" +
    "    })\n" +
    "  })\n" +
    "  let _ = ch.recv()\n" +
    "  ch.close()\n" +
    "  io_println(world, \"done\")\n" +
    "  color_code(Blue(a.load()))\n" +
    "}\n"
  let (ok, json, _) = check_one(src)
  assert_true(ok, "expected positive program to pass, got: " + json)
  assert_true(json == "{\"ok\":true,\"diagnostics\":[]}", "exact ok json")
}

///|
test "positive: linear move of non-Send Array into spawn and Channel" {
  let src =
    "pub fn run(world : World) -> Unit {\n" +
    "  let buf : Array[Int] = [1, 2, 3]\n" +
    "  let ch : Channel[Array[Int]] = Channel::new(4)\n" +
    "  let payload : Array[Int] = [4, 5]\n" +
    "  let _ = ch.send(move payload)\n" +
    "  scope(world, fn(s : Scope) -> Unit {\n" +
    "    spawn(s, fn() -> Unit {\n" +
    "      let owned = move buf\n" +
    "      let _ = owned.length()\n" +
    "    })\n" +
    "  })\n" +
    "}\n"
  let (ok, json, _) = check_one(src)
  assert_true(ok, "expected valid move to pass, got: " + json)
}

///|
test "negative: E_PARSE on invalid syntax with line and fixit" {
  let src = "pub fn broken(x : Int) -> Int {\n  let y = \n}\n"
  let (ok, json, diags) = check_one(src)
  assert_true(!ok, "expected parse error")
  assert_true(diags.length() >= 1, "at least 1 diagnostic")
  assert_true(diags[0].code == "E_PARSE", "expected E_PARSE")
  assert_true(diags[0].line == 3, "expected line 3")
  assert_true(diags[0].fixit.length() > 0, "non-empty fixit")
  assert_true(str_contains(json, "\"code\":\"E_PARSE\""), "json has E_PARSE")
}

///|
test "negative: E_MISSING_TYPE on missing param and return types" {
  let src = "pub fn add(x, y : Int) {\n  x + y\n}\n"
  let (ok, json, diags) = check_one(src)
  assert_true(!ok, "expected E_MISSING_TYPE")
  assert_true(diags.length() >= 2, "expected param and return missing type")
  assert_true(diags[0].code == "E_MISSING_TYPE", "param E_MISSING_TYPE")
  assert_true(diags[0].line == 1, "line 1")
  assert_true(diags[0].fixit.length() > 0, "param fixit")
  assert_true(diags[1].code == "E_MISSING_TYPE", "ret E_MISSING_TYPE")
  assert_true(str_contains(json, "\"code\":\"E_MISSING_TYPE\""), "json code")
}

///|
test "negative: E_TYPE_MISMATCH on incompatible types" {
  let src =
    "pub fn bad() -> Int {\n" +
    "  let x : Int = \"not an int\"\n" +
    "  x\n" +
    "}\n"
  let (ok, json, diags) = check_one(src)
  assert_true(!ok, "expected E_TYPE_MISMATCH")
  assert_true(diags[0].code == "E_TYPE_MISMATCH", "code E_TYPE_MISMATCH")
  assert_true(diags[0].line == 2, "line 2")
  assert_true(diags[0].expected == "Int", "expected Int")
  assert_true(diags[0].found == "String", "found String")
  assert_true(diags[0].fixit.length() > 0, "non-empty fixit")
  assert_true(str_contains(json, "\"code\":\"E_TYPE_MISMATCH\""), "json code")
}

///|
test "negative: E_NON_EXHAUSTIVE on missing enum variant with fixit" {
  let src =
    "pub enum Status {\n" +
    "  Pending\n" +
    "  Running\n" +
    "  Done\n" +
    "}\n" +
    "pub fn label(st : Status) -> Int {\n" +
    "  match st {\n" +
    "    Pending => 0\n" +
    "    Done => 2\n" +
    "  }\n" +
    "}\n"
  let (ok, json, diags) = check_one(src)
  assert_true(!ok, "expected E_NON_EXHAUSTIVE")
  assert_true(diags[0].code == "E_NON_EXHAUSTIVE", "code E_NON_EXHAUSTIVE")
  assert_true(diags[0].line == 7, "line 7")
  assert_true(str_contains(diags[0].fixit, "Running"), "fixit names missing Running")
  assert_true(str_contains(json, "\"code\":\"E_NON_EXHAUSTIVE\""), "json code")
}

///|
test "negative: E_NOT_SEND on val struct, spawn capture, and Channel::send" {
  let src_val =
    "pub val struct BadVal {\n" +
    "  mut count : Int\n" +
    "  items : Array[Int]\n" +
    "}\n"
  let (ok1, _, d1) = check_one(src_val)
  assert_true(!ok1, "val struct with mut and Array must fail")
  assert_true(d1.length() == 2, "2 E_NOT_SEND errors")
  assert_true(d1[0].code == "E_NOT_SEND" && d1[0].line == 2, "mut field line 2")
  assert_true(d1[1].code == "E_NOT_SEND" && d1[1].line == 3, "Array field line 3")

  let src_spawn =
    "pub fn race(world : World) -> Unit {\n" +
    "  let mut counter = 0\n" +
    "  let arr : Array[Int] = [1, 2]\n" +
    "  scope(world, fn(s : Scope) -> Unit {\n" +
    "    spawn(s, fn() -> Unit {\n" +
    "      let _ = counter\n" +
    "      let _ = arr.length()\n" +
    "    })\n" +
    "  })\n" +
    "}\n"
  let (ok2, json2, d2) = check_one(src_spawn)
  assert_true(!ok2, "spawn capturing mut and Array must fail")
  assert_true(d2.length() >= 2, "at least 2 E_NOT_SEND errors")
  assert_true(d2[0].code == "E_NOT_SEND", "counter E_NOT_SEND")
  assert_true(d2[0].line == 6, "counter line 6")
  assert_true(str_contains(d2[0].fixit, "Mutex::new"), "fixit suggests Mutex")
  assert_true(str_contains(json2, "\"code\":\"E_NOT_SEND\""), "json code")

  let src_chan =
    "pub fn send_bad() -> Unit {\n" +
    "  let ch : Channel[Array[Int]] = Channel::new(4)\n" +
    "  let xs : Array[Int] = [1]\n" +
    "  let _ = ch.send(xs)\n" +
    "}\n"
  let (ok3, _, d3) = check_one(src_chan)
  assert_true(!ok3, "sending non-Send Array without move must fail")
  assert_true(d3[0].code == "E_NOT_SEND", "chan send E_NOT_SEND")
  assert_true(d3[0].line == 4, "chan send line 4")
}

///|
test "negative: E_USE_AFTER_MOVE on linear variable reuse" {
  let src =
    "pub fn uam() -> Int {\n" +
    "  let xs : Array[Int] = [1, 2, 3]\n" +
    "  let ys = move xs\n" +
    "  let _ = ys.length()\n" +
    "  xs.length()\n" +
    "}\n"
  let (ok, json, diags) = check_one(src)
  assert_true(!ok, "expected E_USE_AFTER_MOVE")
  assert_true(diags[0].code == "E_USE_AFTER_MOVE", "code E_USE_AFTER_MOVE")
  assert_true(diags[0].line == 5, "line 5")
  assert_true(diags[0].fixit.length() > 0, "non-empty fixit")
  assert_true(str_contains(json, "\"code\":\"E_USE_AFTER_MOVE\""), "json code")
}

///|
test "negative: E_CAPABILITY_MISSING on IO without World" {
  let src =
    "pub fn pure_fn() -> Int64 {\n" +
    "  io_println(\"nope\")\n" +
    "  clock_now_ms()\n" +
    "}\n"
  let (ok, json, diags) = check_one(src)
  assert_true(!ok, "expected E_CAPABILITY_MISSING")
  assert_true(diags.length() == 2, "2 capability errors")
  assert_true(diags[0].code == "E_CAPABILITY_MISSING", "io_println E_CAPABILITY_MISSING")
  assert_true(diags[0].line == 2, "line 2")
  assert_true(str_contains(diags[0].fixit, "world : World"), "fixit suggests World")
  assert_true(diags[1].code == "E_CAPABILITY_MISSING", "clock_now_ms E_CAPABILITY_MISSING")
  assert_true(diags[1].line == 3, "line 3")
  assert_true(str_contains(json, "\"code\":\"E_CAPABILITY_MISSING\""), "json code")
}

///|
test "pionsig: stability across body edits and round-trip parse" {
  let v1 =
    "pub struct User { id : Int }\n" +
    "fn private_helper(x : Int) -> Int { x + 1 }\n" +
    "pub fn greet(u : User) -> Int {\n" +
    "  private_helper(u.id)\n" +
    "}\n"
  let v2 =
    "// changed comment and completely different body\n" +
    "pub struct User { id : Int }\n" +
    "fn another_private(a : Int, b : Int) -> Int { a * b }\n" +
    "pub fn greet(u : User) -> Int {\n" +
    "  let tmp = another_private(u.id, 10)\n" +
    "  tmp + 42\n" +
    "}\n"
  let sig1 = @core.cli_emit_sig("app", ["a.pion"], [v1])
  let sig2 = @core.cli_emit_sig("app", ["a.pion"], [v2])
  assert_true(sig1 == sig2, "pionsig must be byte-for-byte identical when only bodies change")
  match @core.parse_pionsig(sig1) {
    Ok(parsed) => {
      assert_true(parsed.pkg == "app", "parsed pkg name")
      assert_true(parsed.entries.length() == 2, "2 pub entries")
      assert_true(@core.serialize_pionsig(parsed) == sig1, "round-trip serialize matches")
    }
    Err(e) => abort("parse_pionsig failed: " + e)
  }
}

///|
test "query: defs, sig, callers, deps JSON outputs" {
  let src =
    "pub val struct Item { id : Int }\n" +
    "pub fn helper(x : Int) -> Int { x + 1 }\n" +
    "pub fn main(world : World) -> Int {\n" +
    "  io_println(world, \"hi\")\n" +
    "  helper(41)\n" +
    "}\n"
  match @core.cli_query_json("defs", "demo", ["demo.pion"], [src]) {
    Ok(j) => {
      assert_true(str_contains(j, "\"defs\":["), "defs root")
      assert_true(str_contains(j, "\"name\":\"Item\""), "Item def")
      assert_true(str_contains(j, "\"kind\":\"fn\""), "fn kind")
    }
    Err(e) => abort(e)
  }
  match @core.cli_query_json("sig", "demo", ["demo.pion"], [src]) {
    Ok(j) => {
      assert_true(str_contains(j, "\"sig_hash\":"), "sig_hash")
      assert_true(str_contains(j, "\"exports\":["), "exports")
    }
    Err(e) => abort(e)
  }
  match @core.cli_query_json("callers", "demo", ["demo.pion"], [src]) {
    Ok(j) => {
      assert_true(str_contains(j, "\"callers\":["), "callers root")
      assert_true(str_contains(j, "\"helper\""), "calls helper")
      assert_true(str_contains(j, "\"io_println\""), "calls io_println")
    }
    Err(e) => abort(e)
  }
  match @core.cli_query_json("deps", "demo", ["demo.pion"], [src]) {
    Ok(j) => {
      assert_true(str_contains(j, "\"packages\":["), "packages root")
      assert_true(str_contains(j, "pion/runtime/world"), "world dep")
      assert_true(str_contains(j, "\"sig_hash\":"), "deps sig_hash")
    }
    Err(e) => abort(e)
  }
}

///|
test "p6b: import, cross-package types/methods/enums/consts and E_PRIVATE_SYMBOL" {
  let math_src =
    "pub let PI : Int = 3\n" +
    "let SECRET : Int = 99\n" +
    "pub struct Point { x : Int, y : Int }\n" +
    "struct Hidden { v : Int }\n" +
    "pub fn Point::sum(self : Point) -> Int { self.x + self.y }\n" +
    "pub enum Color { Red, Blue(Int) }\n" +
    "pub fn add(a : Int, b : Int) -> Int { a + b }\n" +
    "fn priv_helper(x : Int) -> Int { x * 2 }\n"
  let math_cr = @core.check_source_files_with_imports(
    "math",
    ["math.pion"],
    [math_src],
    [],
    true,
  )
  assert_true(math_cr.diagnostics.length() == 0, "math should check cleanly")
  let imported = [@core.imported_pkg_new("math", math_cr.tc)]

  let ok_app =
    "import \"math\" as m\n" +
    "pub fn run() -> Int {\n" +
    "  let p : m::Point = m::Point::{ x: 10, y: 20 }\n" +
    "  let c : m::Color = m::Color::Blue(m::PI)\n" +
    "  let cv = match c {\n" +
    "    m::Color::Red => 0\n" +
    "    m::Color::Blue(v) => v\n" +
    "  }\n" +
    "  m::add(p.sum(), cv)\n" +
    "}\n"
  let app_cr = @core.check_source_files_with_imports(
    "app",
    ["app.pion"],
    [ok_app],
    imported,
    true,
  )
  assert_true(app_cr.diagnostics.length() == 0, "app using pub symbols should pass")

  let priv_app =
    "import \"math\"\n" +
    "pub fn bad() -> Int {\n" +
    "  let h = math::Hidden::{ v: 1 }\n" +
    "  let s = math::SECRET\n" +
    "  math::priv_helper(s + h.v)\n" +
    "}\n"
  let priv_cr = @core.check_source_files_with_imports(
    "app",
    ["bad.pion"],
    [priv_app],
    imported,
    true,
  )
  let priv_json = @core.check_result_to_json(priv_cr.diagnostics)
  assert_true(str_contains(priv_json, "E_PRIVATE_SYMBOL"), "expected E_PRIVATE_SYMBOL")
  assert_true(priv_cr.diagnostics.length() >= 3, "expected 3 private symbol errors")

  let unk_app =
    "import \"missing_pkg\"\n" +
    "pub fn f() -> Int { 0 }\n"
  let unk_cr = @core.check_source_files_with_imports(
    "app",
    ["unk.pion"],
    [unk_app],
    imported,
    true,
  )
  let unk_json = @core.check_result_to_json(unk_cr.diagnostics)
  assert_true(str_contains(unk_json, "E_UNKNOWN_PACKAGE"), "expected E_UNKNOWN_PACKAGE")
}

///|
test "p6b: pion.toml parser, topo_sort, E_IMPORT_CYCLE, and workspace deps json" {
  let toml =
    "# sample manifest\n" +
    "[package]\n" +
    "name = \"app\"\n" +
    "version = \"0.1.0\"\n" +
    "\n" +
    "[dependencies]\n" +
    "math = { path = \"../math\" }\n" +
    "util = { path = \"./deps/util\" }\n"
  match @core.parse_pion_toml(toml) {
    Ok(m) => {
      assert_true(m.name == "app", "pkg name")
      assert_true(m.version == "0.1.0", "pkg version")
      assert_true(m.deps.length() == 2, "2 deps")
      assert_true(m.deps[0].name == "math" && m.deps[0].path == "../math", "dep 0")
      assert_true(m.deps[1].name == "util" && m.deps[1].path == "./deps/util", "dep 1")
    }
    Err(e) => abort("parse_pion_toml failed: " + e)
  }

  let ok_topo = @core.topo_sort_packages(
    ["app", "math", "core_util"],
    [["math"], ["core_util"], []],
  )
  assert_true(ok_topo.diagnostics.length() == 0, "acyclic topo ok")
  assert_true(ok_topo.order.length() == 3, "3 nodes")
  assert_true(ok_topo.order[0] == 2 && ok_topo.order[1] == 1 && ok_topo.order[2] == 0, "deps first")

  let cyc_topo = @core.topo_sort_packages(["a", "b"], [["b"], ["a"]])
  let cyc_json = @core.check_result_to_json(cyc_topo.diagnostics)
  assert_true(str_contains(cyc_json, "E_IMPORT_CYCLE"), "expected E_IMPORT_CYCLE")

  let ws_json = @core.query_workspace_deps_json(
    ["math", "app"],
    [[], ["math"]],
    ["aaaa", "bbbb"],
  )
  assert_true(str_contains(ws_json, "\"name\":\"math\""), "math in ws json")
  assert_true(str_contains(ws_json, "\"deps\":[\"math\"]"), "app dep in ws json")
}

///|
test "p6b: first-class test block and contextual test identifier" {
  let src =
    "pub fn double(x : Int) -> Int {\n" +
    "  let test = x * 2\n" +
    "  test\n" +
    "}\n" +
    "test \"double works\" {\n" +
    "  debug_assert(double(21) == 42, \"expected 42\")\n" +
    "}\n"
  let cr = @core.check_source_files("tpkg", ["t.pion"], [src])
  assert_true(cr.diagnostics.length() == 0, "contextual test var + test block should pass")
}

///|
test "p6c: stdlib String/Bytes/Math/World IO typechecking and capability/Send guards" {
  let ok_src =
    "pub fn demo(world : World) -> Int {\n" +
    "  let s = \"  hello,world  \".trim()\n" +
    "  let a = s.starts_with(\"he\") && s.ends_with(\"ld\") && s.contains(\",\")\n" +
    "  let idx : Int = s.index_of(\",\")\n" +
    "  let parts : Array[String] = s.split(\",\")\n" +
    "  let r : String = s.replace(\"world\", \"pion\")\n" +
    "  let bs : Bytes = r.to_bytes()\n" +
    "  let buf = Bytes::new(4)\n" +
    "  buf[0] = b'A'\n" +
    "  let b0 : Byte = buf[0]\n" +
    "  let joined : Bytes = buf.slice(0, 1).concat(bs)\n" +
    "  let back : String = joined.to_string()\n" +
    "  let m : Double = math_abs(-1.5) + math_floor(2.7) + math_ceil(2.1) + math_sin(0.0) + math_cos(0.0) + math_pow(2.0, 3.0)\n" +
    "  let _w : Result[Unit, String] = fs_write_bytes(world, \"/tmp/x\", joined)\n" +
    "  let _rb : Result[Bytes, String] = fs_read_bytes(world, \"/tmp/x\")\n" +
    "  let _ap : Result[Unit, String] = fs_append(world, \"/tmp/x\", back)\n" +
    "  let _mt : Int64 = fs_mtime_ms(world, \"/tmp/x\")\n" +
    "  let _ec : Result[String, String] = proc_exec_capture(world, [\"echo\", \"hi\"])\n" +
    "  if a && idx >= 0 && parts.length() > 0 && b0.to_int() == 65 && m > 0.0 { 0 } else { 1 }\n" +
    "}\n"
  let cr = @core.check_source_files("stdlib_ok", ["ok.pion"], [ok_src])
  assert_true(cr.diagnostics.length() == 0, "stdlib ok_src should have 0 diagnostics")

  let no_world =
    "pub fn bad_io() -> Int64 {\n" +
    "  fs_mtime_ms(\"/tmp/x\")\n" +
    "}\n"
  let cr_nw = @core.check_source_files("stdlib_nw", ["nw.pion"], [no_world])
  let nw_json = @core.check_result_to_json(cr_nw.diagnostics)
  assert_true(str_contains(nw_json, "E_CAPABILITY_MISSING"), "fs_mtime_ms requires World")

  let no_world_cap =
    "pub fn bad_exec() -> Result[String, String] {\n" +
    "  proc_exec_capture([\"echo\", \"hi\"])\n" +
    "}\n"
  let cr_ec = @core.check_source_files("stdlib_ec", ["ec.pion"], [no_world_cap])
  let ec_json = @core.check_result_to_json(cr_ec.diagnostics)
  assert_true(str_contains(ec_json, "E_CAPABILITY_MISSING"), "proc_exec_capture requires World")

  let bytes_not_send =
    "pub fn bad_spawn(world : World) -> Unit {\n" +
    "  let b = Bytes::new(4)\n" +
    "  scope(world, fn(s : Scope) -> Unit {\n" +
    "    spawn(s, fn() -> Unit {\n" +
    "      let _ = b.length()\n" +
    "    })\n" +
    "  })\n" +
    "}\n"
  let cr_ns = @core.check_source_files("stdlib_ns", ["ns.pion"], [bytes_not_send])
  let ns_json = @core.check_result_to_json(cr_ns.diagnostics)
  assert_true(str_contains(ns_json, "E_NOT_SEND"), "Bytes must be !Send")
}

///|
test "p7a_ergonomics_try_for_interp_and_methods" {
  let ok_src =
    "fn get_res(ok : Bool) -> Result[String, String] {\n" +
    "  if ok { Ok(\"  hi  \") } else { Err(\"boom\") }\n" +
    "}\n" +
    "fn use_res(ok : Bool) -> Result[Int, String] {\n" +
    "  let s : String = get_res(ok)?.trim()\n" +
    "  Ok(s.length())\n" +
    "}\n" +
    "fn use_opt(x : Option[Int]) -> Option[Int] {\n" +
    "  let v : Int = x?\n" +
    "  Some(v + 1)\n" +
    "}\n" +
    "pub fn main() -> Int {\n" +
    "  let mut sum = 0\n" +
    "  for i in 0..10 {\n" +
    "    if i == 3 { continue }\n" +
    "    if i == 8 { break }\n" +
    "    sum = sum + i\n" +
    "  }\n" +
    "  let mut sum64 : Int64 = 0L\n" +
    "  for j in 0L..5L {\n" +
    "    sum64 = sum64 + j\n" +
    "  }\n" +
    "  let nums : Array[Int] = [3, 1, 2]\n" +
    "  nums.sort()\n" +
    "  nums.reverse()\n" +
    "  for x in nums {\n" +
    "    sum = sum + x\n" +
    "  }\n" +
    "  nums.clear()\n" +
    "  let words : Array[String] = [\"b\", \"a\"]\n" +
    "  words.sort()\n" +
    "  let joined : String = words.join(\",\")\n" +
    "  let d : Double = 3.5\n" +
    "  let ds : String = d.to_string()\n" +
    "  let b : Bool = true\n" +
    "  let c : Char = 'Z'\n" +
    "  let msg : String = \"j=\\{joined}, n=\\{sum + 1}, n64=\\{sum64}, d=\\{d}, b=\\{b}, c=\\{c}, ds=\\{ds}\"\n" +
    "  let esc : String = \"\\\\{literal}\"\n" +
    "  let m : Map[String, Int] = Map::new()\n" +
    "  m.set(\"k\", 1)\n" +
    "  let has_k : Bool = m.contains(\"k\")\n" +
    "  let ks : Array[String] = m.keys()\n" +
    "  m.remove(\"k\")\n" +
    "  let _r = use_res(true)\n" +
    "  let _o = use_opt(Some(1))\n" +
    "  if has_k && ks.length() == 1 && msg.length() > 0 && esc.length() > 0 { 0 } else { 1 }\n" +
    "}\n"
  let cr = @core.check_source_files("p7a_ok", ["ok.pion"], [ok_src])
  assert_true(cr.diagnostics.length() == 0, "p7a ok_src should have 0 diagnostics")

  // `?` in non-Result function
  let bad_try1 =
    "fn f() -> Int {\n" +
    "  let r : Result[Int, String] = Ok(1)\n" +
    "  r?\n" +
    "}\n"
  let cr1 = @core.check_source_files("p7a_bad1", ["b1.pion"], [bad_try1])
  assert_true(str_contains(@core.check_result_to_json(cr1.diagnostics), "E_TYPE_MISMATCH"), "try in non-Result fn")

  // `?` with incompatible error type
  let bad_try2 =
    "fn f() -> Result[Int, Int] {\n" +
    "  let r : Result[Int, String] = Ok(1)\n" +
    "  Ok(r?)\n" +
    "}\n"
  let cr2 = @core.check_source_files("p7a_bad2", ["b2.pion"], [bad_try2])
  assert_true(str_contains(@core.check_result_to_json(cr2.diagnostics), "E_TYPE_MISMATCH"), "try err type mismatch")

  // `?` in top-level const
  let bad_try3 =
    "fn mk() -> Result[Int, String] { Ok(1) }\n" +
    "let BAD : Result[Int, String] = Ok(mk()?)\n"
  let cr3 = @core.check_source_files("p7a_bad3", ["b3.pion"], [bad_try3])
  assert_true(str_contains(@core.check_result_to_json(cr3.diagnostics), "E_TYPE_MISMATCH"), "try in top-level const")

  // `for x in non_array`
  let bad_for =
    "fn f() -> Unit {\n" +
    "  for x in 42 {\n" +
    "    let _ = x\n" +
    "  }\n" +
    "}\n"
  let cr4 = @core.check_source_files("p7a_bad4", ["b4.pion"], [bad_for])
  assert_true(str_contains(@core.check_result_to_json(cr4.diagnostics), "E_TYPE_MISMATCH"), "for-in requires Array")

  // `Array[Int]::join` rejected
  let bad_join =
    "fn f() -> String {\n" +
    "  let a : Array[Int] = [1, 2]\n" +
    "  a.join(\",\")\n" +
    "}\n"
  let cr5 = @core.check_source_files("p7a_bad5", ["b5.pion"], [bad_join])
  assert_true(str_contains(@core.check_result_to_json(cr5.diagnostics), "E_TYPE_MISMATCH"), "Array[Int]::join rejected")

  // `Array[Bool]::sort` rejected
  let bad_sort =
    "fn f() -> Unit {\n" +
    "  let a : Array[Bool] = [true, false]\n" +
    "  a.sort()\n" +
    "}\n"
  let cr6 = @core.check_source_files("p7a_bad6", ["b6.pion"], [bad_sort])
  assert_true(str_contains(@core.check_result_to_json(cr6.diagnostics), "E_TYPE_MISMATCH"), "Array[Bool]::sort rejected")
}

///|
test "p8: tuple destructuring, tuple indexing, match guards, and generic pair_swap" {
  let ok_src =
    "fn pair_swap[A, B](p : (A, B)) -> (B, A) {\n" +
    "  let (a, b) = p\n" +
    "  (b, a)\n" +
    "}\n" +
    "fn mk_triple(tag : String, n : Int) -> (String, Int, Double) {\n" +
    "  (tag, n, 3.5)\n" +
    "}\n" +
    "fn classify(opt : Option[Int]) -> String {\n" +
    "  match opt {\n" +
    "    Some(x) if x > 10 => \"big\"\n" +
    "    Some(x) if x > 0 => \"pos\"\n" +
    "    Some(_) => \"nonpos\"\n" +
    "    None => \"none\"\n" +
    "  }\n" +
    "}\n" +
    "pub fn main() -> Int {\n" +
    "  let (s, _, d) : (String, Int, Double) = mk_triple(\"hi\", 7)\n" +
    "  let swapped = pair_swap((s, 42))\n" +
    "  let n = swapped.0\n" +
    "  let s2 = swapped.1\n" +
    "  let c = classify(Some(5))\n" +
    "  if n == 42 && s2 == \"hi\" && c == \"pos\" && d > 3.0 { 0 } else { 1 }\n" +
    "}\n"
  let cr = @core.check_source_files("p8_ok", ["p8_ok.pion"], [ok_src])
  assert_true(cr.diagnostics.length() == 0, "p8 ok_src should have 0 diagnostics")

  // Arity mismatch in tuple destructuring
  let bad_arity =
    "fn f() -> Int {\n" +
    "  let (a, b) = (1, 2, 3)\n" +
    "  a + b\n" +
    "}\n"
  let cr1 = @core.check_source_files("p8_bad1", ["b1.pion"], [bad_arity])
  assert_true(str_contains(@core.check_result_to_json(cr1.diagnostics), "E_TYPE_MISMATCH"), "tuple arity mismatch")

  // Destructuring non-tuple
  let bad_nontup =
    "fn f() -> Int {\n" +
    "  let (a, b) = 42\n" +
    "  a + b\n" +
    "}\n"
  let cr2 = @core.check_source_files("p8_bad2", ["b2.pion"], [bad_nontup])
  assert_true(str_contains(@core.check_result_to_json(cr2.diagnostics), "E_TYPE_MISMATCH"), "destructure non-tuple")

  // Out-of-range tuple index
  let bad_idx =
    "fn f() -> Int {\n" +
    "  let t = (1, 2)\n" +
    "  t.2\n" +
    "}\n"
  let cr3 = @core.check_source_files("p8_bad3", ["b3.pion"], [bad_idx])
  assert_true(str_contains(@core.check_result_to_json(cr3.diagnostics), "E_TYPE_MISMATCH"), "tuple index out of bounds")

  // Guarded arm does NOT satisfy exhaustiveness
  let bad_exh =
    "fn f(opt : Option[Int]) -> Int {\n" +
    "  match opt {\n" +
    "    Some(x) if x > 0 => x\n" +
    "    None => 0\n" +
    "  }\n" +
    "}\n"
  let cr4 = @core.check_source_files("p8_bad4", ["b4.pion"], [bad_exh])
  assert_true(str_contains(@core.check_result_to_json(cr4.diagnostics), "E_NON_EXHAUSTIVE"), "guarded arm is non-exhaustive")

  // Non-Bool guard condition
  let bad_guard =
    "fn f(x : Int) -> Int {\n" +
    "  match x {\n" +
    "    n if n + 1 => n\n" +
    "    _ => 0\n" +
    "  }\n" +
    "}\n"
  let cr5 = @core.check_source_files("p8_bad5", ["b5.pion"], [bad_guard])
  assert_true(str_contains(@core.check_result_to_json(cr5.diagnostics), "E_TYPE_MISMATCH"), "non-Bool match guard")
}

///|
test "p10c: emit_pion_stub preserves imports, pub/private visibility, and cross-pkg types" {
  let az_src =
    "pub val struct Stats {\n" +
    "  lines : Int\n" +
    "  words : Int\n" +
    "}\n" +
    "pub enum Mode {\n" +
    "  Fast\n" +
    "  Full(Int)\n" +
    "}\n" +
    "pub let MAX_N : Int = 100\n" +
    "fn secret_helper(x : Int) -> Int {\n" +
    "  x * 2 + 1\n" +
    "}\n" +
    "pub fn make_stats(n : Int) -> Stats {\n" +
    "  let h = secret_helper(n)\n" +
    "  Stats::{ lines: n, words: h }\n" +
    "}\n"
  let az_cr = @core.check_source_files_with_imports("analyzer", ["analyzer.pion"], [az_src], [], true)
  assert_true(az_cr.diagnostics.length() == 0, "analyzer full check should pass")
  let az_stub = @core.emit_pion_stub(az_cr.pkg)
  assert_true(str_contains(az_stub, "pub val struct Stats"), "stub preserves pub val struct")
  assert_true(str_contains(az_stub, "pub enum Mode"), "stub preserves pub enum")
  assert_true(str_contains(az_stub, "pub let MAX_N : Int = panic()"), "stub preserves pub const")
  assert_true(str_contains(az_stub, "fn secret_helper(x : Int) -> Int { panic() }"), "stub preserves private fn for E_PRIVATE_SYMBOL")

  let az_stub_cr = @core.check_source_files_with_imports("analyzer", ["analyzer.pionstub"], [az_stub], [], true)
  assert_true(az_stub_cr.diagnostics.length() == 0, "analyzer stub should typecheck cleanly")
  let az_imp = @core.imported_pkg_new("analyzer", az_stub_cr.tc)

  let mid_src =
    "import \"analyzer\" as az\n" +
    "pub fn wrap(s : az::Stats) -> az::Stats {\n" +
    "  az::Stats::{ lines: s.lines + 1, words: s.words + az::MAX_N }\n" +
    "}\n"
  let mid_cr = @core.check_source_files_with_imports("mid", ["mid.pion"], [mid_src], [az_imp], true)
  assert_true(mid_cr.diagnostics.length() == 0, "mid full check against az stub should pass")
  let mid_stub = @core.emit_pion_stub(mid_cr.pkg)
  assert_true(str_contains(mid_stub, "import \"analyzer\" as az"), "mid stub preserves import declaration")
  let mid_stub_cr = @core.check_source_files_with_imports("mid", ["mid.pionstub"], [mid_stub], [az_imp], true)
  assert_true(mid_stub_cr.diagnostics.length() == 0, "mid stub should typecheck cleanly against az stub")
  let mid_imp = @core.imported_pkg_new("mid", mid_stub_cr.tc)

  let app_ok =
    "import \"analyzer\" as az\n" +
    "import \"mid\" as m\n" +
    "pub fn main() -> Int {\n" +
    "  let s = m::wrap(az::make_stats(3))\n" +
    "  s.lines + s.words\n" +
    "}\n"
  let app_cr = @core.check_source_files_with_imports("app", ["app.pion"], [app_ok], [az_imp, mid_imp], true)
  assert_true(app_cr.diagnostics.length() == 0, "app should typecheck cleanly against transitive stubs")

  let app_priv =
    "import \"analyzer\" as az\n" +
    "pub fn main() -> Int {\n" +
    "  az::secret_helper(1)\n" +
    "}\n"
  let priv_cr = @core.check_source_files_with_imports("app", ["app.pion"], [app_priv], [az_imp], true)
  assert_true(str_contains(@core.check_result_to_json(priv_cr.diagnostics), "E_PRIVATE_SYMBOL"), "stub must still reject private symbol with E_PRIVATE_SYMBOL")

  let app_bad_ty =
    "import \"mid\" as m\n" +
    "pub fn main() -> Int {\n" +
    "  let _ = m::wrap(42)\n" +
    "  0\n" +
    "}\n"
  let bad_ty_cr = @core.check_source_files_with_imports("app", ["app.pion"], [app_bad_ty], [az_imp, mid_imp], true)
  assert_true(str_contains(@core.check_result_to_json(bad_ty_cr.diagnostics), "E_TYPE_MISMATCH"), "stub must still reject type mismatch with E_TYPE_MISMATCH")
}

///|
test "p10a: parser never hangs on reserved keyword as struct field or param name" {
  let bad_struct = "struct Bad { val : Int }\n"
  let cr1 = @core.check_source_files("p10a_bad_struct", ["bs.pion"], [bad_struct])
  assert_true(cr1.diagnostics.length() > 0, "reserved keyword field must return parse error")
  assert_true(str_contains(@core.check_result_to_json(cr1.diagnostics), "E_PARSE"), "E_PARSE expected for struct field keyword")

  let bad_param = "fn f(val : Int) -> Int { 0 }\n"
  let cr2 = @core.check_source_files("p10a_bad_param", ["bp.pion"], [bad_param])
  assert_true(cr2.diagnostics.length() > 0, "reserved keyword param must return parse error")
  assert_true(str_contains(@core.check_result_to_json(cr2.diagnostics), "E_PARSE"), "E_PARSE expected for param keyword")

  let bad_enum = "enum BadE { val(Int) }\n"
  let cr3 = @core.check_source_files("p10a_bad_enum", ["be.pion"], [bad_enum])
  assert_true(cr3.diagnostics.length() > 0, "reserved keyword enum variant must return parse error")
}

///|
test "p12a: extern C FFI valid and Ptr helpers" {
  let src =
    "pub extern \"C\" fn c_strlen(s : Ptr) -> Int64 = \"strlen\"\n" +
    "extern \"C\" fn abs(x : Int) -> Int\n" +
    "extern \"C\" fn c_free(p : Ptr) -> Unit = \"free\"\n" +
    "pub fn main() -> Int {\n" +
    "  let p : Ptr = ptr_null()\n" +
    "  let is_n : Bool = ptr_is_null(p)\n" +
    "  let a : Int64 = ptr_addr(p)\n" +
    "  let s : String = \"hello\"\n" +
    "  let n : Int64 = c_strlen(s.as_cstr())\n" +
    "  let v : Int = abs(-7)\n" +
    "  c_free(p)\n" +
    "  if is_n && a == 0L { n.to_int() + v } else { 0 }\n" +
    "}\n"
  let cr = @core.check_source_files("p12a_ffi_ok", ["p12a_ffi_ok.pion"], [src])
  assert_eq(cr.diagnostics.length(), 0)
  let sig = @core.cli_emit_sig("p12a_ffi_ok", ["p12a_ffi_ok.pion"], [src])
  assert_eq(sig.contains("extern \"C\" fn c_strlen(s: Ptr) -> Int64 = \"strlen\""), true)
}

///|
test "p12a: extern C rejects non-C-ABI types with fixit" {
  let src =
    "extern \"C\" fn bad_str(s : String) -> Int\n" +
    "extern \"C\" fn bad_arr(a : Array[Int]) -> Map[String, Int]\n" +
    "pub fn main() -> Int { 0 }\n"
  let cr = @core.check_source_files("p12a_ffi_bad", ["p12a_ffi_bad.pion"], [src])
  assert_eq(cr.diagnostics.length(), 3)
  assert_eq(cr.diagnostics[0].code, "E_TYPE_MISMATCH")
  assert_eq(cr.diagnostics[0].fixit.contains("as_cstr"), true)
  assert_eq(cr.diagnostics[1].code, "E_TYPE_MISMATCH")
  assert_eq(cr.diagnostics[2].code, "E_TYPE_MISMATCH")
}

///|
test "p12a: Ptr is !Send across spawn" {
  let src =
    "pub fn main(world : World) -> Int {\n" +
    "  let p : Ptr = ptr_null()\n" +
    "  scope(world, fn(s : Scope) -> Unit {\n" +
    "    spawn(s, fn() -> Unit {\n" +
    "      let _ = ptr_is_null(p)\n" +
    "    })\n" +
    "  })\n" +
    "  0\n" +
    "}\n"
  let cr = @core.check_source_files("p12a_ptr_send", ["p12a_ptr_send.pion"], [src])
  assert_eq(cr.diagnostics.length() > 0, true)
  assert_eq(cr.diagnostics[0].code, "E_NOT_SEND")
}

///|
test "p12a: trait impl and generic trait bounds ok" {
  let src =
    "pub trait Show {\n" +
    "  show(self : Self) -> String\n" +
    "}\n" +
    "pub trait Hash {\n" +
    "  fn hash(self : Self) -> Int\n" +
    "}\n" +
    "pub struct Point {\n" +
    "  x : Int\n" +
    "  y : Int\n" +
    "}\n" +
    "impl Show for Int {\n" +
    "  fn show(self : Int) -> String { self.to_string() }\n" +
    "}\n" +
    "impl Hash for Int {\n" +
    "  fn hash(self : Int) -> Int { self * 31 }\n" +
    "}\n" +
    "impl Show for Point {\n" +
    "  fn show(self : Point) -> String { \"Point(\" + self.x.to_string() + \",\" + self.y.to_string() + \")\" }\n" +
    "}\n" +
    "fn format_pair[A : Show, B : Show](a : A, b : B) -> String {\n" +
    "  a.show() + \":\" + b.show()\n" +
    "}\n" +
    "fn hash_and_show[T : Show + Hash](x : T) -> String {\n" +
    "  x.show() + \"#\" + x.hash().to_string()\n" +
    "}\n" +
    "pub fn main() -> Int {\n" +
    "  let pt = Point::{ x: 1, y: 2 }\n" +
    "  let s1 = format_pair(42, pt)\n" +
    "  let s2 = hash_and_show(7)\n" +
    "  let s3 = pt.show()\n" +
    "  s1.length() + s2.length() + s3.length()\n" +
    "}\n"
  let cr = @core.check_source_files("p12a_trait_ok", ["p12a_trait_ok.pion"], [src])
  assert_eq(cr.diagnostics.length(), 0)
  let sig = @core.cli_emit_sig("p12a_trait_ok", ["p12a_trait_ok.pion"], [src])
  assert_eq(sig.contains("trait Show"), true)
  assert_eq(sig.contains("impl Show for Point"), true)
}

///|
test "p12a: trait errors E_UNKNOWN_TRAIT E_TRAIT_METHOD_MISSING E_TRAIT_METHOD_SIGNATURE E_TRAIT_NOT_IMPLEMENTED" {
  let src_unknown =
    "impl Ghost for Int {\n" +
    "  fn boo(self : Int) -> Int { self }\n" +
    "}\n" +
    "pub fn main() -> Int { 0 }\n"
  let cr1 = @core.check_source_files("t1", ["t1.pion"], [src_unknown])
  assert_eq(cr1.diagnostics.length() > 0, true)
  assert_eq(cr1.diagnostics[0].code, "E_UNKNOWN_TRAIT")

  let src_missing =
    "trait Show {\n" +
    "  show(self : Self) -> String\n" +
    "}\n" +
    "impl Show for Int {\n" +
    "}\n" +
    "pub fn main() -> Int { 0 }\n"
  let cr2 = @core.check_source_files("t2", ["t2.pion"], [src_missing])
  assert_eq(cr2.diagnostics.length() > 0, true)
  assert_eq(cr2.diagnostics[0].code, "E_TRAIT_METHOD_MISSING")

  let src_sig =
    "trait Show {\n" +
    "  show(self : Self) -> String\n" +
    "}\n" +
    "impl Show for Int {\n" +
    "  fn show(self : Int) -> Int { self }\n" +
    "}\n" +
    "pub fn main() -> Int { 0 }\n"
  let cr3 = @core.check_source_files("t3", ["t3.pion"], [src_sig])
  assert_eq(cr3.diagnostics.length() > 0, true)
  assert_eq(cr3.diagnostics[0].code, "E_TRAIT_METHOD_SIGNATURE")

  let src_not_impl =
    "trait Show {\n" +
    "  show(self : Self) -> String\n" +
    "}\n" +
    "struct Bare { v : Int }\n" +
    "fn render[T : Show](x : T) -> String { x.show() }\n" +
    "pub fn main() -> Int {\n" +
    "  let b = Bare::{ v: 1 }\n" +
    "  let _ = render(b)\n" +
    "  0\n" +
    "}\n"
  let cr4 = @core.check_source_files("t4", ["t4.pion"], [src_not_impl])
  assert_eq(cr4.diagnostics.length() > 0, true)
  assert_eq(cr4.diagnostics[0].code, "E_TRAIT_NOT_IMPLEMENTED")
  assert_eq(cr4.diagnostics[0].expected, "impl Show for Bare")
}

///|
test "p13a: runtime primitives typecheck, World is explicit for TCP/sleep" {
  let ok_src =
    "pub fn main(world : World) -> Int {\n" +
    "  let p = ptr_alloc(16L)\n" +
    "  ptr_write_i64(p, 0L, 7L)\n" +
    "  ptr_write_i32(p, 8L, 3)\n" +
    "  ptr_write_ptr(p, 8L, ptr_offset(p, 4L))\n" +
    "  let s : String = cstr_to_str(ptr_read_ptr(p, 8L))\n" +
    "  let a : Int64 = ptr_read_i64(p, 0L)\n" +
    "  let b : Int = ptr_read_i32(p, 8L)\n" +
    "  ptr_free(p)\n" +
    "  let fd = tcp_listen(world, \"127.0.0.1\", 0)\n" +
    "  let port : Int = tcp_local_port(world, fd)\n" +
    "  let c = tcp_connect(world, \"127.0.0.1\", port)\n" +
    "  let n : Int = tcp_write(world, c, s)\n" +
    "  let r : String = tcp_read(world, tcp_accept(world, fd), 64)\n" +
    "  tcp_close(world, c)\n" +
    "  sleep_ms(world, 1)\n" +
    "  a.to_int() + b + n + r.length()\n" +
    "}\n"
  let ok_cr = @core.check_source_files("p13a_prims", ["p13a_prims.pion"], [ok_src])
  assert_true(ok_cr.diagnostics.length() == 0, "prims ok: " + @core.check_result_to_json(ok_cr.diagnostics))

  // World in scope is not enough: TCP primitives take it as their first argument.
  let no_w =
    "pub fn main(world : World) -> Int {\n" +
    "  tcp_listen(\"127.0.0.1\", 0)\n" +
    "}\n"
  let no_w_json = @core.check_result_to_json(
    @core.check_source_files("p13a_now", ["p13a_now.pion"], [no_w]).diagnostics,
  )
  assert_true(str_contains(no_w_json, "E_CAPABILITY_MISSING"), "missing explicit World: " + no_w_json)

  let pure_fn =
    "pub fn f() -> Unit {\n" +
    "  sleep_ms(5)\n" +
    "}\n"
  let pure_json = @core.check_result_to_json(
    @core.check_source_files("p13a_pure", ["p13a_pure.pion"], [pure_fn]).diagnostics,
  )
  assert_true(str_contains(pure_json, "E_CAPABILITY_MISSING"), "sleep_ms without World: " + pure_json)

  let bad_ty =
    "pub fn main(world : World) -> Int {\n" +
    "  let p = ptr_alloc(8)\n" +
    "  tcp_write(world, 1, 2)\n" +
    "}\n"
  let bad_json = @core.check_result_to_json(
    @core.check_source_files("p13a_bad", ["p13a_bad.pion"], [bad_ty]).diagnostics,
  )
  assert_true(str_contains(bad_json, "argument 3 of `tcp_write` expects `String`"), "tcp_write arg type: " + bad_json)
}

///|
test "p13a: cross-package trait impls are qualified on import" {
  let lib_src =
    "pub trait ToJson {\n" +
    "  to_json(self : Self) -> String\n" +
    "}\n" +
    "pub struct Point {\n" +
    "  x : Int\n" +
    "}\n" +
    "impl ToJson for Int {\n" +
    "  fn to_json(self : Int) -> String { self.to_string() }\n" +
    "}\n" +
    "impl ToJson for Point {\n" +
    "  fn to_json(self : Point) -> String { \"P\" + self.x.to_string() }\n" +
    "}\n" +
    "pub fn encode[T : ToJson](v : T) -> String {\n" +
    "  \"<\" + v.to_json() + \">\"\n" +
    "}\n"
  let lib_cr = @core.check_source_files_with_imports("lib", ["lib.pion"], [lib_src], [], true)
  assert_true(lib_cr.diagnostics.length() == 0, "lib check")
  // A package exporting a bounded generic fn has no body-less stub.
  assert_true(@core.emit_pion_stub(lib_cr.pkg) == "", "bounded pub fn disables the stub")
  let lib_imp = @core.imported_pkg_new("lib", lib_cr.tc)
  let app_src =
    "import \"lib\" as l\n" +
    "pub fn main() -> Int {\n" +
    "  let p = l::Point::{ x: 3 }\n" +
    "  let a = p.to_json()\n" +
    "  let b = (4).to_json()\n" +
    "  let c = l::encode(p) + l::encode(5)\n" +
    "  a.length() + b.length() + c.length()\n" +
    "}\n"
  let app_cr = @core.check_source_files_with_imports("app", ["app.pion"], [app_src], [lib_imp], true)
  assert_true(
    app_cr.diagnostics.length() == 0,
    "app check: " + @core.check_result_to_json(app_cr.diagnostics),
  )
  let ssa = @core.emit_qbe_package_multi(app_cr.pkg, app_cr.tc, false, true, ["lib"]).ssa
  let lib_ssa = @core.emit_qbe_package_multi(lib_cr.pkg, lib_cr.tc, false, false, []).ssa
  // Definition and cross-package call sites agree on the impl symbol names.
  assert_true(lib_ssa.contains("impl_ToJson_Point_to_json("), "lib defines Point impl")
  assert_true(lib_ssa.contains("impl_ToJson_Int_to_json("), "lib defines Int impl")
  assert_true(ssa.contains("impl_ToJson_Point_to_json("), "app calls Point impl")
  assert_true(ssa.contains("impl_ToJson_Int_to_json("), "app calls Int impl")
  assert_true(!ssa.contains("impl_lib__ToJson"), "no package-qualified impl symbol")

  let bad_src =
    "import \"lib\" as l\n" +
    "pub fn main() -> Int {\n" +
    "  l::encode(true).length()\n" +
    "}\n"
  let bad_json = @core.check_result_to_json(
    @core.check_source_files_with_imports("app", ["app.pion"], [bad_src], [lib_imp], true).diagnostics,
  )
  assert_true(str_contains(bad_json, "E_TRAIT_NOT_IMPLEMENTED"), "Bool has no ToJson impl: " + bad_json)
}

///|
test "p13a: pion.toml [link] libs and doc json" {
  let toml =
    "[package]\n" +
    "name = \"db\"\n" +
    "[link]\n" +
    "libs = [\"sqlite3\", \"z\", \"sqlite3\"]\n" +
    "lib = \"m\"\n"
  match @core.parse_pion_toml(toml) {
    Ok(m) => {
      assert_true(m.link_libs.length() == 3, "3 unique libs")
      assert_true(m.link_libs[0] == "sqlite3" && m.link_libs[1] == "z" && m.link_libs[2] == "m", "lib order")
    }
    Err(e) => abort("parse_pion_toml failed: " + e)
  }
  match @core.parse_pion_toml("[package]\nname = \"x\"\n[link]\nlibs = [sqlite3]\n") {
    Ok(_) => abort("unquoted lib must fail")
    Err(e) => assert_true(str_contains(e, "pion.toml line 4"), "error line: " + e)
  }
  let src =
    "pub struct P {\n  pub x : Int\n}\n" +
    "pub trait T {\n  t(self : Self) -> Int\n}\n" +
    "impl T for P {\n  fn t(self : P) -> Int { self.x }\n}\n" +
    "pub let K : Int = 1\n" +
    "fn hidden() -> Int { 0 }\n" +
    "pub fn get(p : P) -> Int { p.x }\n"
  let pkg = @core.parse_package("docpkg", ["d.pion"], [src])
  let j = @core.doc_packages_json([pkg])
  assert_true(str_contains(j, "{\"packages\":[{\"name\":\"docpkg\",\"items\":["), "doc json head: " + j)
  assert_true(str_contains(j, "\"kind\":\"struct\",\"name\":\"P\""), "struct item")
  assert_true(str_contains(j, "\"kind\":\"impl\",\"name\":\"T for P\""), "impl item")
  assert_true(str_contains(j, "\"kind\":\"const\",\"name\":\"K\""), "const item")
  assert_true(str_contains(j, "\"sig\":\"fn get(p: P) -> Int\""), "fn sig")
  assert_true(!str_contains(j, "hidden"), "private fn omitted")
  let t = @core.doc_package_text(pkg)
  assert_true(str_contains(t, "package docpkg\n  struct P { x: Int }\n"), "doc text: " + t)
}

///|
test "p13b: fmt keeps non-ASCII UTF-8 text in strings, comments, chars and code" {
  let src =
    "// 中文注释：键值服务   保持原样\n" +
    "pub fn greet(名 : String) -> String {\n" +
    "      let   s = \"你好，\" +   名 + \"！🚀\"   // 行尾注释  ✓\n" +
    "  let c = '中'\n" +
    "        s\n" +
    "}\n"
  let expected =
    "// 中文注释：键值服务   保持原样\n" +
    "pub fn greet(名 : String) -> String {\n" +
    "  let s = \"你好，\" + 名 + \"！🚀\" // 行尾注释  ✓\n" +
    "  let c = '中'\n" +
    "  s\n" +
    "}\n"
  let out1 = @core.format_source(src)
  assert_true(out1 == expected, "first pass:\n" + out1)
  assert_true(@core.format_source(out1) == out1, "idempotent")
}

///|
test "p13b: UTF-8 scalar helpers decode the host string encoding" {
  let s = "a中🚀"
  let utf8 = @core.host_str_is_utf8()
  assert_true(!utf8, "Stage 0 MoonBit strings are UTF-16")
  assert_true(@core.str_scalar_at(s, 0, utf8) == 97, "ascii")
  assert_true(@core.str_scalar_at(s, 1, utf8) == 0x4E2D, "BMP scalar")
  assert_true(@core.str_scalar_len(s, 2, utf8) == 2, "surrogate pair is 2 UTF-16 units")
  assert_true(@core.str_scalar_at(s, 2, utf8) == 0x1F680, "astral scalar")
  let sb = StringBuilder()
  @core.sb_write_range(sb, s, 1, s.length())
  assert_true(sb.to_string() == "中🚀", "verbatim range copy")
}

///|
test "p13b: Mutex[Map[String, V]] with Send values is Send, Ptr values are not" {
  let ok_src =
    "pub fn main(world : World) -> Int {\n" +
    "  let kv : Mutex[Map[String, String]] = Mutex::new(Map::new())\n" +
    "  scope(world, fn(s : Scope) -> Unit {\n" +
    "    spawn(s, fn() -> Unit {\n" +
    "      let m = kv.lock()\n" +
    "      m.set(\"k\", \"v\")\n" +
    "      kv.unlock()\n" +
    "    })\n" +
    "  })\n" +
    "  0\n" +
    "}\n"
  let (ok1, json1, _) = check_one(ok_src)
  assert_true(ok1, "Mutex[Map[String, String]] spawn capture: " + json1)
  let bad_src =
    "pub fn main(world : World) -> Int {\n" +
    "  let kv : Mutex[Map[String, Ptr]] = Mutex::new(Map::new())\n" +
    "  scope(world, fn(s : Scope) -> Unit {\n" +
    "    spawn(s, fn() -> Unit {\n" +
    "      let _ = kv.lock()\n" +
    "      kv.unlock()\n" +
    "    })\n" +
    "  })\n" +
    "  0\n" +
    "}\n"
  let (ok2, json2, _) = check_one(bad_src)
  assert_true(!ok2 && str_contains(json2, "E_NOT_SEND"), "Ptr map values stay !Send: " + json2)
}

///|
test "p13b: spawned workers may capture the World capability" {
  let src =
    "pub fn serve(world : World, fds : Channel[Int]) -> Unit {\n" +
    "  scope(world, fn(s : Scope) -> Unit {\n" +
    "    spawn(s, fn() -> Unit {\n" +
    "      while true {\n" +
    "        match fds.recv() {\n" +
    "          Some(fd) => {\n" +
    "            let _ = tcp_write(world, fd, \"ok\")\n" +
    "            tcp_close(world, fd)\n" +
    "          }\n" +
    "          None => break\n" +
    "        }\n" +
    "      }\n" +
    "    })\n" +
    "  })\n" +
    "}\n"
  let (ok, json, _) = check_one(src)
  assert_true(ok, "World capture in spawn: " + json)
}

///|
test "p13b: imported bounded generic fn resolves its own package's names" {
  let lib_src =
    "pub trait Show {\n" +
    "  show(self : Self) -> String\n" +
    "}\n" +
    "pub enum Wrapped {\n" +
    "  W(String)\n" +
    "}\n" +
    "impl Show for Int {\n" +
    "  fn show(self : Int) -> String { self.to_string() }\n" +
    "}\n" +
    "pub fn wrap(s : String) -> String {\n" +
    "  \"<\" + s + \">\"\n" +
    "}\n" +
    "pub fn unwrap(w : Wrapped) -> String {\n" +
    "  match w {\n" +
    "    W(s) => s\n" +
    "  }\n" +
    "}\n" +
    "pub fn render[T : Show](v : T) -> String {\n" +
    "  unwrap(W(wrap(v.show())))\n" +
    "}\n"
  let lib_cr = @core.check_source_files_with_imports("lib", ["lib.pion"], [lib_src], [], true)
  assert_true(lib_cr.diagnostics.length() == 0, "lib check")
  let lib_imp = @core.imported_pkg_new("lib", lib_cr.tc)
  let app_src =
    "import \"lib\" as l\n" +
    "pub struct P {\n" +
    "  x : Int\n" +
    "}\n" +
    "impl l::Show for P {\n" +
    "  fn show(self : P) -> String { \"P\" + self.x.to_string() }\n" +
    "}\n" +
    "fn wrap(s : String) -> String {\n" +
    "  s\n" +
    "}\n" +
    "pub fn main() -> Int {\n" +
    "  (l::render(P::{ x: 1 }) + l::render(2) + wrap(\"\")).length()\n" +
    "}\n"
  let app_cr = @core.check_source_files_with_imports("app", ["app.pion"], [app_src], [lib_imp], true)
  assert_true(
    app_cr.diagnostics.length() == 0,
    "app check: " + @core.check_result_to_json(app_cr.diagnostics),
  )
  let ssa = @core.emit_qbe_package_multi(app_cr.pkg, app_cr.tc, false, true, ["lib"]).ssa
  // The monomorphized `render` bodies call lib's `wrap` / `unwrap`, never app's `wrap`.
  assert_true(ssa.contains("render__mono"), "render instantiated in app")
  assert_true(ssa.contains("$pion_pkg_lib_fn_wrap("), "lib::wrap called from the mono body:\n" + ssa)
  assert_true(ssa.contains("$pion_pkg_lib_fn_unwrap("), "lib::unwrap called from the mono body")
}

///|
test "p15: statement-position Result is E_UNHANDLED_RESULT, let _ / tail / ? are fine" {
  let prelude =
    "fn parse(s : String) -> Result[Int, String] {\n" +
    "  if s.length() > 0 { Ok(1) } else { Err(\"empty\") }\n" +
    "}\n"
  let bad = prelude +
    "pub fn main() -> Int {\n" +
    "  parse(\"x\")\n" +
    "  0\n" +
    "}\n"
  let (ok1, json1, d1) = check_one(bad)
  assert_true(!ok1, "discarded Result must error")
  assert_eq(d1.length(), 1)
  assert_eq(d1[0].code, "E_UNHANDLED_RESULT")
  assert_true(d1[0].fixit.contains("let _ ="), json1)
  let in_loop = prelude +
    "pub fn main() -> Int {\n" +
    "  for i in 0..3 {\n" +
    "    parse(i.to_string())\n" +
    "  }\n" +
    "  0\n" +
    "}\n"
  let (ok2, _, d2) = check_one(in_loop)
  assert_true(!ok2, "Result discarded as a loop body tail must error")
  assert_eq(d2[0].code, "E_UNHANDLED_RESULT")
  let good = prelude +
    "fn twice(s : String) -> Result[Int, String] {\n" +
    "  parse(s)?\n" +
    "  parse(s)\n" +
    "}\n" +
    "fn pick(b : Bool) -> Result[Int, String] {\n" +
    "  if b { parse(\"a\") } else { parse(\"\") }\n" +
    "}\n" +
    "pub fn main() -> Int {\n" +
    "  let _ = parse(\"x\")\n" +
    "  let _ = twice(\"y\")\n" +
    "  let _ = pick(true)\n" +
    "  match parse(\"z\") {\n" +
    "    Ok(n) => n\n" +
    "    Err(_) => 0\n" +
    "  }\n" +
    "}\n"
  let (ok3, json3, _) = check_one(good)
  assert_true(ok3, "explicit discard, tail and ? are allowed: " + json3)
}

///|
test "p15: == on Option/Result/payload enums is rejected, payload-less enums allowed" {
  let src =
    "enum Color {\n" +
    "  Red\n" +
    "  Green\n" +
    "}\n" +
    "enum Shape {\n" +
    "  Dot\n" +
    "  Circle(Int)\n" +
    "}\n" +
    "fn find(x : Int) -> Option[Int] {\n" +
    "  if x > 0 { Some(x) } else { None }\n" +
    "}\n" +
    "fn r(x : Int) -> Result[Int, String] {\n" +
    "  Ok(x)\n" +
    "}\n" +
    "pub fn main() -> Int {\n" +
    "  let a = find(1) == Some(1)\n" +
    "  let b = r(1) != Ok(1)\n" +
    "  let c = Circle(1) == Dot\n" +
    "  let d = Red == Green\n" +
    "  let e = \"s\" == \"s\"\n" +
    "  if a || b || c || d || e { 1 } else { 0 }\n" +
    "}\n"
  let (ok, json, ds) = check_one(src)
  assert_true(!ok, "must reject pointer-identity ==")
  assert_true(ds.length() == 3, json)
  assert_eq(ds[0].code, "E_TYPE_MISMATCH")
  assert_true(ds[0].message.contains("Option[Int]"), json)
  assert_true(ds[0].message.contains("no implicit pointer-identity comparison"), json)
  assert_true(ds[0].fixit.contains("use `match`"), json)
  assert_true(ds[1].message.contains("`!=`"), json)
  assert_true(ds[1].message.contains("Result[Int, String]"), json)
  assert_true(ds[2].message.contains("Shape"), json)
}

///|
/// Applies `edits` that target `file` to `src` (1-based line/col, end
/// exclusive), latest position first so earlier offsets stay valid.
fn apply_edits(src : String, file : String, edits : Array[@core.TextEdit]) -> String {
  let starts : Array[Int] = [0]
  let mut i = 0
  while i < src.length() {
    if @core.str_code_at(src, i) == 10 {
      starts.push(i + 1)
    }
    i = i + 1
  }
  let offs : Array[Int] = []
  let ends : Array[Int] = []
  let reps : Array[String] = []
  let mut k = 0
  while k < edits.length() {
    let e = edits[k]
    if e.file == file {
      offs.push(starts[e.line - 1] + e.col - 1)
      ends.push(starts[e.end_line - 1] + e.end_col - 1)
      reps.push(e.replacement)
    }
    k = k + 1
  }
  let mut cur = src
  let used : Array[Bool] = []
  let mut u = 0
  while u < offs.length() {
    used.push(false)
    u = u + 1
  }
  let mut done = 0
  while done < offs.length() {
    let mut best = -1
    let mut j = 0
    while j < offs.length() {
      if !used[j] && (best < 0 || offs[j] > offs[best]) {
        best = j
      }
      j = j + 1
    }
    used[best] = true
    let sb = StringBuilder()
    @core.sb_write_range(sb, cur, 0, offs[best])
    sb.write_string(reps[best])
    @core.sb_write_range(sb, cur, ends[best], cur.length())
    cur = sb.to_string()
    done = done + 1
  }
  cur
}

///|
fn all_edits(diags : Array[@core.Diagnostic]) -> Array[@core.TextEdit] {
  let out : Array[@core.TextEdit] = []
  let mut i = 0
  while i < diags.length() {
    let mut j = 0
    while j < diags[i].edits.length() {
      out.push(diags[i].edits[j])
      j = j + 1
    }
    i = i + 1
  }
  out
}

///|
/// Checks `src`, expects `code` with a machine-applicable edit, applies every
/// edit and expects the patched program to check clean.
fn expect_edit_fixes(src : String, code : String, want_patched : String) -> Unit {
  let (ok, json, diags) = check_one(src)
  assert_true(!ok, "expected " + code + ": " + json)
  let mut found = false
  let mut i = 0
  while i < diags.length() {
    if diags[i].code == code && diags[i].edits.length() > 0 {
      found = true
    }
    i = i + 1
  }
  assert_true(found, code + " carries edits: " + json)
  assert_true(str_contains(json, "\"edits\":[{\"file\":\"test.pion\""), json)
  let patched = apply_edits(src, "test.pion", all_edits(diags))
  assert_true(str_contains(patched, want_patched), "patched:\n" + patched)
  let (ok2, json2, _) = check_one(patched)
  assert_true(ok2, "patched program must check clean: " + json2 + "\n" + patched)
}

///|
test "p17a: diagnostics without a patch keep the compact JSON shape" {
  let (_, json, _) = check_one("pub fn f() -> Int {\n  unknown_var\n}\n")
  assert_true(!str_contains(json, "edits"), json)
}

///|
test "p17a: E_MISSING_TYPE edit inserts the inferred return type" {
  let src =
    "fn add(a : Int, b : Int) {\n" +
    "  a + b\n" +
    "}\n" +
    "fn names() {\n" +
    "  [\"a\"]\n" +
    "}\n" +
    "pub fn main() -> Int {\n" +
    "  add(1, 2) + names().length()\n" +
    "}\n"
  expect_edit_fixes(src, "E_MISSING_TYPE", "fn add(a : Int, b : Int) -> Int {")
  let (_, _, diags) = check_one(src)
  assert_eq(diags[0].edits[0].line, 1)
  assert_eq(diags[0].edits[0].col, 26)
  assert_eq(diags[0].edits[0].replacement, "-> Int ")
  assert_eq(diags[1].edits[0].replacement, "-> Array[String] ")
}

///|
test "p17a: reassigning an immutable let gets `mut ` at the declaration" {
  let src =
    "pub fn main() -> Int {\n" +
    "  let total = 0\n" +
    "  for i in 0..3 {\n" +
    "    total = total + i\n" +
    "  }\n" +
    "  total = total + 1\n" +
    "  total\n" +
    "}\n"
  expect_edit_fixes(src, "E_TYPE_MISMATCH", "  let mut total = 0\n")
  let (_, _, diags) = check_one(src)
  // Two bad assignments, one patch.
  assert_eq(diags.length(), 2)
  assert_eq(all_edits(diags).length(), 1)
  assert_eq(diags[0].edits[0].line, 2)
  assert_eq(diags[0].edits[0].col, 7)
}

///|
test "p17a: E_UNHANDLED_RESULT edit prefixes `let _ = `" {
  let src =
    "fn parse(s : String) -> Result[Int, String] {\n" +
    "  if s.length() > 0 { Ok(1) } else { Err(\"empty\") }\n" +
    "}\n" +
    "pub fn main() -> Int {\n" +
    "  parse(\"x\")\n" +
    "  0\n" +
    "}\n"
  expect_edit_fixes(src, "E_UNHANDLED_RESULT", "  let _ = parse(\"x\")\n")
}

///|
test "p17a: E_NON_EXHAUSTIVE edit inserts the missing arms" {
  let src =
    "enum Color {\n" +
    "  Red\n" +
    "  Green\n" +
    "  Blue(Int, String)\n" +
    "}\n" +
    "pub fn code(c : Color) -> Int {\n" +
    "  match c {\n" +
    "    Red => 1\n" +
    "  }\n" +
    "}\n" +
    "pub fn pick(o : Option[Int]) -> Int {\n" +
    "  match o {\n" +
    "    Some(v) => v\n" +
    "  }\n" +
    "}\n"
  expect_edit_fixes(
    src,
    "E_NON_EXHAUSTIVE",
    "    Green => panic(\"unhandled Green\")\n    Blue(_, _) => panic(\"unhandled Blue(_, _)\")\n    Red => 1\n",
  )
  let (_, _, diags) = check_one(src)
  assert_eq(diags[1].edits[0].replacement, "None => panic(\"unhandled None\")\n    ")
}

///|
test "p17a: E_TRAIT_METHOD_SIGNATURE edit replaces the return type" {
  let src =
    "trait Show {\n" +
    "  show(self : Self) -> String\n" +
    "  tags(self : Self) -> Array[String]\n" +
    "}\n" +
    "struct P {\n" +
    "  x : Int\n" +
    "}\n" +
    "impl Show for P {\n" +
    "  fn show(self : P) -> Int {\n" +
    "    self.x.to_string()\n" +
    "  }\n" +
    "  fn tags(self : P) -> Array[Int] {\n" +
    "    [self.x.to_string()]\n" +
    "  }\n" +
    "}\n" +
    "pub fn main() -> Int {\n" +
    "  let p = P::{ x: 1 }\n" +
    "  p.show().length()\n" +
    "}\n"
  expect_edit_fixes(src, "E_TRAIT_METHOD_SIGNATURE", "  fn tags(self : P) -> Array[String] {\n")
  let (_, _, diags) = check_one(src)
  let e = diags[0].edits[0]
  assert_eq(e.line, 9)
  assert_eq(e.col, 24)
  assert_eq(e.end_col, 27)
  assert_eq(e.replacement, "String")
}

///|
test "p17a: E_PRIVATE_SYMBOL edit marks the target declaration `pub `" {
  let lib_src =
    "pub fn api() -> Int {\n" +
    "  1\n" +
    "}\n" +
    "fn helper(x : Int) -> Int {\n" +
    "  x + 1\n" +
    "}\n"
  let app_src =
    "import \"lib\" as l\n" +
    "pub fn main() -> Int {\n" +
    "  l::api() + l::helper(2)\n" +
    "}\n"
  let lib_cr = @core.check_source_files_with_imports("lib", ["lib.pion"], [lib_src], [], true)
  assert_true(lib_cr.diagnostics.length() == 0, "lib check")
  let app_cr = @core.check_source_files_with_imports(
    "app",
    ["app.pion"],
    [app_src],
    [@core.imported_pkg_new("lib", lib_cr.tc)],
    true,
  )
  let json = @core.check_result_to_json(app_cr.diagnostics)
  assert_eq(app_cr.diagnostics.length(), 1)
  assert_eq(app_cr.diagnostics[0].code, "E_PRIVATE_SYMBOL")
  assert_true(
    str_contains(
      json,
      "\"edits\":[{\"file\":\"lib.pion\",\"line\":4,\"col\":1,\"end_line\":4,\"end_col\":1,\"replacement\":\"pub \"}]",
    ),
    json,
  )
  let fixed_lib = apply_edits(lib_src, "lib.pion", all_edits(app_cr.diagnostics))
  assert_true(str_contains(fixed_lib, "pub fn helper(x : Int) -> Int {"), fixed_lib)
  let lib2 = @core.check_source_files_with_imports("lib", ["lib.pion"], [fixed_lib], [], true)
  assert_true(lib2.diagnostics.length() == 0, "fixed lib check")
  let app2 = @core.check_source_files_with_imports(
    "app",
    ["app.pion"],
    [app_src],
    [@core.imported_pkg_new("lib", lib2.tc)],
    true,
  )
  assert_true(
    app2.diagnostics.length() == 0,
    "patched app: " + @core.check_result_to_json(app2.diagnostics),
  )
}

///|
test "p17a: String parsing, Option/Result helpers and expression debug_assert type-check" {
  let src =
    "fn half(n : Int) -> Result[Int, String] {\n" +
    "  if n % 2 == 0 { Ok(n / 2) } else { Err(\"odd\") }\n" +
    "}\n" +
    "pub fn main() -> Int {\n" +
    "  let a : Option[Int] = \"42\".to_int()\n" +
    "  let b : Option[Int64] = \"-9000000000\".to_int64()\n" +
    "  let c : Option[Double] = \"2.5\".to_double()\n" +
    "  let n = a.unwrap_or(0) + half(4).unwrap_or(-1)\n" +
    "  let flags = a.is_some() && !b.is_none() && c.is_some() && half(3).is_err() && half(2).is_ok()\n" +
    "  let names : Option[String] = None\n" +
    "  let s : String = names.unwrap_or(\"anon\")\n" +
    "  match a {\n" +
    "    Some(x) => debug_assert(x > 0, \"pos\")\n" +
    "    None => ()\n" +
    "  }\n" +
    "  let u : Unit = debug_assert(n > 0, \"n\")\n" +
    "  if flags { n + s.length() } else { 0 }\n" +
    "}\n"
  let (ok, json, _) = check_one(src)
  assert_true(ok, json)
  let bad =
    "pub fn main() -> Int {\n" +
    "  let a = \"1\".to_int()\n" +
    "  let x : Int = a\n" +
    "  a.unwrap_or(\"zero\") + \"2\".to_int(10).unwrap_or(0)\n" +
    "}\n"
  let (ok2, json2, d2) = check_one(bad)
  assert_true(!ok2, json2)
  assert_eq(d2.length(), 3)
  assert_true(str_contains(json2, "Option[Int]"), json2)
  assert_true(str_contains(json2, "`unwrap_or` default type mismatch"), json2)
  assert_true(str_contains(json2, "`to_int` takes no arguments"), json2)
}

///|
test "p17a: generic == is checked at each instantiation" {
  let prelude =
    "enum Color {\n" +
    "  Red\n" +
    "  Green\n" +
    "}\n" +
    "fn same[T](a : T, b : T) -> Bool {\n" +
    "  a == b\n" +
    "}\n" +
    "fn count_eq[U](xs : Array[U], x : U) -> Int {\n" +
    "  let mut n = 0\n" +
    "  for y in xs {\n" +
    "    if same(x, y) {\n" +
    "      n = n + 1\n" +
    "    }\n" +
    "  }\n" +
    "  n\n" +
    "}\n" +
    "fn first[T](xs : Array[T]) -> T {\n" +
    "  xs[0]\n" +
    "}\n"
  let good = prelude +
    "pub fn main() -> Int {\n" +
    "  let ok = same(1, 2) || same(\"a\", \"b\") || same(Red, Green)\n" +
    "  let opts : Array[Option[Int]] = [Some(1)]\n" +
    "  let _ = first(opts)\n" +
    "  let k = if ok { 1 } else { 0 }\n" +
    "  count_eq([\"a\", \"b\"], \"a\") + k\n" +
    "}\n"
  let (ok1, json1, _) = check_one(good)
  assert_true(ok1, "comparable instantiations: " + json1)
  let bad = prelude +
    "pub fn main() -> Int {\n" +
    "  let a = same(Some(1), None)\n" +
    "  let r : Result[Int, String] = Ok(1)\n" +
    "  let b = same(r, r)\n" +
    "  let opts : Array[Option[Int]] = [Some(1)]\n" +
    "  let k = if a || b { 1 } else { 0 }\n" +
    "  count_eq(opts, None) + k\n" +
    "}\n"
  let (ok2, json2, d2) = check_one(bad)
  assert_true(!ok2, json2)
  assert_eq(d2.length(), 3)
  assert_eq(d2[0].code, "E_TYPE_MISMATCH")
  assert_true(str_contains(d2[0].message, "`T` = `Option[Int]`"), json2)
  assert_true(str_contains(d2[1].message, "Result[Int, String]"), json2)
  // Propagated through the generic caller `count_eq`.
  assert_true(str_contains(d2[2].message, "generic `count_eq` compares `U`"), json2)
}

///|
test "p17a: Mutex[Array[T]] and Mutex[Map[String, Array[T]]] are Send, bare containers are not" {
  let ok_src =
    "pub fn main(world : World) -> Int {\n" +
    "  let log : Mutex[Array[String]] = Mutex::new([])\n" +
    "  let idx : Mutex[Map[String, Array[String]]] = Mutex::new(Map::new())\n" +
    "  let grid : Mutex[Array[Array[Int]]] = Mutex::new([])\n" +
    "  scope(world, fn(s : Scope) -> Unit {\n" +
    "    spawn(s, fn() -> Unit {\n" +
    "      let l = log.lock()\n" +
    "      l.push(\"x\")\n" +
    "      log.unlock()\n" +
    "      let m = idx.lock()\n" +
    "      m.set(\"k\", [\"v\"])\n" +
    "      idx.unlock()\n" +
    "      let _ = grid.lock()\n" +
    "      grid.unlock()\n" +
    "    })\n" +
    "  })\n" +
    "  0\n" +
    "}\n"
  let (ok1, json1, _) = check_one(ok_src)
  assert_true(ok1, json1)
  let bad_src =
    "pub fn run(world : World, p : Ptr) -> Int {\n" +
    "  let bare : Array[String] = []\n" +
    "  let ptrs : Mutex[Array[Ptr]] = Mutex::new([p])\n" +
    "  let fns : Mutex[Map[String, Array[(Int) -> Int]]] = Mutex::new(Map::new())\n" +
    "  scope(world, fn(s : Scope) -> Unit {\n" +
    "    spawn(s, fn() -> Unit {\n" +
    "      let _ = bare.length()\n" +
    "      let _ = ptrs.lock()\n" +
    "      ptrs.unlock()\n" +
    "      let _ = fns.lock()\n" +
    "      fns.unlock()\n" +
    "    })\n" +
    "  })\n" +
    "  0\n" +
    "}\n"
  let (ok2, json2, d2) = check_one(bad_src)
  assert_true(!ok2, json2)
  assert_eq(d2.length(), 3)
  assert_true(d2[0].code == "E_NOT_SEND" && d2[1].code == "E_NOT_SEND" && d2[2].code == "E_NOT_SEND", json2)
}

///|
test "p18: non-blocking IO and poll primitives typecheck behind an explicit World" {
  let ok_src =
    #|pub fn main(world : World) -> Int {
    #|  let lfd = tcp_listen_reuse(world, "127.0.0.1", 0)
    #|  let nb : Bool = tcp_set_nonblock(world, lfd, true)
    #|  let pfd = poll_create(world)
    #|  let added : Bool = poll_ctl(world, pfd, 1, lfd, 1)
    #|  let fds : Array[Int] = []
    #|  let evs : Array[Int] = []
    #|  let n : Int = poll_wait(world, pfd, fds, evs, 64, 0)
    #|  let c = tcp_accept_nb(world, lfd)
    #|  let buf = StringBuilder()
    #|  let r : Int = tcp_read_nb(world, c, buf, 16384)
    #|  let wr : Int = tcp_write_nb(world, c, "ok", 0)
    #|  poll_close(world, pfd)
    #|  if nb && added { n + r + wr } else { 0 }
    #|}
  let ok_cr = @core.check_source_files("p18_ok", ["p18_ok.pion"], [ok_src])
  assert_true(ok_cr.diagnostics.length() == 0, "p18 prims ok: " + @core.check_result_to_json(ok_cr.diagnostics))

  // A pure helper cannot reach the event loop: World must be the first argument.
  let no_w =
    #|pub fn f(pfd : Int) -> Int {
    #|  let fds : Array[Int] = []
    #|  let evs : Array[Int] = []
    #|  poll_wait(pfd, fds, evs, 64, 0)
    #|}
  let no_w_json = @core.check_result_to_json(
    @core.check_source_files("p18_now", ["p18_now.pion"], [no_w]).diagnostics,
  )
  assert_true(str_contains(no_w_json, "E_CAPABILITY_MISSING"), "poll_wait without World: " + no_w_json)
  assert_true(str_contains(no_w_json, "`poll_wait` requires an explicit `World`"), "poll_wait msg: " + no_w_json)

  let bad_ty =
    #|pub fn main(world : World) -> Int {
    #|  let fds : Array[String] = []
    #|  let evs : Array[Int] = []
    #|  let a = tcp_read_nb(world, 3, "not a builder", 16)
    #|  let b = tcp_set_nonblock(world, 3, 1)
    #|  poll_wait(world, 4, fds, evs, 8, 0) + a
    #|}
  let bad_json = @core.check_result_to_json(
    @core.check_source_files("p18_bad", ["p18_bad.pion"], [bad_ty]).diagnostics,
  )
  assert_true(
    str_contains(bad_json, "argument 3 of `tcp_read_nb` expects `StringBuilder`"),
    "tcp_read_nb arg type: " + bad_json,
  )
  assert_true(str_contains(bad_json, "argument 3 of `tcp_set_nonblock` expects `Bool`"), "nonblock arg: " + bad_json)
  assert_true(str_contains(bad_json, "argument 3 of `poll_wait` expects `Array[Int]`"), "poll_wait arg: " + bad_json)
}

///|
test "p19b: StringBuilder::length and closure return type checking" {
  let ok_src =
    #|pub fn f() -> Int {
    #|  let sb = StringBuilder()
    #|  sb.write_string("hello")
    #|  let n : Int = sb.length()
    #|  let g = fn(x : Int) -> String {
    #|    if x > 0 {
    #|      return "pos"
    #|    }
    #|    "nonpos"
    #|  }
    #|  let s : String = g(n)
    #|  s.length() + n
    #|}
  let ok_cr = @core.check_source_files("p19b_ok", ["p19b_ok.pion"], [ok_src])
  assert_true(
    ok_cr.diagnostics.length() == 0,
    "p19b closure return & sb.length ok: " + @core.check_result_to_json(ok_cr.diagnostics),
  )

  let bad_src =
    #|pub fn f() -> Int {
    #|  let g = fn(x : Int) -> String {
    #|    return x
    #|  }
    #|  let _ = g(1)
    #|  0
    #|}
  let bad_json = @core.check_result_to_json(
    @core.check_source_files("p19b_bad", ["p19b_bad.pion"], [bad_src]).diagnostics,
  )
  assert_true(
    str_contains(bad_json, "E_TYPE_MISMATCH") && str_contains(bad_json, "String"),
    "closure bad return should check against closure return type: " + bad_json,
  )
}

///|
test "p20a: dyn Trait implicit/explicit boxing, collections, Option, cross-pkg, and error checks" {
  let ok_src =
    #|pub trait Describe {
    #|  describe(self : Self) -> String
    #|  score(self : Self, bonus : Int) -> Int
    #|}
    #|pub struct Dog {
    #|  name : String
    #|}
    #|impl Describe for Dog {
    #|  fn describe(self : Dog) -> String {
    #|    "dog:" + self.name
    #|  }
    #|  fn score(self : Dog, bonus : Int) -> Int {
    #|    self.name.length() + bonus
    #|  }
    #|}
    #|impl Describe for Int {
    #|  fn describe(self : Int) -> String {
    #|    "int:" + self.to_string()
    #|  }
    #|  fn score(self : Int, bonus : Int) -> Int {
    #|    self + bonus
    #|  }
    #|}
    #|pub struct Boxed {
    #|  item : dyn Describe
    #|}
    #|fn render(x : dyn Describe) -> String {
    #|  x.describe() + ":" + x.score(1).to_string()
    #|}
    #|fn make_dyn(flag : Bool) -> dyn Describe {
    #|  if flag {
    #|    Dog::{ name: "rex" }
    #|  } else {
    #|    42
    #|  }
    #|}
    #|pub fn main() -> Int {
    #|  let a : dyn Describe = Dog::{ name: "fido" }
    #|  let b = 7 as dyn Describe
    #|  let items : Array[dyn Describe] = [Dog::{ name: "a" }, 10]
    #|  items.push(Dog::{ name: "b" })
    #|  items.push(99)
    #|  let opt : Option[dyn Describe] = Some(Dog::{ name: "c" })
    #|  let opt2 : Option[dyn Describe] = None
    #|  let w = Boxed::{ item: 5 }
    #|  let _ = render(Dog::{ name: "d" })
    #|  let _ = render(a)
    #|  let _ = render(b)
    #|  let _ = render(w.item)
    #|  let _ = render(make_dyn(true))
    #|  let _ = match opt {
    #|    Some(v) => v.describe()
    #|    None => ""
    #|  }
    #|  let _ = match opt2 {
    #|    Some(v) => v.describe()
    #|    None => ""
    #|  }
    #|  items.length()
    #|}
  let (ok, json, _) = check_one(ok_src)
  assert_true(ok, "dyn Trait ok: " + json)
  let pkg = @core.parse_package("demo", ["demo.pion"], [ok_src])
  let sig = @core.emit_pionsig(pkg)
  assert_true(str_contains(sig, "dyn Describe"), "pionsig dyn: " + sig)

  // Cross-package `dyn pkg::Trait`
  let lib_src =
    #|pub trait Greet {
    #|  greet(self : Self) -> String
    #|}
    #|pub struct Bot {
    #|  id : Int
    #|}
    #|impl Greet for Bot {
    #|  fn greet(self : Bot) -> String {
    #|    "bot" + self.id.to_string()
    #|  }
    #|}
  let app_src =
    #|import "lib" as l
    #|pub fn say(x : dyn l::Greet) -> String {
    #|  x.greet()
    #|}
    #|pub fn main() -> Int {
    #|  let b = l::Bot::{ id: 1 }
    #|  let xs : Array[dyn l::Greet] = [b]
    #|  say(xs[0]).length()
    #|}
  let lib_cr = @core.check_source_files_with_imports("lib", ["lib.pion"], [lib_src], [], true)
  assert_true(lib_cr.diagnostics.length() == 0, "lib check")
  let app_cr = @core.check_source_files_with_imports(
    "app",
    ["app.pion"],
    [app_src],
    [@core.imported_pkg_new("lib", lib_cr.tc)],
    true,
  )
  assert_true(
    app_cr.diagnostics.length() == 0,
    "cross-pkg dyn: " + @core.check_result_to_json(app_cr.diagnostics),
  )

  // Reject == on dyn Trait
  let eq_src =
    #|trait T {
    #|  f(self : Self) -> Int
    #|}
    #|impl T for Int {
    #|  fn f(self : Int) -> Int { self }
    #|}
    #|pub fn bad(a : dyn T, b : dyn T) -> Bool {
    #|  a == b
    #|}
  let (eq_ok, eq_json, _) = check_one(eq_src)
  assert_true(!eq_ok && str_contains(eq_json, "no implicit pointer-identity comparison"), eq_json)

  // Reject non-object-safe trait (returning Self)
  let nos_src =
    #|trait Clone {
    #|  clone(self : Self) -> Self
    #|}
    #|pub fn bad(x : dyn Clone) -> Int {
    #|  0
    #|}
  let (nos_ok, nos_json, _) = check_one(nos_src)
  assert_true(!nos_ok && str_contains(nos_json, "not object-safe"), nos_json)

  // Reject non-Send dyn Trait in spawn
  let send_src =
    #|trait T {
    #|  f(self : Self) -> Int
    #|}
    #|impl T for Int {
    #|  fn f(self : Int) -> Int { self }
    #|}
    #|pub fn main(world : World) -> Int {
    #|  let x : dyn T = 1
    #|  scope(world, fn(s : Scope) -> Unit {
    #|    spawn(s, fn() -> Unit {
    #|      let _ = x.f()
    #|    })
    #|  })
    #|  0
    #|}
  let (send_ok, send_json, _) = check_one(send_src)
  assert_true(!send_ok && str_contains(send_json, "E_NOT_SEND"), send_json)

  // Unimplemented type for dyn Trait emits E_TRAIT_NOT_IMPLEMENTED with impl edit
  let unimpl_src =
    "trait Describe {\n" +
    "  describe(self : Self) -> String\n" +
    "}\n" +
    "struct Cat {\n" +
    "  name : String\n" +
    "}\n" +
    "pub fn main() -> Int {\n" +
    "  let x : dyn Describe = Cat::{ name: \"m\" }\n" +
    "  x.describe().length()\n" +
    "}\n"
  expect_edit_fixes(unimpl_src, "E_TRAIT_NOT_IMPLEMENTED", "impl Describe for Cat {")
}

///|
test "p20a: 6 new machine-applicable edits complete 12/12 coverage" {
  // e01_type_mismatch: fn declared return type vs body type
  let e01 =
    "fn label(n : Int) -> Int {\n" +
    "  \"n=\" + n.to_string()\n" +
    "}\n" +
    "pub fn main(world : World) -> Int {\n" +
    "  io_println(world, label(3).to_string())\n" +
    "  0\n" +
    "}\n"
  expect_edit_fixes(e01, "E_TYPE_MISMATCH", "fn label(n : Int) -> String {")

  // e02_wrong_arity (extra argument)
  let e02_extra =
    "fn add(a : Int, b : Int) -> Int {\n" +
    "  a + b\n" +
    "}\n" +
    "pub fn main(world : World) -> Int {\n" +
    "  io_println(world, add(1, 2, 3).to_string())\n" +
    "  0\n" +
    "}\n"
  expect_edit_fixes(e02_extra, "E_TYPE_MISMATCH", "add(1, 2).to_string()")

  // e02_wrong_arity (missing argument)
  let e02_missing =
    "fn add(a : Int, b : Int) -> Int {\n" +
    "  a + b\n" +
    "}\n" +
    "pub fn main() -> Int {\n" +
    "  add(1)\n" +
    "}\n"
  expect_edit_fixes(e02_missing, "E_TYPE_MISMATCH", "add(1, 0)")

  // e03_unknown_field (Levenshtein <= 2 typo)
  let e03 =
    "pub struct User {\n" +
    "  name : String\n" +
    "  age : Int\n" +
    "}\n" +
    "pub fn main(world : World) -> Int {\n" +
    "  let u = User::{ name: \"ada\", age: 36 }\n" +
    "  io_println(world, u.agee.to_string())\n" +
    "  0\n" +
    "}\n"
  expect_edit_fixes(e03, "E_TYPE_MISMATCH", "u.age.to_string()")

  // e06_missing_trait_impl (generic bound)
  let e06 =
    "pub trait Describe {\n" +
    "  describe(self : Self) -> String\n" +
    "}\n" +
    "pub struct Point {\n" +
    "  x : Int\n" +
    "  y : Int\n" +
    "}\n" +
    "impl Describe for Int {\n" +
    "  fn describe(self : Int) -> String {\n" +
    "    \"int \" + self.to_string()\n" +
    "  }\n" +
    "}\n" +
    "fn show_all[T : Describe](x : T) -> String {\n" +
    "  x.describe()\n" +
    "}\n" +
    "pub fn main(world : World) -> Int {\n" +
    "  io_println(world, show_all(1))\n" +
    "  io_println(world, show_all(Point::{ x: 1, y: 2 }))\n" +
    "  0\n" +
    "}\n"
  expect_edit_fixes(e06, "E_TRAIT_NOT_IMPLEMENTED", "impl Describe for Point {")

  // e10_missing_capability (adds `world : World, ` to enclosing function)
  let e10 =
    "fn load_config(path : String) -> String {\n" +
    "  match fs_read(path) {\n" +
    "    Ok(s) => s\n" +
    "    Err(_) => \"\"\n" +
    "  }\n" +
    "}\n" +
    "pub fn main(world : World) -> Int {\n" +
    "  io_println(world, load_config(\"/etc/hosts\"))\n" +
    "  0\n" +
    "}\n"
  let (ok10, json10, diags10) = check_one(e10)
  assert_true(!ok10 && str_contains(json10, "E_CAPABILITY_MISSING"), json10)
  assert_true(all_edits(diags10).length() > 0, "e10 edits: " + json10)
  let patched10 = apply_edits(e10, "test.pion", all_edits(diags10))
  assert_true(
    str_contains(patched10, "fn load_config(world : World, path : String) -> String {"),
    patched10,
  )
  // Applying the edit removes E_CAPABILITY_MISSING; only caller arity remains.
  let (_, json10_2, _) = check_one(patched10)
  assert_true(!str_contains(json10_2, "E_CAPABILITY_MISSING"), json10_2)

  // e08_data_race_send (wraps non-Send Array in Mutex::new(...))
  let e08 =
    "pub fn main(world : World) -> Int {\n" +
    "  let hits : Array[Int] = []\n" +
    "  scope(world, fn(s : Scope) -> Unit {\n" +
    "    for w in 0..4 {\n" +
    "      spawn(s, fn() -> Unit {\n" +
    "        hits.push(w)\n" +
    "      })\n" +
    "    }\n" +
    "  })\n" +
    "  io_println(world, hits.length().to_string())\n" +
    "  0\n" +
    "}\n"
  let (ok08, json08, diags08) = check_one(e08)
  assert_true(!ok08 && str_contains(json08, "E_NOT_SEND"), json08)
  assert_true(all_edits(diags08).length() > 0, "e08 edits: " + json08)
  let patched08 = apply_edits(e08, "test.pion", all_edits(diags08))
  assert_true(
    str_contains(patched08, "let hits : Mutex[Array[Int]] = Mutex::new([])"),
    patched08,
  )
}

///|
test "p24a_map_key_and_empty_branch" {
  // Bug 5: Map[K, V] rejects non-String keys with E_MAP_KEY_TYPE
  let bad_map =
    #|pub fn f(m : Map[Int, String]) -> Int {
    #|  m.length()
    #|}
  let (ok_m, json_m, _) = check_one(bad_map)
  assert_true(!ok_m && str_contains(json_m, "E_MAP_KEY_TYPE"), json_m)

  // Map[String, Int] and generic Map[K, V] remain accepted
  let ok_map =
    #|pub fn g[K, V](m : Map[K, V]) -> Int {
    #|  m.length()
    #|}
    #|pub fn h(m : Map[String, Int]) -> Int {
    #|  m.length()
    #|}
  let (ok_g, json_g, _) = check_one(ok_map)
  assert_true(ok_g, json_g)

  // Bug 2: if/match with empty [] first branch infers concrete element type from other branch
  let ok_if =
    #|pub fn pick(cond : Bool, k : Int) -> Int {
    #|  let xs = if cond { [] } else { ["a", "b"] }
    #|  xs.push("c")
    #|  let ys = match k {
    #|    0 => []
    #|    _ => ["x", "y"]
    #|  }
    #|  ys.push("z")
    #|  xs.length() + ys.length()
    #|}
  let (ok_b2, json_b2, _) = check_one(ok_if)
  assert_true(ok_b2, json_b2)

  // Pushing wrong type into inferred Array[String] must fail type check
  let bad_if =
    #|pub fn bad_pick(cond : Bool) -> Int {
    #|  let xs = if cond { [] } else { ["a", "b"] }
    #|  xs.push(123)
    #|  xs.length()
    #|}
  let (ok_bad, json_bad, _) = check_one(bad_if)
  assert_true(!ok_bad && str_contains(json_bad, "E_TYPE_MISMATCH"), json_bad)
}
