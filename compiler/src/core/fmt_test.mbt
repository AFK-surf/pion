///|
fn fmt_assert_eq(actual : String, expected : String, msg : String) -> Unit {
  if actual != expected {
    abort(
      "FMT ASSERTION FAILED (" +
      msg +
      "):\n--- expected ---\n" +
      expected +
      "--- actual ---\n" +
      actual +
      "--- end ---",
    )
  }
}

///|
test "fmt: basic 2-space indentation, blank lines, trailing whitespace, EOF newline" {
  let src =
    "\n\n  pub fn add(a : Int,   b : Int) -> Int {   \r\n" +
    "\t\tlet   sum = a + b   \r\n" +
    "\n\n\n" +
    "      if sum > 0 {\n" +
    "          return sum\n" +
    "      } else {\n" +
    "          return 0\n" +
    "      }\n" +
    "  }  \n\n\n"
  let expected =
    "pub fn add(a : Int, b : Int) -> Int {\n" +
    "  let sum = a + b\n" +
    "\n" +
    "  if sum > 0 {\n" +
    "    return sum\n" +
    "  } else {\n" +
    "    return 0\n" +
    "  }\n" +
    "}\n"
  let out1 = @core.format_source(src)
  fmt_assert_eq(out1, expected, "first pass")
  let out2 = @core.format_source(out1)
  fmt_assert_eq(out2, out1, "idempotent second pass")
}

///|
test "fmt: preserves comments, strings, char/byte literals with braces" {
  let src =
    "///| doc comment with   extra   spaces and {\n" +
    "pub fn demo() -> String {\n" +
    "    // inline comment with } and (\n" +
    "    let s = \"{   not   a   block   } // not a comment\"\n" +
    "    let c = '{'\n" +
    "    let b = b'}'\n" +
    "    let esc = \"quote \\\" { \\\" end\"\n" +
    "    s // trailing   comment   preserved\n" +
    "}\n"
  let expected =
    "///| doc comment with   extra   spaces and {\n" +
    "pub fn demo() -> String {\n" +
    "  // inline comment with } and (\n" +
    "  let s = \"{   not   a   block   } // not a comment\"\n" +
    "  let c = '{'\n" +
    "  let b = b'}'\n" +
    "  let esc = \"quote \\\" { \\\" end\"\n" +
    "  s // trailing   comment   preserved\n" +
    "}\n"
  let out1 = @core.format_source(src)
  fmt_assert_eq(out1, expected, "comment and literal preservation")
  fmt_assert_eq(@core.format_source(out1), out1, "idempotent")
}

///|
test "fmt: scope/spawn nested closure alignment and multiline calls" {
  let src =
    "pub fn main(world : World) -> Int {\n" +
    "scope(world, fn(s : Scope) -> Unit {\n" +
    "spawn(s, fn() -> Unit {\n" +
    "io_println(\n" +
    "world,\n" +
    "\"hi\",\n" +
    ")\n" +
    "})\n" +
    "})\n" +
    "0\n" +
    "}\n"
  let expected =
    "pub fn main(world : World) -> Int {\n" +
    "  scope(world, fn(s : Scope) -> Unit {\n" +
    "    spawn(s, fn() -> Unit {\n" +
    "      io_println(\n" +
    "        world,\n" +
    "        \"hi\",\n" +
    "      )\n" +
    "    })\n" +
    "  })\n" +
    "  0\n" +
    "}\n"
  let out1 = @core.format_source(src)
  fmt_assert_eq(out1, expected, "scope/spawn alignment")
  fmt_assert_eq(@core.format_source(out1), out1, "idempotent")
}

///|
test "fmt: empty and whitespace-only input" {
  fmt_assert_eq(@core.format_source(""), "", "empty string")
  fmt_assert_eq(@core.format_source("   \n\t\n  "), "", "whitespace only")
}

///|
test "fmt: check result JSON format" {
  fmt_assert_eq(
    @core.fmt_check_result_to_json([]),
    "{\"ok\":true,\"unformatted\":[]}",
    "empty unformatted list",
  )
  fmt_assert_eq(
    @core.fmt_check_result_to_json(["a.m2", "dir/b.mbt"]),
    "{\"ok\":false,\"unformatted\":[\"a.m2\",\"dir/b.mbt\"]}",
    "two unformatted files",
  )
}
