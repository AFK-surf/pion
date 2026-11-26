// Differential oracle: MoonBit reference side (`moon run --target wasm-gc`).
//
// Run as `main -- <case>`. Every case prints
//   T <key>=<value>   trace lines (compared verbatim with the Pion side),
//   A <id>            one line per assertion that held (ids compared too).
// A failed assertion aborts, so the outcome class turns into a panic.
// The Pion side (`../pion_probe/src/main.pion`) mirrors every case.

///|
fn trace(key : String, value : String) -> Unit {
  println("T \{key}=\{value}")
}

///|
fn check(id : String, cond : Bool) -> Unit {
  if cond {
    println("A \{id}")
  } else {
    println("FAILED \{id}")
    abort("assertion failed: \{id}")
  }
}

///|
let lcg_state : Ref[UInt64] = { val: 0x2545F4914F6CDD1DUL, }

///|
fn lcg_next() -> UInt64 {
  lcg_state.val = lcg_state.val * 6364136223846793005UL + 1442695040888963407UL
  lcg_state.val
}

///|
fn utf8_width(c : Char) -> Int32 {
  let x = c.to_int()
  if x < 0x80 {
    1
  } else if x < 0x800 {
    2
  } else if x < 0x10000 {
    3
  } else {
    4
  }
}

///|
/// Byte offset (UTF-8) of UTF-16 offset `u`, flooring inside a pair.
fn utf8_off_of(s : String, u : Int32) -> Int32 {
  let mut units = 0
  let mut bytes = 0
  for c in s {
    let w = if c.to_int() >= 0x10000 { 2 } else { 1 }
    if units + w > u {
      break
    }
    units += w
    bytes += utf8_width(c)
  }
  bytes
}

///|
/// Scalar index of UTF-16 offset `u`, flooring inside a pair.
fn scalar_off_of(s : String, u : Int32) -> Int32 {
  let mut units = 0
  let mut k = 0
  for c in s {
    let w = if c.to_int() >= 0x10000 { 2 } else { 1 }
    if units + w > u {
      break
    }
    units += w
    k += 1
  }
  k
}

///|
fn case_utf16_basic() -> Unit {
  let s = "A中😀B"
  trace("len", s.length().to_string())
  check("utf16.len", s.length() == 5)
  for i = 0; i < 5; i = i + 1 {
    trace("cu\{i}", s.code_unit_at(i).to_string())
  }
  check("utf16.cu1", s.code_unit_at(1) == 20013)
  check("utf16.cu2", s.code_unit_at(2) == 55357)
  check("utf16.cu3", s.code_unit_at(3) == 56832)
  let idx = []
  for i, ch in s {
    trace("scalar\{i}", ch.to_int().to_string())
    idx.push(i)
  }
  check("utf16.scalar_idx", idx == [0, 1, 2, 3])
  let comb = "e\u{301}x"
  trace("comb.len", comb.length().to_string())
  check("utf16.comb_len", comb.length() == 3)
  let emo = "👍🏽!"
  trace("emo.len", emo.length().to_string())
  trace("emo.cu1", emo.code_unit_at(1).to_string())
  trace("prefix", s.has_prefix("A中").to_string())
  trace("prefix2", s.has_prefix("中").to_string())
  trace("suffix", s.has_suffix("😀B").to_string())
  check("utf16.prefix", s.has_prefix("A中") && !s.has_prefix("中"))
  check("utf16.suffix", s.has_suffix("😀B"))
  let cs = [
    "😀", "\u{FF01}\u{FF01}", "中", "k9", "alpha", "beta", "zeta", "", "a😀",
  ]
  for x in cs {
    for y in cs {
      trace("cmp<\{x}><\{y}>", x.compare(y).to_string())
    }
  }
  trace("lower", "Hello WORLD Ä 😀X".to_lower())
  check("utf16.lower", "Hello WORLD Ä".to_lower() == "hello world Ä")
}

///|
fn case_utf16_long() -> Unit {
  let pieces = ["abcdefgh", "abc中文😀de", "😀", "x😀", "é"]
  for pi, piece in pieces {
    let s = piece.repeat(500)
    let mut h = 0
    for i = 0; i < s.length(); i = i + 1 {
      h = h * 31 + s.code_unit_at(i).to_int()
    }
    trace("long\{pi}.len", s.length().to_string())
    trace("long\{pi}.hash", h.to_string())
    trace("long\{pi}.last", s.code_unit_at(s.length() - 1).to_string())
  }
  check("utf16.long_len", "abc中文😀de".repeat(500).length() == 4500)
}

///|
fn case_utf16_slices() -> Unit {
  let samples = ["A中😀B", "😀😀", "e\u{301}x", "", "ab👍🏽cd"]
  for si, s in samples {
    let n = s.length()
    for a = -1; a <= n + 1; a = a + 1 {
      for b = -1; b <= n + 1; b = b + 1 {
        let v = s[a:b].to_owned()
        trace("s\{si}[\{a}:\{b}]", "<\{v}>")
        let g = match s.get_view(start=a, end=b) {
          Some(x) => "<\{x.to_owned()}>"
          None => "None"
        }
        trace("g\{si}[\{a}:\{b}]", g)
      }
    }
  }
  check("slice.pair", "A中😀B"[2:4].to_owned() == "😀")
  check("slice.mid_start", "A中😀B"[3:4].to_owned() == "")
  check("slice.mid_end", "A中😀B"[2:3].to_owned() == "")
  check("slice.clamp", "A中😀B"[-3:99].to_owned() == "A中😀B")
  check(
    "slice.exact",
    "A中😀B".exact_view(start=2, end=4).to_owned() == "😀",
  )
}

///|
fn case_utf16_boundary() -> Unit {
  let s = "aé中😀z"
  for u = 0; u <= s.length(); u = u + 1 {
    trace("u2b\{u}", utf8_off_of(s, u).to_string())
  }
  for u = 0; u <= s.length(); u = u + 1 {
    trace("u2s\{u}", scalar_off_of(s, u).to_string())
  }
  let mut acc = 0
  for k, c in s {
    trace("s2u\{k}", acc.to_string())
    acc += if c.to_int() >= 0x10000 { 2 } else { 1 }
  }
  trace("s2u_end", acc.to_string())
  check("boundary.scalar_pair_floor", scalar_off_of(s, 4) == 3)
  check("boundary.end", utf8_off_of(s, s.length()) == 11)
  check("boundary.pair_floor", utf8_off_of(s, 4) == 6)
}

///|
fn case_utf16_exact_mid_pair() -> Unit {
  trace("before", "ok")
  let v = "A中😀B".exact_view(start=3, end=4)
  trace("after", v.to_owned())
}

///|
fn case_utf16_exact_oob() -> Unit {
  trace("before", "ok")
  let v = "A中😀B".exact_view(start=0, end=6)
  trace("after", v.to_owned())
}

///|
fn case_utf16_code_unit_oob() -> Unit {
  trace("before", "ok")
  trace("after", "A中😀B".code_unit_at(5).to_string())
}

///|
fn case_arrayview_grow() -> Unit {
  let a = [1, 2, 3]
  trace("cap0", a.capacity().to_string())
  let v = a[0:2]
  a[0] = 2
  trace("v0.pre", v[0].to_string())
  check("av.pre_grow_visible", v[0] == 2)
  for i = 0; i < 256; i = i + 1 {
    a.push(i)
  }
  a[0] = 3
  trace("v0.post", v[0].to_string())
  trace("a0.post", a[0].to_string())
  trace("cap1", a.capacity().to_string())
  check("av.post_grow_isolated", v[0] == 2 && a[0] == 3)
  let e : Array[Int32] = []
  e.push(1)
  trace("cap.empty_push", e.capacity().to_string())
  let c : Array[Int32] = Array(capacity=2)
  c.push(1)
  let cv = c[0:1]
  c.push(2)
  c[0] = 5
  trace("reserved.shared", cv[0].to_string())
  c.push(3)
  c[0] = 6
  trace("reserved.grown", cv[0].to_string())
  trace("reserved.cap", c.capacity().to_string())
  c.insert(0, 0)
  let d = [7, 8]
  d.append(c[:])
  trace("append.cap", d.capacity().to_string())
  trace("append", d.map(x => x.to_string()).join(","))
  check("av.append_len", d.length() == 6)
}

///|
fn case_arrayview_ops() -> Unit {
  let a = [10, 11, 12, 13, 14, 15]
  let v = a[1:5]
  let w = v[1:3]
  trace("w", w.to_owned().map(x => x.to_string()).join(","))
  let mv = a.mut_view(start=1, end=5)
  mv[1] = 99
  trace("a2", a[2].to_string())
  trace("v1", v[1].to_string())
  trace("w0", w[0].to_string())
  check("av.nested_shared", w[0] == 99)
  let e = v.exact_view(start=2, end=4)
  trace("e", e.to_owned().map(x => x.to_string()).join(","))
  let b = [1, 2, 3, 4, 5]
  for p in [(3, 10), (-2, 2), (4, 1), (0, 5), (5, 5), (2, 2)] {
    trace(
      "clamp[\{p.0}:\{p.1}]",
      b[p.0:p.1].to_owned().map(x => x.to_string()).join(","),
    )
  }
  let bv = b[1:4]
  trace("sub[1:10]", bv[1:10].to_owned().map(x => x.to_string()).join(","))
  trace("sub[3:1]", bv[3:1].length().to_string())
  for p in [(3, 10), (-2, 2), (4, 1), (0, 5), (5, 5), (2, 2), (1, 3)] {
    trace(
      "slice_copy[\{p.0}:\{p.1}]",
      b[p.0:p.1].to_owned().map(x => x.to_string()).join(","),
    )
  }
  check("av.slice_copy", b[1:3].to_owned() == [2, 3])
  check("av.clamp_end", b[3:10].length() == 2)
  let o = b[0:3].to_owned()
  b[1] = 20
  trace("owned", o.map(x => x.to_string()).join(","))
  check("av.to_owned_independent", o[1] == 2)
}

///|
fn case_arrayview_exact_oob() -> Unit {
  let a = [1, 2, 3]
  trace("before", "ok")
  let v = a.exact_view(start=1, end=4)
  trace("after", v.length().to_string())
}

///|
fn case_arrayview_get_oob() -> Unit {
  let a = [1, 2, 3]
  let v = a[0:2]
  trace("before", "ok")
  trace("after", v[2].to_string())
}

///|
fn case_map_order() -> Unit {
  let m : Map[String, Int32] = Map([])
  m["zeta"] = 1
  m["alpha"] = 2
  m["mid"] = 3
  m["beta"] = 4
  m["k9"] = 5
  let ks = m.keys().collect().join(" ")
  trace("keys", ks)
  check("map.insertion_order", ks == "zeta alpha mid beta k9")
  m.remove("alpha")
  m["alpha"] = 6
  m["zeta"] = 7
  let parts = []
  m.each((k, v) => parts.push("\{k}=\{v}"))
  trace("each", parts.join(" "))
  check(
    "map.reinsert_moves_last",
    parts.join(" ") == "zeta=7 mid=3 beta=4 k9=5 alpha=6",
  )
  let pi = []
  m.eachi((i, k, v) => pi.push("\{i}:\{k}:\{v}"))
  trace("eachi", pi.join(","))
  trace("size", m.length().to_string())
  trace("get.mid", m.get("mid").unwrap_or(-1).to_string())
  trace("contains.nope", m.contains("nope").to_string())
  // Random set/remove workload over 64 keys.
  let r : Map[Int32, Int32] = Map([])
  for i = 0; i < 3000; i = i + 1 {
    let x = (lcg_next() >> 33).to_int()
    let k = x % 64
    if x % 3 == 0 {
      r.remove(k)
    } else {
      r[k] = i
    }
  }
  trace("rand.keys", r.keys().collect().map(x => x.to_string()).join(","))
  trace("rand.values", r.values().collect().map(x => x.to_string()).join(","))
  trace("rand.size", r.length().to_string())
  let lit = { "b": 1, "a": 2, "b": 3 }
  let lp = []
  lit.each((k, v) => lp.push("\{k}=\{v}"))
  trace("literal_dup", lp.join(" "))
  let entries = m.to_array().map(p => "\{p.0}=\{p.1}")
  entries.sort()
  trace("boundary.sorted", entries.join(","))
  check("map.boundary_size", entries.length() == 5)
  m.clear()
  trace("cleared", m.is_empty().to_string())
}

///|
#derive(Eq, Hash)
enum Shape {
  Circle(Int32)
  Label(String)
}

///|
fn case_map_enum_keys() -> Unit {
  let m : Map[Shape, String] = Map([])
  m[Label("b")] = "lb"
  m[Circle(3)] = "c3"
  m[Label("a")] = "la"
  m[Circle(3)] = "c3'"
  trace("values", m.values().collect().join(","))
  trace("size", m.length().to_string())
  check("map.enum_overwrite", m.get(Circle(3)) == Some("c3'"))
  let t : Map[(Int32, String), Int32] = Map([])
  t[(1, "x")] = 10
  t[(1, "y")] = 11
  t[(1, "x")] = 12
  t.remove((1, "y"))
  t[(1, "y")] = 13
  let tp = []
  t.each((k, v) => tp.push("\{k.0}/\{k.1}=\{v}"))
  trace("tuple", tp.join(" "))
  check("map.tuple_keys", t.length() == 2)
}

///|
fn case_double_golden() -> Unit {
  let ds = [
    1.5e-7,
    -0.0,
    0.0,
    0.0 / 0.0,
    1.0 / 0.0,
    -1.0 / 0.0,
    1.0e20,
    1.0e21,
    1.0e-7,
    1.0e-6,
    123.456,
    0.1 + 0.2,
    5.0e-324,
    1.7976931348623157e308,
    100.0,
    1.0,
    -2.5,
    123456789012345680000.0,
    1.0e100,
    2.0e-7,
    9007199254740993.0,
    2.2250738585072014e-308,
    -1.25e-10,
    0.5,
    1.0 / 3.0,
    6.02214076e23,
    4.35,
    1.0e15 + 0.3,
    999999999999999999999.0,
    0.000001234,
    1.0e-300,
    4.9406564584124654e-324,
  ]
  for i, d in ds {
    trace("d\{i}", d.to_string())
  }
  check("double.1_5e_7", 1.5e-7.to_string() == "1.5e-7")
  check("double.neg_zero", (-0.0).to_string() == "0")
  check("double.nan", (0.0 / 0.0).to_string() == "NaN")
  check("double.1e20", 1.0e20.to_string() == "100000000000000000000")
}

///|
fn case_double_random() -> Unit {
  let mut h = 0
  for i = 0; i < 3000; i = i + 1 {
    let d = lcg_next().reinterpret_as_double()
    let s = d.to_string()
    trace("r\{i}", s)
    h = h * 31 + s.length()
  }
  let p10 = [
    1.0, 10.0, 100.0, 1000.0, 10000.0, 100000.0, 1000000.0, 10000000.0, 100000000.0,
  ]
  for i = 0; i < 3000; i = i + 1 {
    let x = (lcg_next() >> 33).to_int()
    let n = x % 2000001 - 1000000
    let d = n.to_double() / p10[i % 9]
    trace("q\{i}", d.to_string())
  }
  check("double.random_done", h != 0)
}

///|
fn case_div_nonzero() -> Unit {
  let xs = [7, -7, 2147483647, -2147483648, 0, 1, -1, 2, -2, 3]
  for a in xs {
    for b in xs {
      if b != 0 && !(a == -2147483648 && b == -1) {
        trace("i32 \{a}/\{b}", (a / b).to_string())
      }
      if b != 0 {
        trace("i32 \{a}%\{b}", (a % b).to_string())
      }
    }
  }
  let ls = [
    7L, -7L, 9223372036854775807L, -9223372036854775808L, 0L, 1L, -1L, 3L,
  ]
  for a in ls {
    for b in ls {
      if b != 0L && !(a == -9223372036854775808L && b == -1L) {
        trace("i64 \{a}/\{b}", (a / b).to_string())
      }
      if b != 0L {
        trace("i64 \{a}%\{b}", (a % b).to_string())
      }
    }
  }
  let us : Array[UInt32] = [0U, 1U, 7U, 4294967295U, 2147483648U]
  for a in us {
    for b in us {
      if b != 0U {
        trace("u32 \{a}/\{b}", (a / b).to_string())
        trace("u32 \{a}%\{b}", (a % b).to_string())
      }
    }
  }
  let uls : Array[UInt64] = [0UL, 1UL, 7UL, 18446744073709551615UL]
  for a in uls {
    for b in uls {
      if b != 0UL {
        trace("u64 \{a}/\{b}", (a / b).to_string())
        trace("u64 \{a}%\{b}", (a % b).to_string())
      }
    }
  }
  let bs : Array[Byte] = [b'\x00', b'\x01', b'\x07', b'\xff']
  for a in bs {
    for b in bs {
      if b != b'\x00' {
        trace("byte \{a.to_int()}/\{b.to_int()}", (a / b).to_int().to_string())
        trace("byte \{a.to_int()}%\{b.to_int()}", (a % b).to_int().to_string())
      }
    }
  }
  check("div.min_mod_neg1", xs[3] % xs[6] == 0)
  check("div.trunc", -7 / 2 == -3 && -7 % 2 == -1)
}

///|
/// Runtime operands that the compiler cannot fold.
let zero_i32 : Array[Int32] = [0, -1, -2147483648, 7]

///|
let zero_i64 : Array[Int64] = [0L, -1L, -9223372036854775808L, 7L]

///|
let zero_u32 : Array[UInt32] = [0U, 7U]

///|
let zero_u64 : Array[UInt64] = [0UL, 7UL]

///|
let zero_byte : Array[Byte] = [b'\x00', b'\x07']

///|
fn case_div_trap(name : String) -> Unit {
  trace("before", name)
  let r = match name {
    "div.i32.div.rt" => (zero_i32[3] / zero_i32[0]).to_string()
    "div.i32.div.const" => (7 / 0).to_string()
    "div.i32.mod.rt" => (zero_i32[3] % zero_i32[0]).to_string()
    "div.i32.mod.const" => (7 % 0).to_string()
    "div.i32.ovf.rt" => (zero_i32[2] / zero_i32[1]).to_string()
    "div.i32.ovf.const" => (-2147483648 / -1).to_string()
    "div.i64.div.rt" => (zero_i64[3] / zero_i64[0]).to_string()
    "div.i64.div.const" => (7L / 0L).to_string()
    "div.i64.mod.rt" => (zero_i64[3] % zero_i64[0]).to_string()
    "div.i64.mod.const" => (7L % 0L).to_string()
    "div.i64.ovf.rt" => (zero_i64[2] / zero_i64[1]).to_string()
    "div.i64.ovf.const" => (-9223372036854775808L / -1L).to_string()
    "div.u32.div.rt" => (zero_u32[1] / zero_u32[0]).to_string()
    "div.u32.div.const" => (7U / 0U).to_string()
    "div.u32.mod.rt" => (zero_u32[1] % zero_u32[0]).to_string()
    "div.u32.mod.const" => (7U % 0U).to_string()
    "div.u64.div.rt" => (zero_u64[1] / zero_u64[0]).to_string()
    "div.u64.div.const" => (7UL / 0UL).to_string()
    "div.u64.mod.rt" => (zero_u64[1] % zero_u64[0]).to_string()
    "div.u64.mod.const" => (7UL % 0UL).to_string()
    "div.byte.div.rt" => (zero_byte[1] / zero_byte[0]).to_string()
    "div.byte.div.const" => (b'\x07' / b'\x00').to_string()
    "div.byte.mod.rt" => (zero_byte[1] % zero_byte[0]).to_string()
    "div.byte.mod.const" => (b'\x07' % b'\x00').to_string()
    _ => abort("unknown division case \{name}")
  }
  trace("after", r)
}

///|
fn case_collections() -> Unit {
  let xs = [3, 1, 2]
  trace("map", xs.map(x => "<\{x}>").join(""))
  trace("mapi", xs.mapi((i, x) => i * 10 + x).map(x => x.to_string()).join(","))
  trace("filter", xs.filter(x => x != 1).map(x => x.to_string()).join(","))
  trace("fold", xs.fold(init=100, (a, x) => a - x).to_string())
  trace("last", xs.last().unwrap_or(0).to_string())
  let ys = [1, 2, 3]
  ys.insert(0, 0)
  ys.insert(4, 4)
  ys.insert(2, 9)
  trace("insert", ys.map(x => x.to_string()).join(","))
  trace("remove", ys.remove(2).to_string())
  ys.append([7, 8])
  trace("append", ys.map(x => x.to_string()).join(","))
  check("coll.insert_remove", ys.length() == 7)
  // Sort with many ties: final tie order must match MoonBit exactly.
  for n in [10, 17, 60, 200, 1000] {
    let ps : Array[(Int32, Int32)] = []
    for i = 0; i < n; i = i + 1 {
      ps.push(((lcg_next() >> 33).to_int() % 7, i))
    }
    ps.sort_by((a, b) => a.0 - b.0)
    trace("sort\{n}", ps.map(p => p.1.to_string()).join(","))
  }
  let sorted = [5, 3, 9, 1, 7, 2, 8, 6, 4, 0]
  sorted.sort_by((a, b) => a - b)
  check("coll.sorted", sorted == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
  let hs = Array::makei(100, i => if i % 2 == 0 { 1 } else { 0 })
  hs.sort_by((a, b) => if a < b { -1 } else { 1 })
  trace("heap", hs.map(x => x.to_string()).join(""))
  let s : Int32? = Some(2)
  let n : Int32? = None
  trace("opt.map", s.map(x => x * 3).unwrap_or(0).to_string())
  trace("opt.map_none", (n.map(x => x * 3) is None).to_string())
  trace("opt.unwrap", s.unwrap().to_string())
  trace("opt.or", n.unwrap_or(7).to_string())
  check("coll.opt", s.unwrap() == 2 && n is None)
}

///|
fn case_opt_unwrap_none() -> Unit {
  let n : Int32? = None
  trace("before", "ok")
  trace("after", n.unwrap().to_string())
}

///|
fn case_arr_remove_oob() -> Unit {
  let xs = [1, 2, 3]
  trace("before", "ok")
  trace("after", xs.remove(3).to_string())
}

///|
fn case_double_compare_nan() -> Unit {
  let nan = 0.0 / 0.0
  let ninf = -1.0 / 0.0
  let c1 = nan.compare(1.0)
  let c2 = (1.0).compare(nan)
  let c3 = nan.compare(ninf)
  let c4 = nan.compare(nan)
  let c5 = (-0.0).compare(0.0)
  let xs : Array[Double] = [3.0, nan, 1.0, -0.0, 2.0, ninf]
  xs.sort_by((a, b) => a.compare(b))
  let sb = StringBuilder::new()
  for i = 0; i < xs.length(); i = i + 1 {
    if i > 0 { sb.write_string(",") }
    sb.write_string(xs[i].to_string())
  }
  let sorted_s = sb.to_string()
  trace("cmp", "\{c1},\{c2},\{c3},\{c4},\{c5}")
  trace("sort", sorted_s)
  check("double.cmp_nan_1", c1 == 0)
  check("double.cmp_1_nan", c2 == 0)
  check("double.cmp_nan_ninf", c3 == 0)
  check("double.cmp_nan_nan", c4 == 0)
  check("double.cmp_neg0_0", c5 == 0)
  check("double.sort_nan", sorted_s.length() > 0)
}

///|
fn case_compat_basics() -> Unit {
  let inf = 1.0 / 0.0
  let ninf = -1.0 / 0.0
  let nan = 0.0 / 0.0
  check("m2.is_inf_pos", inf.is_inf())
  check("m2.is_inf_neg", ninf.is_inf())
  check("m2.is_inf_nan", !nan.is_inf())
  check("m2.is_inf_fin", !(42.5).is_inf())
  let h1 : Double = 0x1.0p1023
  let h2 : Double = 0x1.fp-1022
  let h3 : Double = 0x1.0p-54
  let h4 : Double = 0x1.0p-1074
  trace("hex_bits", "\{h1.reinterpret_as_int64()},\{h2.reinterpret_as_int64()},\{h3.reinterpret_as_int64()},\{h4.reinterpret_as_int64()}")
  let r1 : Ref[Int] = { val: 10 }
  let r2 : Ref[Int] = { val: 10 }
  r1.val = r1.val + 5
  check("m2.ref_mut", r1.val == 15 && r2.val == 10)
  check("m2.ref_phys", physical_equal(r1, r1) && !physical_equal(r1, r2))
  let bs = Bytes::makei(4, fn(i) { (65 + i).to_byte() })
  let sub = bs[1:3]
  trace("bytes", "\{bs.length()},\{sub.length()},\{sub[0].to_int()},\{sub[1].to_int()}")
  check("m2.bytes_makei", bs.length() == 4 && sub.length() == 2 && sub[0] == b'B' && sub[1] == b'C')
  let fa = FixedArray::makei(3, fn(i) { i * 10 })
  check("m2.fa_makei", fa.length() == 3 && fa[0] == 0 && fa[1] == 10 && fa[2] == 20)
}

///|
fn case_compat_round2() -> Unit {
  // P1-6: UTF-8 lossy maximal subpart (Unicode Table 3-7 / WHATWG)
  let samples : Array[(String, Array[Byte])] = [
    ("e0a0", [b'\xE0', b'\xA0']),
    ("e282", [b'\xE2', b'\x82']),
    ("e28241", [b'\xE2', b'\x82', b'\x41']),
    ("f09f92", [b'\xF0', b'\x9F', b'\x92']),
    ("f0908041", [b'\xF0', b'\x90', b'\x80', b'\x41']),
    ("mixed", [b'\xC0', b'\x80', b'\xED', b'\xA0', b'\x80', b'\xF4', b'\x90', b'\x80', b'\x80', b'\xFF', b'\x7A']),
  ]
  for pair in samples {
    let dec = @utf8.decode_lossy(Bytes::from_array(pair.1))
    let sb = StringBuilder::new()
    for i = 0; i < dec.length(); i = i + 1 {
      if i > 0 { sb.write_string(",") }
      sb.write_string(dec[i].to_int().to_string())
    }
    trace("utf8." + pair.0, sb.to_string())
  }
  check("r2.utf8_subpart", @utf8.decode_lossy(Bytes::from_array([b'\xE0', b'\xA0'])).length() == 1)

  // P1-7: math.maximum / math.minimum on NaN and ±0.0
  let nan = 0.0 / 0.0
  let p0 = 0.0
  let n0 = -0.0
  let pairs : Array[(String, Double, Double)] = [
    ("nan_1", nan, 1.0),
    ("1_nan", 1.0, nan),
    ("p0_n0", p0, n0),
    ("n0_p0", n0, p0),
    ("nan_nan", nan, nan),
    ("2_5", 2.0, 5.0),
  ]
  for item in pairs {
    let mx = @math.maximum(item.1, item.2)
    let mn = @math.minimum(item.1, item.2)
    let mx_s = if mx.is_nan() { "NaN" } else { mx.reinterpret_as_int64().to_string() }
    let mn_s = if mn.is_nan() { "NaN" } else { mn.reinterpret_as_int64().to_string() }
    trace("mm." + item.0, "\{mx_s},\{mn_s}")
  }
  check("r2.math_max_nan", @math.maximum(nan, 1.0) == 1.0 && @math.maximum(1.0, nan).is_nan())
  check("r2.math_min_nan", @math.minimum(nan, 1.0).is_nan() && @math.minimum(1.0, nan) == 1.0)

  // P1-8: Lazy iter short-circuiting (including lazy zip!)
  let mut c1 = 0
  let a1 = [1, 2, 3, 4, 5, 6].iter().map(fn(x) { c1 = c1 + 1; x * 2 }).any(fn(x) { x == 4 })
  let mut c2 = 0
  let a2 = [1, 2, 3, 4, 5, 6].iter().map(fn(x) { c2 = c2 + 1; x * 2 }).all(fn(x) { x < 6 })
  let mut zf = 0
  let mut zg = 0
  let _unused_zip = [1, 2, 3].iter().map(fn(x) { zf = zf + 1; x }).zip([10, 20, 30].iter().map(fn(y) { zg = zg + 1; y }))
  let z_unused_cnt = "\{zf}:\{zg}"
  let za = [1, 2, 3, 4, 5, 6]
    .iter()
    .map(fn(x) { zf = zf + 1; x })
    .zip([10, 20, 30, 40, 50, 60].iter().map(fn(y) { zg = zg + 1; y }))
    .any(fn(p) { p.0 + p.1 == 22 })
  trace("iter", "\{a1}:\{c1},\{a2}:\{c2},zip_unused=\{z_unused_cnt},zip_any=\{za}:\{zf}:\{zg}")
  check("r2.iter_lazy", a1 && c1 == 2 && !a2 && c2 == 3 && z_unused_cnt == "0:0" && za && zf == 2 && zg == 2)

  // P0-1 + P2: Debug formatting for String & Char + arr_iter length snapshot
  let ds0 = "\u{00}\u{01}\u{1f}\u{7f}\b\n\t\\\"".escape()
  let dc0 = '\u{00}'.escape()
  let dc7f = '\u{7f}'.escape()
  let dc200b = '\u{200b}'.escape()
  let dc_a = 'A'.escape()
  trace("dbg_str", ds0)
  trace("dbg_chr", "\{dc0}|\{dc7f}|\{dc200b}|\{dc_a}")
  let snap_xs = [1, 2]
  let snap_it = snap_xs.iter()
  snap_xs.push(3)
  let snap_cnt = snap_it.count()
  let fold_v = [1, 2].iter().fold(init=0, fn(x, y) { x * 10 + y })
  trace("iter_snap_fold", "\{snap_cnt},\{fold_v}")
  check("r2.dbg_str", ds0.contains("\\u{00}\\u{01}\\u{1f}") && dc0 == "'\\u{00}'" && dc7f == "'\\u{7f}'" && dc200b == "'\\u{200b}'" && snap_cnt == 2 && fold_v == 12)
}

///|
fn case_compat_parse_numbers() -> Unit {
  let i_ws = try { Some(@string.parse_int(" 42 ")) } catch { _ => None }
  let i_hex0 = try { Some(@string.parse_int("0xff")) } catch { _ => None }
  let i_hex16 = try { Some(@string.parse_int("0xFF", base=16)) } catch { _ => None }
  let d_ws = try { Some(@string.parse_double(" 1.5 ")) } catch { _ => None }
  let d_ovf = try { Some(@string.parse_double("1e309")) } catch { _ => None }
  let d_und = try { Some(@string.parse_double("1e-400")) } catch { _ => None }
  trace("parse", "\{i_ws is None},\{i_hex0.unwrap_or(-1)},\{i_hex16.unwrap_or(-1)},\{d_ws is None},\{d_ovf is None},\{d_und.unwrap_or(-1.0)}")
  check("m2b.int_ws_err", i_ws is None)
  check("m2b.int_hex0", i_hex0 == Some(255))
  check("m2b.int_hex16", i_hex16 == Some(255))
  check("m2b.dbl_ws_err", d_ws is None)
  check("m2b.dbl_ovf_err", d_ovf is None)
  check("m2b.dbl_und_zero", d_und == Some(0.0))

  // P1-1: 0-ULP exact parse_double bit-level comparison across all 3 engines
  let big_cancel = "1" + String::make(800, '0') + "e-800"
  let dbl_inputs = [
    "1.7976931348623157e308",
    "1.7976931348623159e308",
    "2.2250738585072014e-308",
    "123456789012345678901234567890",
    "2.4703282292062328e-324",
    "2.4703282292062327e-324",
    "1_000.5",
    "1_234.5_6e1_2",
    "1e309",
    "1e-400",
    "-1e-400",
    "-0.0",
    " 1.5 ",
    "_1.0",
    "1_.0",
    "1._0",
    "1.0_",
    "1__0.0",
    "1e_2",
    "1e+_2",
    "1e2_",
    big_cancel,
  ]
  for i = 0; i < dbl_inputs.length(); i = i + 1 {
    let s = dbl_inputs[i]
    let res = try {
      let v = @string.parse_double(s)
      "ok:" + v.reinterpret_as_int64().to_string()
    } catch {
      _ => "err"
    }
    trace("dbl_bits_\{i}", res)
  }
  check("m2b.dbl_exact_bits", true)

  // P1-2: MbtJson lossless repr + non-finite stringify
  let j1 = (@json.parse("9007199254740993") catch { _ => Json::null() }).stringify()
  let j2 = (@json.parse("-9007199254740993") catch { _ => Json::null() }).stringify()
  let j3 = (@json.parse("1e500") catch { _ => Json::null() }).stringify()
  let j4 = (@json.parse("-1e500") catch { _ => Json::null() }).stringify()
  let j5 = (@json.parse("1.7976931348623157e308") catch { _ => Json::null() }).stringify()
  let j6 = Json::number(0.0 / 0.0).stringify()
  let j7 = Json::number(1.0 / 0.0).stringify()
  let j8 = Json::number(-1.0 / 0.0).stringify()
  let j9 = Json::number(-0.0).stringify()
  trace("json_repr", "\{j1}|\{j2}|\{j3}|\{j4}|\{j5}|\{j6}|\{j7}|\{j8}|\{j9}")
  check("m2b.json_repr_and_nonfinite", j1 == "9007199254740993" && j2 == "-9007199254740993" && j3 == "1e500" && j4 == "-1e500" && j6 == "\"NaN\"" && j7 == "\"Infinity\"" && j8 == "\"-Infinity\"")

  // P1-1: parse_int underscore rules across radixes
  let iu1 = try { Some(@string.parse_int("0x_FF")) } catch { _ => None }
  let iu2 = try { Some(@string.parse_int("1_0", base=10)) } catch { _ => None }
  let iu3 = try { Some(@string.parse_int("0xF_F", base=16)) } catch { _ => None }
  let iub1 = try { Some(@string.parse_int("_10")) } catch { _ => None }
  let iub2 = try { Some(@string.parse_int("10_")) } catch { _ => None }
  let iub3 = try { Some(@string.parse_int("1__0")) } catch { _ => None }
  let iub4 = try { Some(@string.parse_int("0x__FF")) } catch { _ => None }
  let iub5 = try { Some(@string.parse_int("0x_FF", base=10)) } catch { _ => None }
  trace("int_under", "\{iu1.unwrap_or(-1)},\{iu2.unwrap_or(-1)},\{iu3.unwrap_or(-1)},\{iub1 is None},\{iub2 is None},\{iub3 is None},\{iub4 is None},\{iub5 is None}")
  check("m2b.int_underscores", iu1 == Some(255) && iu2 == Some(10) && iu3 == Some(255) && iub1 is None && iub2 is None && iub3 is None && iub4 is None && iub5 is None)

  // P1-3: JSON nesting depth 513 (Ok), 1024 (Ok) — invariant across MoonBit 0.1.20261119 (1024 cap) & 0.1.20261126+ (heap stack)
  let mk_nest = fn(d : Int) -> String {
    let sb = StringBuilder::new()
    for _i = 0; _i < d; _i = _i + 1 { sb.write_char('[') }
    sb.write_char('0')
    for _i = 0; _i < d; _i = _i + 1 { sb.write_char(']') }
    sb.to_string()
  }
  let jd513 = try { let _ = @json.parse(mk_nest(513)); true } catch { _ => false }
  let jd1024 = try { let _ = @json.parse(mk_nest(1024)); true } catch { _ => false }
  trace("json_depth", "\{jd513},\{jd1024}")
  check("m2b.json_depth_1024", jd513 && jd1024)

  // P1-4: String::view vs String::clamped_view
  let sv1 = "abc".view(start_offset=1).to_string()
  let sv2 = "abc".view(start_offset=1, end_offset=2).to_string()
  let cv1 = "abc".clamped_view(start=1).to_string()
  let cv2 = "abc".clamped_view(start=-5, end=99).to_string()
  let cv3 = "abc".clamped_view(start=2, end=1).to_string()
  trace("str_views", "\{sv1}|\{sv2}|\{cv1}|\{cv2}|\{cv3}")
  check("m2b.str_views", sv1 == "bc" && sv2 == "b" && cv1 == "bc" && cv2 == "abc" && cv3 == "")

  // P1-6: xxHash32 Hasher exact bit-for-bit match
  let h7 = Hash::hash(7)
  let h42 = Hash::hash(42)
  let hstr = Hash::hash("hello")
  let hpi = Hash::hash(3.14)
  let hz_eq = Hash::hash(-0.0) == Hash::hash(0.0)
  trace("xxhash32", "\{h7},\{h42},\{hstr},\{hpi},\{hz_eq}")
  check("m2b.xxhash32", h7 == -427046664 && h42 == 1161967057 && hstr == -655549713 && hpi == -428265677 && hz_eq)
}

///|
fn case_set_retain_nan() -> Unit {
  let nan = 0.0 / 0.0
  let s1 : Set[Double] = Set::new()
  s1.add(nan)
  s1.add(1.0)
  s1.retain(fn(_) { false })
  trace("s1_len", s1.length().to_string())
  check("set.retain_nan_all_false", s1.length() == 0)

  let s2 : Set[Double] = Set::new()
  s2.add(nan)
  s2.add(1.0)
  s2.retain(fn(x) { x == x })
  let rem = s2.to_array()
  trace("s2_rem", "\{s2.length()}:\{rem[0]}")
  check("set.retain_nan_keep_finite", s2.length() == 1 && rem.length() == 1 && rem[0] == 1.0)

  // 100 elements (NaN + 0.0..98.0): triggers compaction threshold (>= 64)
  let s3 : Set[Double] = Set::new()
  s3.add(nan)
  for i = 0; i < 99; i = i + 1 {
    s3.add(i.to_double())
  }
  s3.retain(fn(_) { false })
  trace("s3_len", s3.length().to_string())
  check("set.retain_100_all_false", s3.length() == 0 && s3.to_array().length() == 0)

  let s4 : Set[Double] = Set::new()
  s4.add(nan)
  for i = 0; i < 99; i = i + 1 {
    s4.add(i.to_double())
  }
  s4.retain(fn(x) { x == x && x >= 90.0 })
  let rem4 = s4.to_array()
  let mut rem4_str = ""
  for j = 0; j < rem4.length(); j = j + 1 {
    if j > 0 {
      rem4_str = rem4_str + ","
    }
    rem4_str = rem4_str + rem4[j].to_string()
  }
  trace("s4_rem", "\{s4.length()}:\{rem4_str}")
  check("set.retain_100_ge90", s4.length() == 9 && rem4.length() == 9 && rem4[0] == 90.0 && rem4[8] == 98.0)
}

///|
fn main {
  let args = @env.args()
  let name = if args.length() > 1 { args[1] } else { "" }
  match name {
    "utf16.basic" => case_utf16_basic()
    "utf16.long" => case_utf16_long()
    "utf16.slices" => case_utf16_slices()
    "utf16.boundary" => case_utf16_boundary()
    "utf16.exact_mid_pair" => case_utf16_exact_mid_pair()
    "utf16.exact_oob" => case_utf16_exact_oob()
    "utf16.code_unit_oob" => case_utf16_code_unit_oob()
    "arrayview.grow" => case_arrayview_grow()
    "arrayview.ops" => case_arrayview_ops()
    "arrayview.exact_oob" => case_arrayview_exact_oob()
    "arrayview.get_oob" => case_arrayview_get_oob()
    "map.order" => case_map_order()
    "map.enum_keys" => case_map_enum_keys()
    "double.golden" => case_double_golden()
    "double.compare_nan" => case_double_compare_nan()
    "double.random" => case_double_random()
    "div.nonzero" => case_div_nonzero()
    "collections" => case_collections()
    "opt.unwrap_none" => case_opt_unwrap_none()
    "arr.remove_oob" => case_arr_remove_oob()
    "compat.basics" => case_compat_basics()
    "compat.round2" => case_compat_round2()
    "compat.parse_numbers" => case_compat_parse_numbers()
    "set.retain_nan" => case_set_retain_nan()
    _ =>
      if name.has_prefix("div.") {
        case_div_trap(name)
      } else {
        abort("unknown case \{name}")
      }
  }
}
