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
