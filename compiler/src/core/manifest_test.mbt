///| P17-B: git dependencies, pion.lock, workspace test report, `pionc init` templates

///|
fn mf_check(cond : Bool, msg : String) -> Unit {
  if !cond {
    abort("ASSERTION FAILED: " + msg)
  }
}

///|
fn mf_has(haystack : String, needle : String) -> Bool {
  let hlen = haystack.length()
  let nlen = needle.length()
  let mut i = 0
  while i + nlen <= hlen {
    let mut j = 0
    while j < nlen &&
      @core.str_code_at(haystack, i + j) == @core.str_code_at(needle, j) {
      j = j + 1
    }
    if j == nlen {
      return true
    }
    i = i + 1
  }
  false
}

///|
test "p17b: pion.toml path and git dependencies" {
  let toml =
    "[package]\n" +
    "name = \"app\"\n" +
    "[dependencies]\n" +
    "local_dep = { path = \"./deps/local_dep\" }\n" +
    "legacy = \"../legacy\"\n" +
    "remote_lib = { git = \"https://github.com/org/repo.git\", tag = \"v0.1.0\" }\n" +
    "pinned = { git = \"file:///tmp/r.git\", rev = \"0123abc\", subdir = \"pkgs/sub\" }\n" +
    "tracking = { git = \"file:///tmp/r.git\", branch = \"main\" }\n" +
    "head = { git = \"file:///tmp/r.git\" }\n"
  match @core.parse_pion_toml(toml) {
    Ok(m) => {
      mf_check(m.deps.length() == 6, "6 deps")
      let d0 = m.deps[0]
      mf_check(d0.path == "./deps/local_dep" && !@core.manifest_dep_is_git(d0), "path dep")
      mf_check(m.deps[1].path == "../legacy" && m.deps[1].git == "", "bare string path dep")
      let d2 = m.deps[2]
      mf_check(@core.manifest_dep_is_git(d2), "git dep")
      mf_check(d2.git == "https://github.com/org/repo.git" && d2.tag == "v0.1.0", "git url + tag")
      mf_check(d2.path == "" && d2.subdir == "", "git dep has no path/subdir")
      mf_check(@core.manifest_dep_ref(d2) == "tag:v0.1.0", "tag ref")
      let d3 = m.deps[3]
      mf_check(d3.rev == "0123abc" && d3.subdir == "pkgs/sub", "rev + subdir")
      mf_check(@core.manifest_dep_ref(d3) == "rev:0123abc", "rev ref")
      mf_check(@core.manifest_dep_ref(m.deps[4]) == "branch:main", "branch ref")
      mf_check(@core.manifest_dep_ref(m.deps[5]) == "HEAD", "default HEAD ref")
    }
    Err(e) => abort("parse_pion_toml failed: " + e)
  }
  let bad : Array[String] = [
    "x = { git = \"u\", path = \"p\" }", "x = { git = \"u\", tag = \"a\", rev = \"b\" }",
    "x = { path = \"p\", tag = \"a\" }", "x = { path = \"p\", subdir = \"s\" }", "x = { version = \"1\" }",
  ]
  let mut i = 0
  while i < bad.length() {
    match @core.parse_pion_toml("[package]\nname = \"a\"\n[dependencies]\n" + bad[i] + "\n") {
      Ok(_) => abort("expected an error for " + bad[i])
      Err(e) => mf_check(mf_has(e, "pion.toml line 4"), "error names the line: " + e)
    }
    i = i + 1
  }
}

///|
test "p17b: pion.lock format is deterministic and round-trips" {
  let a = @core.lock_entry_new(
    "zeta", "file:///tmp/z.git", "tag:v1", "ffff000000000000000000000000000000000000",
    "",
  )
  let b = @core.lock_entry_new(
    "alpha", "file:///tmp/mono.git", "rev:abc", "abc0000000000000000000000000000000000000",
    "pkgs/sub",
  )
  let t1 = @core.format_pion_lock([a, b])
  let t2 = @core.format_pion_lock([b, a])
  mf_check(t1 == t2, "order-independent output")
  mf_check(mf_has(t1, "[[package]]\nname = \"alpha\""), "alpha table")
  mf_check(mf_has(t1, "subdir = \"pkgs/sub\""), "subdir written")
  mf_check(mf_has(t1, "subdir = \"\""), "empty subdir written")
  mf_check(
    mf_has(t1, "rev = \"ffff000000000000000000000000000000000000\""),
    "rev written",
  )
  match @core.parse_pion_lock(t1) {
    Ok(es) => {
      mf_check(es.length() == 2, "2 entries")
      mf_check(es[0].name == "alpha" && es[1].name == "zeta", "sorted by name")
      mf_check(es[0].git == "file:///tmp/mono.git" && es[0].subdir == "pkgs/sub", "alpha fields")
      mf_check(es[0].reference == "rev:abc", "alpha ref")
      mf_check(es[1].rev == "ffff000000000000000000000000000000000000", "zeta rev")
      mf_check(@core.format_pion_lock(es) == t1, "format(parse(x)) == x")
    }
    Err(e) => abort("parse_pion_lock failed: " + e)
  }
  match @core.parse_pion_lock("") {
    Ok(es) => mf_check(es.length() == 0, "empty lock")
    Err(e) => abort("empty lock failed: " + e)
  }
  match @core.parse_pion_lock("version = 1\n[[package]]\nname = \"x\"\n") {
    Ok(_) => abort("entry without git/rev must fail")
    Err(e) => mf_check(mf_has(e, "needs `name`, `git` and `rev`"), "missing fields: " + e)
  }
  match @core.parse_pion_lock("[package]\nname = \"x\"\n") {
    Ok(_) => abort("unknown table must fail")
    Err(e) => mf_check(mf_has(e, "unexpected table"), "unexpected table: " + e)
  }
}

///|
test "p17b: lock_find matches name, url, subdir and requested ref" {
  match @core.parse_pion_toml(
    "[package]\nname = \"a\"\n[dependencies]\nlib = { git = \"file:///r.git\", tag = \"v1\", subdir = \"s\" }\n",
  ) {
    Ok(m) => {
      let dep = m.deps[0]
      let hit = @core.lock_entry_new("lib", "file:///r.git", "tag:v1", "1111", "s")
      let other_tag = @core.lock_entry_new("lib", "file:///r.git", "tag:v2", "2222", "s")
      let other_sub = @core.lock_entry_new("lib", "file:///r.git", "tag:v1", "3333", "")
      match @core.lock_find([other_tag, other_sub, hit], dep) {
        Some(e) => mf_check(e.rev == "1111", "matching entry")
        None => abort("lock_find missed the matching entry")
      }
      match @core.lock_find([other_tag, other_sub], dep) {
        Some(_) => abort("stale lock entries must not match")
        None => ()
      }
      let acc : Array[@core.LockEntry] = []
      mf_check(@core.lock_add(acc, hit) is Ok(_), "first add")
      mf_check(@core.lock_add(acc, hit) is Ok(_), "same pin again")
      mf_check(acc.length() == 1, "deduplicated")
      let conflict = @core.lock_entry_new("lib", "file:///r.git", "tag:v1", "9999", "s")
      match @core.lock_add(acc, conflict) {
        Ok(_) => abort("conflicting revs must fail")
        Err(e) => mf_check(mf_has(e, "required as both"), "conflict message: " + e)
      }
    }
    Err(e) => abort("parse_pion_toml failed: " + e)
  }
}

///|
test "p17b: merged workspace test report" {
  let ok_json = @core.format_workspace_test_report_json(
    ["json", "app"],
    ["json", "app"],
    ["parse", "main"],
    [true, true],
  )
  mf_check(
    ok_json ==
    "{\"ok\":true,\"total\":2,\"passed\":2,\"failed\":0,\"packages\":[\"json\",\"app\"],\"tests\":[{\"pkg\":\"json\",\"name\":\"parse\",\"ok\":true},{\"pkg\":\"app\",\"name\":\"main\",\"ok\":true}]}",
    "ok report: " + ok_json,
  )
  let bad_json = @core.format_workspace_test_report_json(["a"], ["a"], ["t"], [false])
  mf_check(mf_has(bad_json, "{\"ok\":false,\"total\":1,\"passed\":0,\"failed\":1"), "failed report")
  let empty = @core.format_workspace_test_report_json([], [], [], [])
  mf_check(mf_has(empty, "\"ok\":true") && mf_has(empty, "\"failed\":0"), "empty report")
}

///|
test "p17b: pionc init templates are formatted and named from the directory" {
  mf_check(@core.init_package_name("/tmp/demo_app") == "demo_app", "plain name")
  mf_check(@core.init_package_name("/tmp/My-App/") == "my_app", "sanitized name")
  mf_check(@core.init_package_name("2fast") == "pkg_2fast", "leading digit")
  mf_check(@core.init_package_name("/") == "app", "fallback name")
  let toml = @core.init_pion_toml("demo_app")
  match @core.parse_pion_toml(toml) {
    Ok(m) => mf_check(m.name == "demo_app" && m.deps.length() == 0, "init manifest parses")
    Err(e) => abort("init manifest: " + e)
  }
  let main_src = @core.init_main_source("demo_app")
  let test_src = @core.init_test_source("demo_app")
  mf_check(@core.format_source(main_src) == main_src, "main template is fmt-clean")
  mf_check(@core.format_source(test_src) == test_src, "test template is fmt-clean")
  let cr = @core.check_source_files_full(
    "demo_app",
    ["src/main.pion", "main_test.pion"],
    [main_src, test_src],
  )
  mf_check(cr.diagnostics.length() == 0, "init templates type-check")
}

///|
test "p17b: workspace query covers every package" {
  let json_pkg = @core.parse_package(
    "json",
    ["std/json/src/json.pion"],
    ["pub fn parse(s : String) -> Int {\n  s.length()\n}\n"],
  )
  let app_pkg = @core.parse_package(
    "app",
    ["src/main.pion"],
    ["fn run() -> Int {\n  json::parse(\"x\")\n}\n"],
  )
  match @core.query_workspace_json("defs", [json_pkg, app_pkg]) {
    Ok(j) => {
      mf_check(mf_has(j, "{\"pkg\":\"json\",\"name\":\"parse\""), "json defs: " + j)
      mf_check(mf_has(j, "{\"pkg\":\"app\",\"name\":\"run\""), "app defs: " + j)
    }
    Err(e) => abort(e)
  }
  match @core.query_workspace_json("callers", [json_pkg, app_pkg]) {
    Ok(j) =>
      mf_check(
        mf_has(j, "{\"pkg\":\"app\",\"fn\":\"run\",\"calls\":[\"json::parse\"]}"),
        "cross-package call: " + j,
      )
    Err(e) => abort(e)
  }
  match @core.query_workspace_json("sig", [json_pkg, app_pkg]) {
    Ok(j) =>
      mf_check(
        mf_has(j, "{\"packages\":[{\"name\":\"json\",\"sig\":") &&
        mf_has(j, "{\"name\":\"app\",\"sig\":"),
        "sig: " + j,
      )
    Err(e) => abort(e)
  }
  mf_check(@core.query_workspace_json("bogus", [json_pkg]) is Err(_), "unknown kind")
  // Single-package output stays unchanged (no pkg key on callers).
  mf_check(
    @core.query_callers_json(app_pkg) ==
    "{\"callers\":[{\"fn\":\"run\",\"calls\":[\"json::parse\"]}]}",
    "single-package callers",
  )
}

///|
test "p20b: pion.toml [registry] url and registry/version dependency keys" {
  let toml =
    "[package]\nname = \"app\"\n\n[registry]\nurl = \"file:///srv/pion-index.git\"\n\n" +
    "[dependencies]\n" +
    "mylib = { git = \"file:///srv/mylib.git\", tag = \"v1\", version = \"1.0.0\", registry = \"file:///srv/pion-index.git\" }\n"
  match @core.parse_pion_toml(toml) {
    Ok(m) => {
      mf_check(m.registry == "file:///srv/pion-index.git", "[registry] url")
      mf_check(m.deps.length() == 1, "one dep")
      let d = m.deps[0]
      mf_check(d.tag == "v1" && d.version == "1.0.0", "tag + version")
      mf_check(d.registry == "file:///srv/pion-index.git", "dep registry")
      mf_check(@core.manifest_dep_ref(d) == "tag:v1", "registry dep ref is its tag")
    }
    Err(e) => abort("parse_pion_toml failed: " + e)
  }
  match @core.parse_pion_toml("[package]\nname = \"a\"\n[dependencies]\nx = { path = \"../x\", registry = \"r\" }\n") {
    Ok(_) => abort("path dep with registry must be rejected")
    Err(e) => mf_check(mf_has(e, "require `git"), "registry needs git: " + e)
  }
  match @core.parse_pion_toml("[package]\nname = \"a\"\n") {
    Ok(m) => mf_check(m.registry == "", "no registry by default")
    Err(e) => abort(e)
  }
}

///|
test "p20b: registry index entry parsing" {
  let txt = "# mylib\nname = \"mylib\"\nversion = \"2.0.0\"\ngit = \"file:///srv/mylib.git\"\ntag = \"v2\"\nsubdir = \"pkg\"\n"
  match @core.parse_registry_entry("mylib", txt) {
    Ok(e) => {
      mf_check(e.name == "mylib" && e.version == "2.0.0", "name + version")
      mf_check(e.git == "file:///srv/mylib.git" && e.tag == "v2", "git + tag")
      mf_check(e.subdir == "pkg" && e.rev == "" && e.branch == "", "subdir")
      let d = @core.registry_entry_dep(e, "file:///srv/idx.git")
      mf_check(d.name == "mylib" && d.registry == "file:///srv/idx.git", "dep from entry")
      mf_check(@core.manifest_dep_is_git(d) && d.path == "", "registry dep is a git dep")
      mf_check(
        @core.format_dep_inline(d) ==
        "{ git = \"file:///srv/mylib.git\", tag = \"v2\", subdir = \"pkg\", version = \"2.0.0\", registry = \"file:///srv/idx.git\" }",
        "inline form: " + @core.format_dep_inline(d),
      )
    }
    Err(e) => abort("parse_registry_entry failed: " + e)
  }
  mf_check(@core.registry_index_path("mylib") == "index/mylib.toml", "index path")
  let bad : Array[String] = [
    "version = \"1\"\n", "git = \"u\"\ntag = \"a\"\nrev = \"b\"\n", "name = \"other\"\ngit = \"u\"\n",
    "git u\n",
  ]
  let mut i = 0
  while i < bad.length() {
    match @core.parse_registry_entry("mylib", bad[i]) {
      Ok(_) => abort("bad registry entry accepted: " + bad[i])
      Err(e) => mf_check(mf_has(e, "index/mylib.toml"), "error names the entry: " + e)
    }
    i = i + 1
  }
  mf_check(@core.manifest_valid_dep_name("my_lib-2"), "valid name")
  mf_check(!@core.manifest_valid_dep_name("2lib"), "leading digit")
  mf_check(!@core.manifest_valid_dep_name("a b"), "space")
  mf_check(!@core.manifest_valid_dep_name(""), "empty")
}

///|
test "p20b: manifest_set_dependency appends, replaces in place and is idempotent" {
  let init = @core.init_pion_toml("app")
  let d1 = @core.manifest_dep_new("util", "../util", "", "", "", "", "")
  let t1 = @core.manifest_set_dependency(init, d1)
  mf_check(t1 == init + "util = { path = \"../util\" }\n", "append to empty table: " + t1)
  mf_check(@core.manifest_set_dependency(t1, d1) == t1, "idempotent")
  let d2 = @core.manifest_dep_new("net", "", "file:///r.git", "v1", "", "", "")
  let t2 = @core.manifest_set_dependency(t1, d2)
  mf_check(
    t2 == init + "util = { path = \"../util\" }\nnet = { git = \"file:///r.git\", tag = \"v1\" }\n",
    "second entry after the first: " + t2,
  )
  let d2b = @core.manifest_dep_new("net", "", "file:///r.git", "v2", "", "", "")
  let t3 = @core.manifest_set_dependency(t2, d2b)
  mf_check(
    t3 == init + "util = { path = \"../util\" }\nnet = { git = \"file:///r.git\", tag = \"v2\" }\n",
    "replace in place: " + t3,
  )
  match @core.parse_pion_toml(t3) {
    Ok(m) => mf_check(m.deps.length() == 2 && m.deps[1].tag == "v2", "rewritten toml parses")
    Err(e) => abort(e)
  }
  // Other sections and comments are kept; the entry goes into [dependencies], not after [link].
  let mixed = "[package]\nname = \"a\" # app\n\n[dependencies]\nold = { path = \"../old\" } # keep\n\n[link]\nlibs = [\"z\"]\n"
  let t4 = @core.manifest_set_dependency(mixed, d1)
  mf_check(
    t4 == "[package]\nname = \"a\" # app\n\n[dependencies]\nold = { path = \"../old\" } # keep\nutil = { path = \"../util\" }\n\n[link]\nlibs = [\"z\"]\n",
    "insert inside the table: " + t4,
  )
  // No [dependencies] table yet (and no trailing newline).
  let t5 = @core.manifest_set_dependency("[package]\nname = \"a\"", d1)
  mf_check(
    t5 == "[package]\nname = \"a\"\n\n[dependencies]\nutil = { path = \"../util\" }\n",
    "create the table: " + t5,
  )
  let entries = [@core.lock_entry_new("net", "file:///r.git", "tag:v2", "abc123", "")]
  mf_check(@core.lock_rev_of(entries, "net") == "abc123", "lock_rev_of")
  mf_check(@core.lock_rev_of(entries, "nope") == "", "lock_rev_of missing")
}
