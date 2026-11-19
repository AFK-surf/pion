///|
#borrow(path)
extern "C" fn m2_host_file_exists(path : Bytes) -> Int = "m2_host_file_exists"

///|
#borrow(path)
extern "C" fn m2_host_is_dir(path : Bytes) -> Int = "m2_host_is_dir"

///|
#borrow(path)
extern "C" fn m2_host_read_file(path : Bytes) -> Bytes = "m2_host_read_file"

///|
#borrow(dir)
extern "C" fn m2_host_list_sources(dir : Bytes) -> Bytes = "m2_host_list_sources"

///|
#borrow(data)
extern "C" fn m2_host_write_stdout(data : Bytes) -> Unit = "m2_host_write_stdout"

///|
#borrow(data)
extern "C" fn m2_host_write_stderr(data : Bytes) -> Unit = "m2_host_write_stderr"

///|
extern "C" fn m2_host_exit(code : Int) -> Unit = "m2_host_exit"

///|
fn str_to_utf8(s : String) -> Bytes {
  let out : Array[Byte] = []
  let len = s.length()
  let mut i = 0
  while i < len {
    let cp = s[i].to_int()
    if cp < 0x80 {
      out.push(cp.to_byte())
    } else if cp < 0x800 {
      out.push((0xC0 | (cp >> 6)).to_byte())
      out.push((0x80 | (cp & 0x3F)).to_byte())
    } else {
      out.push((0xE0 | (cp >> 12)).to_byte())
      out.push((0x80 | ((cp >> 6) & 0x3F)).to_byte())
      out.push((0x80 | (cp & 0x3F)).to_byte())
    }
    i = i + 1
  }
  Bytes::from_array(out)
}

///|
fn utf8_to_str(b : Bytes) -> String {
  let sb = StringBuilder()
  let len = b.length()
  let mut i = 0
  while i < len {
    let b0 = b[i].to_int()
    if b0 < 0x80 {
      sb.write_char(b0.unsafe_to_char())
      i = i + 1
    } else if (b0 & 0xE0) == 0xC0 && i + 1 < len {
      let b1 = b[i + 1].to_int()
      let cp = ((b0 & 0x1F) << 6) | (b1 & 0x3F)
      sb.write_char(cp.unsafe_to_char())
      i = i + 2
    } else if (b0 & 0xF0) == 0xE0 && i + 2 < len {
      let b1 = b[i + 1].to_int()
      let b2 = b[i + 2].to_int()
      let cp = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F)
      sb.write_char(cp.unsafe_to_char())
      i = i + 3
    } else if (b0 & 0xF8) == 0xF0 && i + 3 < len {
      let b1 = b[i + 1].to_int()
      let b2 = b[i + 2].to_int()
      let b3 = b[i + 3].to_int()
      let cp = ((b0 & 0x07) << 18) |
        ((b1 & 0x3F) << 12) |
        ((b2 & 0x3F) << 6) |
        (b3 & 0x3F)
      sb.write_char(cp.unsafe_to_char())
      i = i + 4
    } else {
      sb.write_char(b0.unsafe_to_char())
      i = i + 1
    }
  }
  sb.to_string()
}

///|
fn write_out(s : String) -> Unit {
  m2_host_write_stdout(str_to_utf8(s))
}

///|
fn write_err(s : String) -> Unit {
  m2_host_write_stderr(str_to_utf8(s))
}

///|
fn split_nonempty_lines(s : String) -> Array[String] {
  let out : Array[String] = []
  let sb = StringBuilder()
  let mut i = 0
  while i < s.length() {
    let ch = s[i].to_int()
    if ch == 10 {
      let line = sb.to_string()
      if line.length() > 0 {
        out.push(line)
      }
      sb.reset()
    } else if ch != 13 {
      sb.write_char(ch.unsafe_to_char())
    }
    i = i + 1
  }
  let tail = sb.to_string()
  if tail.length() > 0 {
    out.push(tail)
  }
  out
}

///|
fn basename_pkg(path : String) -> String {
  let mut end = path.length()
  while end > 1 && path[end - 1].to_int() == 47 {
    end = end - 1
  }
  let mut start = end - 1
  while start >= 0 && path[start].to_int() != 47 {
    start = start - 1
  }
  let sb = StringBuilder()
  let mut i = start + 1
  while i < end {
    let ch = path[i].to_int()
    if ch == 46 {
      break
    }
    sb.write_char(ch.unsafe_to_char())
    i = i + 1
  }
  let name = sb.to_string()
  if name.length() == 0 {
    "main"
  } else {
    name
  }
}

///|
fn load_target(target : String) -> Result[(String, Array[String], Array[String]), String] {
  let target_b = str_to_utf8(target)
  if m2_host_file_exists(target_b) == 0 {
    return Err("path does not exist: " + target)
  }
  let pkg_name = basename_pkg(target)
  let paths : Array[String] = []
  let sources : Array[String] = []
  if m2_host_is_dir(target_b) != 0 {
    let listing = utf8_to_str(m2_host_list_sources(target_b))
    let files = split_nonempty_lines(listing)
    let mut i = 0
    while i < files.length() {
      let fpath = files[i]
      let content = utf8_to_str(m2_host_read_file(str_to_utf8(fpath)))
      paths.push(fpath)
      sources.push(content)
      i = i + 1
    }
  } else {
    let content = utf8_to_str(m2_host_read_file(target_b))
    paths.push(target)
    sources.push(content)
  }
  Ok((pkg_name, paths, sources))
}

///|
fn usage() -> Unit {
  write_err(
    "usage:\n" +
    "  m2c check [--json] <file_or_dir>\n" +
    "  m2c query defs|sig|callers|deps [--json] <file_or_dir>\n" +
    "  m2c emit-sig <file_or_dir>\n",
  )
}

///|
fn main {
  let args = @env.args()
  if args.length() < 3 {
    usage()
    m2_host_exit(1)
    return
  }
  let cmd = args[1]
  if cmd == "check" {
    let mut target = ""
    let mut i = 2
    while i < args.length() {
      if args[i] != "--json" {
        target = args[i]
      }
      i = i + 1
    }
    if target == "" {
      usage()
      m2_host_exit(1)
      return
    }
    match load_target(target) {
      Err(msg) => {
        write_err("error: " + msg + "\n")
        m2_host_exit(1)
      }
      Ok((pkg_name, paths, sources)) => {
        let (ok, json) = @core.cli_check_json(pkg_name, paths, sources)
        write_out(json + "\n")
        if !ok {
          m2_host_exit(1)
        }
      }
    }
  } else if cmd == "query" {
    if args.length() < 4 {
      usage()
      m2_host_exit(1)
      return
    }
    let kind = args[2]
    let mut target = ""
    let mut i = 3
    while i < args.length() {
      if args[i] != "--json" {
        target = args[i]
      }
      i = i + 1
    }
    if target == "" {
      usage()
      m2_host_exit(1)
      return
    }
    match load_target(target) {
      Err(msg) => {
        write_err("error: " + msg + "\n")
        m2_host_exit(1)
      }
      Ok((pkg_name, paths, sources)) =>
        match @core.cli_query_json(kind, pkg_name, paths, sources) {
          Ok(json) => write_out(json + "\n")
          Err(msg) => {
            write_err("error: " + msg + "\n")
            m2_host_exit(1)
          }
        }
    }
  } else if cmd == "emit-sig" {
    let target = args[2]
    match load_target(target) {
      Err(msg) => {
        write_err("error: " + msg + "\n")
        m2_host_exit(1)
      }
      Ok((pkg_name, paths, sources)) => {
        let sig = @core.cli_emit_sig(pkg_name, paths, sources)
        write_out(sig)
      }
    }
  } else {
    usage()
    m2_host_exit(1)
  }
}
