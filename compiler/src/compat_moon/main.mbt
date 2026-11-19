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
#borrow(path, data)
extern "C" fn m2_host_write_file(path : Bytes, data : Bytes) -> Int = "m2_host_write_file"

///|
#borrow(path)
extern "C" fn m2_host_mkdir_p(path : Bytes) -> Int = "m2_host_mkdir_p"

///|
#borrow(path)
extern "C" fn m2_host_remove(path : Bytes) -> Int = "m2_host_remove"

///|
#borrow(old_p, new_p)
extern "C" fn m2_host_rename(old_p : Bytes, new_p : Bytes) -> Int = "m2_host_rename"

///|
#borrow(path)
extern "C" fn m2_host_file_size(path : Bytes) -> Int64 = "m2_host_file_size"

///|
#borrow(name)
extern "C" fn m2_host_env_get(name : Bytes) -> Bytes = "m2_host_env_get"

///|
extern "C" fn m2_host_clock_ms() -> Int64 = "m2_host_clock_ms"

///|
extern "C" fn m2_host_getpid() -> Int = "m2_host_getpid"

///|
#borrow(argv)
extern "C" fn m2_host_exec(argv : Bytes) -> Int = "m2_host_exec"

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
fn env_str(name : String) -> String {
  utf8_to_str(m2_host_env_get(str_to_utf8(name)))
}

///|
fn file_exists(path : String) -> Bool {
  m2_host_file_exists(str_to_utf8(path)) != 0
}

///|
fn read_text(path : String) -> String {
  utf8_to_str(m2_host_read_file(str_to_utf8(path)))
}

///|
fn write_text_atomic(path : String, content : String) -> Bool {
  let tmp = path + ".tmp." + m2_host_getpid().to_string()
  if m2_host_write_file(str_to_utf8(tmp), str_to_utf8(content)) == 0 {
    return false
  }
  m2_host_rename(str_to_utf8(tmp), str_to_utf8(path)) != 0
}

///|
fn exec_argv(argv : Array[String]) -> Int {
  let sb = StringBuilder()
  let mut i = 0
  while i < argv.length() {
    if i > 0 {
      sb.write_string("\n")
    }
    sb.write_string(argv[i])
    i = i + 1
  }
  m2_host_exec(str_to_utf8(sb.to_string()))
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
fn parse_pos_int64(s : String, fallback : Int64) -> Int64 {
  if s.length() == 0 {
    return fallback
  }
  let mut acc = 0L
  let mut i = 0
  while i < s.length() {
    let c = s[i].to_int()
    if c >= 48 && c <= 57 {
      acc = acc * 10L + (c - 48).to_int64()
    } else {
      return fallback
    }
    i = i + 1
  }
  if acc > 0L {
    acc
  } else {
    fallback
  }
}

///|
fn prefix16(s : String) -> String {
  let sb = StringBuilder()
  let mut i = 0
  while i < 16 && i < s.length() {
    sb.write_char(s[i].to_int().unsafe_to_char())
    i = i + 1
  }
  sb.to_string()
}

///|
fn resolve_cache_dir() -> String {
  let custom = env_str("M2_CACHE_DIR")
  if custom.length() > 0 {
    return custom
  }
  let home = env_str("HOME")
  if home.length() > 0 {
    home + "/.cache/m2/cas"
  } else {
    "/tmp/m2-cas"
  }
}

///|
fn resolve_cache_max_bytes() -> Int64 {
  let kb_s = env_str("M2_CACHE_MAX_KB")
  if kb_s.length() > 0 {
    return parse_pos_int64(kb_s, 1024L) * 1024L
  }
  let mb_s = env_str("M2_CACHE_MAX_MB")
  parse_pos_int64(mb_s, 2048L) * 1024L * 1024L
}

///|
fn resolve_qbe_bin() -> String {
  let env_qbe = env_str("M2_QBE")
  if env_qbe.length() > 0 {
    return env_qbe
  }
  if file_exists("out/qbe") {
    return "out/qbe"
  }
  if file_exists("../out/qbe") {
    return "../out/qbe"
  }
  "qbe"
}

///|
fn resolve_rt_lib() -> String {
  let env_rt = env_str("M2_RT_LIB")
  if env_rt.length() > 0 {
    return env_rt
  }
  if file_exists("out/libm2rt.a") {
    return "out/libm2rt.a"
  }
  if file_exists("../out/libm2rt.a") {
    return "../out/libm2rt.a"
  }
  "out/libm2rt.a"
}

///|
fn resolve_qbe_target() -> String {
  let env_t = env_str("M2_TARGET")
  if env_t.length() > 0 {
    env_t
  } else {
    "arm64_apple"
  }
}

///|
fn parent_dir(path : String) -> String {
  let mut idx = path.length() - 1
  while idx >= 0 && path[idx].to_int() != 47 {
    idx = idx - 1
  }
  if idx <= 0 {
    return ""
  }
  let sb = StringBuilder()
  let mut i = 0
  while i < idx {
    sb.write_char(path[i].to_int().unsafe_to_char())
    i = i + 1
  }
  sb.to_string()
}

///|
fn ensure_parent_dir(path : String) -> Unit {
  let dir = parent_dir(path)
  if dir.length() > 0 {
    let _ = m2_host_mkdir_p(str_to_utf8(dir))
  }
}

///|
fn load_targets(
  targets : Array[String],
) -> Result[(String, Array[String], Array[String]), String] {
  if targets.length() == 0 {
    return Err("no input files specified")
  }
  let pkg_name = basename_pkg(targets[0])
  let paths : Array[String] = []
  let sources : Array[String] = []
  let mut t = 0
  while t < targets.length() {
    let target = targets[t]
    let target_b = str_to_utf8(target)
    if m2_host_file_exists(target_b) == 0 {
      return Err("path does not exist: " + target)
    }
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
    t = t + 1
  }
  Ok((pkg_name, paths, sources))
}

///|
fn cas_record_and_evict(
  cache_dir : String,
  key : String,
  entry_bytes : Int64,
) -> Unit {
  let index_path = cache_dir + "/index.tsv"
  let entries = if file_exists(index_path) {
    @core.cas_parse_index(read_text(index_path))
  } else {
    []
  }
  let now = m2_host_clock_ms()
  let max_bytes = resolve_cache_max_bytes()
  let ev = @core.cas_touch_and_evict(entries, key, entry_bytes, now, max_bytes)
  let mut i = 0
  while i < ev.evicted.length() {
    let ek = ev.evicted[i]
    let _ = m2_host_remove(str_to_utf8(cache_dir + "/sig/" + ek + ".m2sig"))
    let _ = m2_host_remove(str_to_utf8(cache_dir + "/ssa/" + ek + ".ssa"))
    let _ = m2_host_remove(str_to_utf8(cache_dir + "/obj/" + ek + ".o"))
    i = i + 1
  }
  let _ = write_text_atomic(index_path, @core.cas_format_index(ev.kept))
}

///|
fn build_targets(
  targets : Array[String],
  release : Bool,
  emit_ssa_path : String,
  emit_asm_path : String,
  out_bin_arg : String,
) -> Result[String, String] {
  let loaded = match load_targets(targets) {
    Err(msg) => return Err(msg)
    Ok(v) => v
  }
  let (pkg_name, paths, sources) = loaded

  let cache_dir = resolve_cache_dir()
  let _ = m2_host_mkdir_p(str_to_utf8(cache_dir + "/sig"))
  let _ = m2_host_mkdir_p(str_to_utf8(cache_dir + "/ssa"))
  let _ = m2_host_mkdir_p(str_to_utf8(cache_dir + "/obj"))
  let _ = m2_host_mkdir_p(str_to_utf8(cache_dir + "/bin"))

  let qbe_target = resolve_qbe_target()
  let qbe_bin = resolve_qbe_bin()

  if paths.length() > 1 && emit_ssa_path == "" && emit_asm_path == "" {
    let prep = match @core.cli_prepare_qbe_units(pkg_name, paths, sources) {
      Err(diag_json) => return Err(diag_json)
      Ok(p) => p
    }
    let n_units = paths.length()
    let unit_keys : Array[String] = []
    let obj_paths : Array[String] = []
    let miss_indices : Array[Int] = []
    let pkg_key_sb = StringBuilder()
    pkg_key_sb.write_string(prep.sigs_hash)
    let mut ui = 0
    while ui < n_units {
      let src_h = @core.cas_sha256_hex(sources[ui])
      let ukey = @core.cas_compute_unit_key(
        pkg_name,
        ui,
        paths[ui],
        src_h,
        prep.sigs_hash,
        qbe_target,
        release,
      )
      unit_keys.push(ukey)
      pkg_key_sb.write_string(":")
      pkg_key_sb.write_string(ukey)
      let uobj = cache_dir + "/obj/" + ukey + ".o"
      obj_paths.push(uobj)
      if !file_exists(uobj) {
        miss_indices.push(ui)
      }
      ui = ui + 1
    }
    let pkg_key = @core.cas_sha256_hex(pkg_key_sb.to_string())
    let default_bin = cache_dir + "/bin/" + pkg_name + "_" + prefix16(pkg_key)
    let final_bin = if out_bin_arg != "" { out_bin_arg } else { default_bin }
    if miss_indices.length() == 0 && out_bin_arg == "" && file_exists(final_bin) {
      return Ok(final_bin)
    }
    let pid_s = m2_host_getpid().to_string()
    let mut mi = 0
    while mi < miss_indices.length() {
      let idx = miss_indices[mi]
      let ukey = unit_keys[idx]
      let u_ssa = cache_dir + "/ssa/" + ukey + ".ssa"
      let u_obj = obj_paths[idx]
      let u_asm = cache_dir + "/obj/" + ukey + ".s." + pid_s + "_" + idx.to_string()
      let u_tmp = u_obj + ".tmp." + pid_s + "_" + idx.to_string()
      let ssa_text = @core.emit_qbe_unit(prep, idx, release)
      if !write_text_atomic(u_ssa, ssa_text) {
        return Err("failed to write CAS unit ssa: " + u_ssa)
      }
      let rc_qbe = exec_argv([qbe_bin, "-t", qbe_target, "-o", u_asm, u_ssa])
      if rc_qbe != 0 {
        let _ = m2_host_remove(str_to_utf8(u_asm))
        return Err("qbe failed with exit code " + rc_qbe.to_string() + " on " + u_ssa)
      }
      let rc_as = exec_argv(["as", "-o", u_tmp, u_asm])
      let _ = m2_host_remove(str_to_utf8(u_asm))
      if rc_as != 0 {
        let _ = m2_host_remove(str_to_utf8(u_tmp))
        return Err("as failed with exit code " + rc_as.to_string())
      }
      let _ = m2_host_rename(str_to_utf8(u_tmp), str_to_utf8(u_obj))
      mi = mi + 1
    }
    if !prep.has_main && out_bin_arg == "" {
      return Ok(obj_paths[0])
    }
    if out_bin_arg != "" {
      ensure_parent_dir(out_bin_arg)
    }
    let rt_lib = resolve_rt_lib()
    let cc = {
      let e = env_str("CC")
      if e.length() > 0 { e } else { "clang" }
    }
    let ld_argv : Array[String] = [cc]
    let mut oi = 0
    while oi < obj_paths.length() {
      ld_argv.push(obj_paths[oi])
      oi = oi + 1
    }
    ld_argv.push(rt_lib)
    ld_argv.push("-lpthread")
    ld_argv.push("-o")
    ld_argv.push(final_bin)
    let rc_ld = exec_argv(ld_argv)
    if rc_ld != 0 {
      return Err("linker failed with exit code " + rc_ld.to_string())
    }
    return Ok(final_bin)
  }
  let key = @core.cas_compute_key(pkg_name, paths, sources, [], qbe_target, release)
  let sig_path = cache_dir + "/sig/" + key + ".m2sig"
  let ssa_path = cache_dir + "/ssa/" + key + ".ssa"
  let obj_path = cache_dir + "/obj/" + key + ".o"
  let default_bin = cache_dir + "/bin/" + pkg_name + "_" + prefix16(key)
  let final_bin = if out_bin_arg != "" { out_bin_arg } else { default_bin }

  let mut has_main = true
  let cache_hit = file_exists(obj_path) && file_exists(ssa_path) && file_exists(sig_path)

  if cache_hit {
    if emit_ssa_path != "" {
      ensure_parent_dir(emit_ssa_path)
      let ssa_cached = read_text(ssa_path)
      if !write_text_atomic(emit_ssa_path, ssa_cached) {
        return Err("failed to write --emit-ssa file: " + emit_ssa_path)
      }
    }
    if emit_asm_path != "" {
      ensure_parent_dir(emit_asm_path)
      let rc_qbe = exec_argv([qbe_bin, "-t", qbe_target, "-o", emit_asm_path, ssa_path])
      if rc_qbe != 0 {
        return Err("qbe failed with exit code " + rc_qbe.to_string() + " on " + ssa_path)
      }
    }
    let sz_sig = m2_host_file_size(str_to_utf8(sig_path))
    let sz_ssa = m2_host_file_size(str_to_utf8(ssa_path))
    let sz_obj = m2_host_file_size(str_to_utf8(obj_path))
    let total_sz = (if sz_sig > 0L { sz_sig } else { 0L }) +
      (if sz_ssa > 0L { sz_ssa } else { 0L }) +
      (if sz_obj > 0L { sz_obj } else { 0L })
    cas_record_and_evict(cache_dir, key, total_sz)
    // On cache hit, if linking to default_bin and it already exists, skip link!
    if out_bin_arg == "" && file_exists(final_bin) {
      return Ok(final_bin)
    }
    if (emit_ssa_path != "" || emit_asm_path != "") && out_bin_arg == "" {
      return Ok(obj_path)
    }
  } else {
    let compiled = match @core.cli_compile_qbe(pkg_name, paths, sources, release) {
      Err(diag_json) => return Err(diag_json)
      Ok(c) => c
    }
    has_main = compiled.has_main
    if !write_text_atomic(sig_path, compiled.sig) {
      return Err("failed to write CAS sig: " + sig_path)
    }
    if !write_text_atomic(ssa_path, compiled.ssa) {
      return Err("failed to write CAS ssa: " + ssa_path)
    }
    if emit_ssa_path != "" {
      ensure_parent_dir(emit_ssa_path)
      if !write_text_atomic(emit_ssa_path, compiled.ssa) {
        return Err("failed to write --emit-ssa file: " + emit_ssa_path)
      }
    }

    let asm_path = cache_dir + "/obj/" + key + ".s." + m2_host_getpid().to_string()
    let obj_tmp = obj_path + ".tmp." + m2_host_getpid().to_string()
    let rc_qbe = exec_argv([qbe_bin, "-t", qbe_target, "-o", asm_path, ssa_path])
    if rc_qbe != 0 {
      let _ = m2_host_remove(str_to_utf8(asm_path))
      return Err("qbe failed with exit code " + rc_qbe.to_string() + " on " + ssa_path)
    }
    if emit_asm_path != "" {
      ensure_parent_dir(emit_asm_path)
      let asm_text = read_text(asm_path)
      if !write_text_atomic(emit_asm_path, asm_text) {
        let _ = m2_host_remove(str_to_utf8(asm_path))
        return Err("failed to write --emit-asm file: " + emit_asm_path)
      }
    }
    let rc_as = exec_argv(["as", "-o", obj_tmp, asm_path])
    let _ = m2_host_remove(str_to_utf8(asm_path))
    if rc_as != 0 {
      let _ = m2_host_remove(str_to_utf8(obj_tmp))
      return Err("as failed with exit code " + rc_as.to_string())
    }
    let _ = m2_host_rename(str_to_utf8(obj_tmp), str_to_utf8(obj_path))

    let sz_sig = m2_host_file_size(str_to_utf8(sig_path))
    let sz_ssa = m2_host_file_size(str_to_utf8(ssa_path))
    let sz_obj = m2_host_file_size(str_to_utf8(obj_path))
    let total_sz = (if sz_sig > 0L { sz_sig } else { 0L }) +
      (if sz_ssa > 0L { sz_ssa } else { 0L }) +
      (if sz_obj > 0L { sz_obj } else { 0L })
    cas_record_and_evict(cache_dir, key, total_sz)
  }

  if !has_main && out_bin_arg == "" {
    return Ok(obj_path)
  }

  if out_bin_arg != "" {
    ensure_parent_dir(out_bin_arg)
  }
  let rt_lib = resolve_rt_lib()
  let cc = {
    let e = env_str("CC")
    if e.length() > 0 { e } else { "clang" }
  }
  let rc_ld = exec_argv([cc, obj_path, rt_lib, "-lpthread", "-o", final_bin])
  if rc_ld != 0 {
    return Err("linker failed with exit code " + rc_ld.to_string())
  }
  Ok(final_bin)
}

///|
fn usage() -> Unit {
  write_err(
    "usage:\n" +
    "  m2c check [--json] <input1> [input2 ...]\n" +
    "  m2c query defs|sig|callers|deps [--json] <input1> [input2 ...]\n" +
    "  m2c emit-sig <input1> [input2 ...]\n" +
    "  m2c build [--release] [--emit-ssa <path>] [--emit-asm <path>] [--jobs <n>] [-o <out>] <input1> [input2 ...]\n" +
    "  m2c run [--release] <input> [-- args...]\n",
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
    let targets : Array[String] = []
    let mut i = 2
    while i < args.length() {
      if args[i] != "--json" {
        targets.push(args[i])
      }
      i = i + 1
    }
    if targets.length() == 0 {
      usage()
      m2_host_exit(1)
      return
    }
    match load_targets(targets) {
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
    let targets : Array[String] = []
    let mut i = 3
    while i < args.length() {
      if args[i] != "--json" {
        targets.push(args[i])
      }
      i = i + 1
    }
    if targets.length() == 0 {
      usage()
      m2_host_exit(1)
      return
    }
    match load_targets(targets) {
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
    let targets : Array[String] = []
    let mut i = 2
    while i < args.length() {
      targets.push(args[i])
      i = i + 1
    }
    match load_targets(targets) {
      Err(msg) => {
        write_err("error: " + msg + "\n")
        m2_host_exit(1)
      }
      Ok((pkg_name, paths, sources)) => {
        let sig = @core.cli_emit_sig(pkg_name, paths, sources)
        write_out(sig)
      }
    }
  } else if cmd == "build" {
    let mut release = false
    let mut emit_ssa = ""
    let mut emit_asm = ""
    let mut out_bin = ""
    let targets : Array[String] = []
    let mut i = 2
    while i < args.length() {
      let a = args[i]
      if a == "--release" {
        release = true
      } else if a == "--emit-ssa" && i + 1 < args.length() {
        emit_ssa = args[i + 1]
        i = i + 1
      } else if a == "--emit-asm" && i + 1 < args.length() {
        emit_asm = args[i + 1]
        i = i + 1
      } else if a == "--jobs" && i + 1 < args.length() {
        i = i + 1
      } else if a == "-o" && i + 1 < args.length() {
        out_bin = args[i + 1]
        i = i + 1
      } else {
        targets.push(a)
      }
      i = i + 1
    }
    if targets.length() == 0 {
      usage()
      m2_host_exit(1)
      return
    }
    match build_targets(targets, release, emit_ssa, emit_asm, out_bin) {
      Ok(_) => ()
      Err(msg) => {
        write_err(msg + "\n")
        m2_host_exit(1)
      }
    }
  } else if cmd == "run" {
    let mut release = false
    let mut target = ""
    let prog_args : Array[String] = []
    let mut after_sep = false
    let mut i = 2
    while i < args.length() {
      let a = args[i]
      if after_sep {
        prog_args.push(a)
      } else if a == "--" {
        after_sep = true
      } else if a == "--release" && target == "" {
        release = true
      } else if target == "" {
        target = a
      } else {
        prog_args.push(a)
      }
      i = i + 1
    }
    if target == "" {
      usage()
      m2_host_exit(1)
      return
    }
    match build_targets([target], release, "", "", "") {
      Err(msg) => {
        write_err(msg + "\n")
        m2_host_exit(1)
      }
      Ok(bin_path) => {
        let run_argv : Array[String] = [bin_path]
        let mut j = 0
        while j < prog_args.length() {
          run_argv.push(prog_args[j])
          j = j + 1
        }
        let rc = exec_argv(run_argv)
        if rc != 0 {
          m2_host_exit(rc)
        }
      }
    }
  } else {
    usage()
    m2_host_exit(1)
  }
}
