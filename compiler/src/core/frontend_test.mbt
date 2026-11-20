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
  let cr = @core.check_source_files("testpkg", ["test.m2"], [src])
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
  let lr = @core.lex("sample.m2", src)
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
test "m2sig: stability across body edits and round-trip parse" {
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
  let sig1 = @core.cli_emit_sig("app", ["a.m2"], [v1])
  let sig2 = @core.cli_emit_sig("app", ["a.m2"], [v2])
  assert_true(sig1 == sig2, "m2sig must be byte-for-byte identical when only bodies change")
  match @core.parse_m2sig(sig1) {
    Ok(parsed) => {
      assert_true(parsed.pkg == "app", "parsed pkg name")
      assert_true(parsed.entries.length() == 2, "2 pub entries")
      assert_true(@core.serialize_m2sig(parsed) == sig1, "round-trip serialize matches")
    }
    Err(e) => abort("parse_m2sig failed: " + e)
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
  match @core.cli_query_json("defs", "demo", ["demo.m2"], [src]) {
    Ok(j) => {
      assert_true(str_contains(j, "\"defs\":["), "defs root")
      assert_true(str_contains(j, "\"name\":\"Item\""), "Item def")
      assert_true(str_contains(j, "\"kind\":\"fn\""), "fn kind")
    }
    Err(e) => abort(e)
  }
  match @core.cli_query_json("sig", "demo", ["demo.m2"], [src]) {
    Ok(j) => {
      assert_true(str_contains(j, "\"sig_hash\":"), "sig_hash")
      assert_true(str_contains(j, "\"exports\":["), "exports")
    }
    Err(e) => abort(e)
  }
  match @core.cli_query_json("callers", "demo", ["demo.m2"], [src]) {
    Ok(j) => {
      assert_true(str_contains(j, "\"callers\":["), "callers root")
      assert_true(str_contains(j, "\"helper\""), "calls helper")
      assert_true(str_contains(j, "\"io_println\""), "calls io_println")
    }
    Err(e) => abort(e)
  }
  match @core.cli_query_json("deps", "demo", ["demo.m2"], [src]) {
    Ok(j) => {
      assert_true(str_contains(j, "\"packages\":["), "packages root")
      assert_true(str_contains(j, "m2/runtime/world"), "world dep")
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
    ["math.m2"],
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
    ["app.m2"],
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
    ["bad.m2"],
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
    ["unk.m2"],
    [unk_app],
    imported,
    true,
  )
  let unk_json = @core.check_result_to_json(unk_cr.diagnostics)
  assert_true(str_contains(unk_json, "E_UNKNOWN_PACKAGE"), "expected E_UNKNOWN_PACKAGE")
}

///|
test "p6b: m2.toml parser, topo_sort, E_IMPORT_CYCLE, and workspace deps json" {
  let toml =
    "# sample manifest\n" +
    "[package]\n" +
    "name = \"app\"\n" +
    "version = \"0.1.0\"\n" +
    "\n" +
    "[dependencies]\n" +
    "math = { path = \"../math\" }\n" +
    "util = { path = \"./deps/util\" }\n"
  match @core.parse_m2_toml(toml) {
    Ok(m) => {
      assert_true(m.name == "app", "pkg name")
      assert_true(m.version == "0.1.0", "pkg version")
      assert_true(m.deps.length() == 2, "2 deps")
      assert_true(m.deps[0].name == "math" && m.deps[0].path == "../math", "dep 0")
      assert_true(m.deps[1].name == "util" && m.deps[1].path == "./deps/util", "dep 1")
    }
    Err(e) => abort("parse_m2_toml failed: " + e)
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
  let cr = @core.check_source_files("tpkg", ["t.m2"], [src])
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
    "  let r : String = s.replace(\"world\", \"m2\")\n" +
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
  let cr = @core.check_source_files("stdlib_ok", ["ok.m2"], [ok_src])
  assert_true(cr.diagnostics.length() == 0, "stdlib ok_src should have 0 diagnostics")

  let no_world =
    "pub fn bad_io() -> Int64 {\n" +
    "  fs_mtime_ms(\"/tmp/x\")\n" +
    "}\n"
  let cr_nw = @core.check_source_files("stdlib_nw", ["nw.m2"], [no_world])
  let nw_json = @core.check_result_to_json(cr_nw.diagnostics)
  assert_true(str_contains(nw_json, "E_CAPABILITY_MISSING"), "fs_mtime_ms requires World")

  let no_world_cap =
    "pub fn bad_exec() -> Result[String, String] {\n" +
    "  proc_exec_capture([\"echo\", \"hi\"])\n" +
    "}\n"
  let cr_ec = @core.check_source_files("stdlib_ec", ["ec.m2"], [no_world_cap])
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
  let cr_ns = @core.check_source_files("stdlib_ns", ["ns.m2"], [bytes_not_send])
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
  let cr = @core.check_source_files("p7a_ok", ["ok.m2"], [ok_src])
  assert_true(cr.diagnostics.length() == 0, "p7a ok_src should have 0 diagnostics")

  // `?` in non-Result function
  let bad_try1 =
    "fn f() -> Int {\n" +
    "  let r : Result[Int, String] = Ok(1)\n" +
    "  r?\n" +
    "}\n"
  let cr1 = @core.check_source_files("p7a_bad1", ["b1.m2"], [bad_try1])
  assert_true(str_contains(@core.check_result_to_json(cr1.diagnostics), "E_TYPE_MISMATCH"), "try in non-Result fn")

  // `?` with incompatible error type
  let bad_try2 =
    "fn f() -> Result[Int, Int] {\n" +
    "  let r : Result[Int, String] = Ok(1)\n" +
    "  Ok(r?)\n" +
    "}\n"
  let cr2 = @core.check_source_files("p7a_bad2", ["b2.m2"], [bad_try2])
  assert_true(str_contains(@core.check_result_to_json(cr2.diagnostics), "E_TYPE_MISMATCH"), "try err type mismatch")

  // `?` in top-level const
  let bad_try3 =
    "fn mk() -> Result[Int, String] { Ok(1) }\n" +
    "let BAD : Result[Int, String] = Ok(mk()?)\n"
  let cr3 = @core.check_source_files("p7a_bad3", ["b3.m2"], [bad_try3])
  assert_true(str_contains(@core.check_result_to_json(cr3.diagnostics), "E_TYPE_MISMATCH"), "try in top-level const")

  // `for x in non_array`
  let bad_for =
    "fn f() -> Unit {\n" +
    "  for x in 42 {\n" +
    "    let _ = x\n" +
    "  }\n" +
    "}\n"
  let cr4 = @core.check_source_files("p7a_bad4", ["b4.m2"], [bad_for])
  assert_true(str_contains(@core.check_result_to_json(cr4.diagnostics), "E_TYPE_MISMATCH"), "for-in requires Array")

  // `Array[Int]::join` rejected
  let bad_join =
    "fn f() -> String {\n" +
    "  let a : Array[Int] = [1, 2]\n" +
    "  a.join(\",\")\n" +
    "}\n"
  let cr5 = @core.check_source_files("p7a_bad5", ["b5.m2"], [bad_join])
  assert_true(str_contains(@core.check_result_to_json(cr5.diagnostics), "E_TYPE_MISMATCH"), "Array[Int]::join rejected")

  // `Array[Bool]::sort` rejected
  let bad_sort =
    "fn f() -> Unit {\n" +
    "  let a : Array[Bool] = [true, false]\n" +
    "  a.sort()\n" +
    "}\n"
  let cr6 = @core.check_source_files("p7a_bad6", ["b6.m2"], [bad_sort])
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
  let cr = @core.check_source_files("p8_ok", ["p8_ok.m2"], [ok_src])
  assert_true(cr.diagnostics.length() == 0, "p8 ok_src should have 0 diagnostics")

  // Arity mismatch in tuple destructuring
  let bad_arity =
    "fn f() -> Int {\n" +
    "  let (a, b) = (1, 2, 3)\n" +
    "  a + b\n" +
    "}\n"
  let cr1 = @core.check_source_files("p8_bad1", ["b1.m2"], [bad_arity])
  assert_true(str_contains(@core.check_result_to_json(cr1.diagnostics), "E_TYPE_MISMATCH"), "tuple arity mismatch")

  // Destructuring non-tuple
  let bad_nontup =
    "fn f() -> Int {\n" +
    "  let (a, b) = 42\n" +
    "  a + b\n" +
    "}\n"
  let cr2 = @core.check_source_files("p8_bad2", ["b2.m2"], [bad_nontup])
  assert_true(str_contains(@core.check_result_to_json(cr2.diagnostics), "E_TYPE_MISMATCH"), "destructure non-tuple")

  // Out-of-range tuple index
  let bad_idx =
    "fn f() -> Int {\n" +
    "  let t = (1, 2)\n" +
    "  t.2\n" +
    "}\n"
  let cr3 = @core.check_source_files("p8_bad3", ["b3.m2"], [bad_idx])
  assert_true(str_contains(@core.check_result_to_json(cr3.diagnostics), "E_TYPE_MISMATCH"), "tuple index out of bounds")

  // Guarded arm does NOT satisfy exhaustiveness
  let bad_exh =
    "fn f(opt : Option[Int]) -> Int {\n" +
    "  match opt {\n" +
    "    Some(x) if x > 0 => x\n" +
    "    None => 0\n" +
    "  }\n" +
    "}\n"
  let cr4 = @core.check_source_files("p8_bad4", ["b4.m2"], [bad_exh])
  assert_true(str_contains(@core.check_result_to_json(cr4.diagnostics), "E_NON_EXHAUSTIVE"), "guarded arm is non-exhaustive")

  // Non-Bool guard condition
  let bad_guard =
    "fn f(x : Int) -> Int {\n" +
    "  match x {\n" +
    "    n if n + 1 => n\n" +
    "    _ => 0\n" +
    "  }\n" +
    "}\n"
  let cr5 = @core.check_source_files("p8_bad5", ["b5.m2"], [bad_guard])
  assert_true(str_contains(@core.check_result_to_json(cr5.diagnostics), "E_TYPE_MISMATCH"), "non-Bool match guard")
}

///|
test "p10c: emit_m2_stub preserves imports, pub/private visibility, and cross-pkg types" {
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
  let az_cr = @core.check_source_files_with_imports("analyzer", ["analyzer.m2"], [az_src], [], true)
  assert_true(az_cr.diagnostics.length() == 0, "analyzer full check should pass")
  let az_stub = @core.emit_m2_stub(az_cr.pkg)
  assert_true(str_contains(az_stub, "pub val struct Stats"), "stub preserves pub val struct")
  assert_true(str_contains(az_stub, "pub enum Mode"), "stub preserves pub enum")
  assert_true(str_contains(az_stub, "pub let MAX_N : Int = panic()"), "stub preserves pub const")
  assert_true(str_contains(az_stub, "fn secret_helper(x : Int) -> Int { panic() }"), "stub preserves private fn for E_PRIVATE_SYMBOL")

  let az_stub_cr = @core.check_source_files_with_imports("analyzer", ["analyzer.m2stub"], [az_stub], [], true)
  assert_true(az_stub_cr.diagnostics.length() == 0, "analyzer stub should typecheck cleanly")
  let az_imp = @core.imported_pkg_new("analyzer", az_stub_cr.tc)

  let mid_src =
    "import \"analyzer\" as az\n" +
    "pub fn wrap(s : az::Stats) -> az::Stats {\n" +
    "  az::Stats::{ lines: s.lines + 1, words: s.words + az::MAX_N }\n" +
    "}\n"
  let mid_cr = @core.check_source_files_with_imports("mid", ["mid.m2"], [mid_src], [az_imp], true)
  assert_true(mid_cr.diagnostics.length() == 0, "mid full check against az stub should pass")
  let mid_stub = @core.emit_m2_stub(mid_cr.pkg)
  assert_true(str_contains(mid_stub, "import \"analyzer\" as az"), "mid stub preserves import declaration")
  let mid_stub_cr = @core.check_source_files_with_imports("mid", ["mid.m2stub"], [mid_stub], [az_imp], true)
  assert_true(mid_stub_cr.diagnostics.length() == 0, "mid stub should typecheck cleanly against az stub")
  let mid_imp = @core.imported_pkg_new("mid", mid_stub_cr.tc)

  let app_ok =
    "import \"analyzer\" as az\n" +
    "import \"mid\" as m\n" +
    "pub fn main() -> Int {\n" +
    "  let s = m::wrap(az::make_stats(3))\n" +
    "  s.lines + s.words\n" +
    "}\n"
  let app_cr = @core.check_source_files_with_imports("app", ["app.m2"], [app_ok], [az_imp, mid_imp], true)
  assert_true(app_cr.diagnostics.length() == 0, "app should typecheck cleanly against transitive stubs")

  let app_priv =
    "import \"analyzer\" as az\n" +
    "pub fn main() -> Int {\n" +
    "  az::secret_helper(1)\n" +
    "}\n"
  let priv_cr = @core.check_source_files_with_imports("app", ["app.m2"], [app_priv], [az_imp], true)
  assert_true(str_contains(@core.check_result_to_json(priv_cr.diagnostics), "E_PRIVATE_SYMBOL"), "stub must still reject private symbol with E_PRIVATE_SYMBOL")

  let app_bad_ty =
    "import \"mid\" as m\n" +
    "pub fn main() -> Int {\n" +
    "  let _ = m::wrap(42)\n" +
    "  0\n" +
    "}\n"
  let bad_ty_cr = @core.check_source_files_with_imports("app", ["app.m2"], [app_bad_ty], [az_imp, mid_imp], true)
  assert_true(str_contains(@core.check_result_to_json(bad_ty_cr.diagnostics), "E_TYPE_MISMATCH"), "stub must still reject type mismatch with E_TYPE_MISMATCH")
}
