///| Pure m2 native compiler driver (zero MoonBit runtime dependency)

///|
struct DrvLoaded {
  pkg_name : String
  paths : Array[String]
  sources : Array[String]
}

///|
fn drv_ends_with(s : String, suf : String) -> Bool {
  let sl = s.length()
  let sufl = suf.length()
  if sl < sufl {
    return false
  }
  let off = sl - sufl
  let mut i = 0
  while i < sufl {
    if str_code_at(s, off + i) != str_code_at(suf, i) {
      return false
    }
    i = i + 1
  }
  true
}

///|
fn drv_is_source_file(name : String) -> Bool {
  if name.length() == 0 {
    return false
  }
  if str_code_at(name, 0) == 46 {
    return false
  }
  let is_src = drv_ends_with(name, ".m2") || drv_ends_with(name, ".mbt")
  let is_test = drv_ends_with(name, "_test.m2") || drv_ends_with(name, "_test.mbt")
  is_src && !is_test
}

///|
fn drv_join_path(dir : String, name : String) -> String {
  if dir.length() == 0 {
    return name
  }
  if str_code_at(dir, dir.length() - 1) == 47 {
    dir + name
  } else {
    dir + "/" + name
  }
}

///|
fn drv_parent_dir(path : String) -> String {
  let mut idx = path.length() - 1
  while idx >= 0 && str_code_at(path, idx) != 47 {
    idx = idx - 1
  }
  if idx <= 0 {
    return ""
  }
  let sb = StringBuilder()
  let mut i = 0
  while i < idx {
    sb.write_char(str_code_at(path, i).unsafe_to_char())
    i = i + 1
  }
  sb.to_string()
}

///|
fn drv_ensure_parent_dir(world : World, path : String) -> Unit {
  let dir = drv_parent_dir(path)
  if dir.length() > 0 {
    let _ = fs_mkdir_p(world, dir)
  }
}

///|
fn drv_basename_pkg(path : String) -> String {
  let mut end = path.length()
  while end > 1 && str_code_at(path, end - 1) == 47 {
    end = end - 1
  }
  let mut start = end - 1
  while start >= 0 && str_code_at(path, start) != 47 {
    start = start - 1
  }
  let sb = StringBuilder()
  let mut i = start + 1
  while i < end {
    let ch = str_code_at(path, i)
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
fn drv_prefix16(s : String) -> String {
  let sb = StringBuilder()
  let mut i = 0
  while i < 16 && i < s.length() {
    sb.write_char(str_code_at(s, i).unsafe_to_char())
    i = i + 1
  }
  sb.to_string()
}

///|
fn drv_parse_pos_int64(s : String, fallback : Int64) -> Int64 {
  if s.length() == 0 {
    return fallback
  }
  let mut acc = 0L
  let mut i = 0
  while i < s.length() {
    let c = str_code_at(s, i)
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
fn drv_parse_pos_int(s : String, fallback : Int) -> Int {
  let v = drv_parse_pos_int64(s, fallback.to_int64()).to_int()
  if v > 0 {
    v
  } else {
    fallback
  }
}

///|
fn drv_env_str(world : World, name : String) -> String {
  match env_get(world, name) {
    Some(v) => v
    None => ""
  }
}

///|
fn drv_resolve_cache_dir(world : World) -> String {
  let custom = drv_env_str(world, "M2_CACHE_DIR")
  if custom.length() > 0 {
    return custom
  }
  let home = drv_env_str(world, "HOME")
  if home.length() > 0 {
    home + "/.cache/m2/cas"
  } else {
    "/tmp/m2-cas"
  }
}

///|
fn drv_resolve_cache_max_bytes(world : World) -> Int64 {
  let kb_s = drv_env_str(world, "M2_CACHE_MAX_KB")
  if kb_s.length() > 0 {
    return drv_parse_pos_int64(kb_s, 1024L) * 1024L
  }
  let mb_s = drv_env_str(world, "M2_CACHE_MAX_MB")
  drv_parse_pos_int64(mb_s, 2048L) * 1024L * 1024L
}

///|
fn drv_resolve_qbe_bin(world : World) -> String {
  let env_qbe = drv_env_str(world, "M2_QBE")
  if env_qbe.length() > 0 {
    return env_qbe
  }
  if fs_exists(world, "out/qbe") {
    return "out/qbe"
  }
  if fs_exists(world, "../out/qbe") {
    return "../out/qbe"
  }
  "qbe"
}

///|
fn drv_resolve_rt_lib(world : World) -> String {
  let env_rt = drv_env_str(world, "M2_RT_LIB")
  if env_rt.length() > 0 {
    return env_rt
  }
  if fs_exists(world, "out/libm2rt.a") {
    return "out/libm2rt.a"
  }
  if fs_exists(world, "../out/libm2rt.a") {
    return "../out/libm2rt.a"
  }
  "out/libm2rt.a"
}

///|
fn drv_resolve_qbe_target(world : World) -> String {
  let env_t = drv_env_str(world, "M2_TARGET")
  if env_t.length() > 0 {
    env_t
  } else {
    "arm64_apple"
  }
}

///|
fn drv_write_text_atomic(world : World, path : String, content : String) -> Bool {
  let tmp = path + ".tmp." + clock_now_ms(world).to_string()
  match fs_write(world, tmp, content) {
    Err(_) => return false
    Ok(_) => ()
  }
  fs_rename(world, tmp, path)
}

///|
fn drv_load_targets(
  world : World,
  targets : Array[String],
) -> Result[DrvLoaded, String] {
  if targets.length() == 0 {
    return Err("no input files specified")
  }
  let pkg_name = drv_basename_pkg(targets[0])
  let paths : Array[String] = []
  let sources : Array[String] = []
  let mut t = 0
  while t < targets.length() {
    let target = targets[t]
    if !fs_exists(world, target) {
      return Err("path does not exist: " + target)
    }
    if fs_is_dir(world, target) {
      let entries = fs_list_dir(world, target)
      let mut i = 0
      while i < entries.length() {
        let name = entries[i]
        if drv_is_source_file(name) {
          let fpath = drv_join_path(target, name)
          match fs_read(world, fpath) {
            Err(msg) => return Err("failed to read " + fpath + ": " + msg)
            Ok(content) => {
              paths.push(fpath)
              sources.push(content)
            }
          }
        }
        i = i + 1
      }
    } else {
      match fs_read(world, target) {
        Err(msg) => return Err("failed to read " + target + ": " + msg)
        Ok(content) => {
          paths.push(target)
          sources.push(content)
        }
      }
    }
    t = t + 1
  }
  Ok(DrvLoaded::{ pkg_name: pkg_name, paths: paths, sources: sources })
}

///|
/// Parallel per-file SHA-256 pre-hash using m2 native OS threads (scope + spawn + Channel + AtomicInt).
/// Results are always reassembled in deterministic input index order.
fn drv_parallel_prehash(
  world : World,
  sources : Array[String],
  jobs : Int,
) -> Array[String] {
  let n = sources.length()
  let out : Array[String] = []
  let mut k = 0
  while k < n {
    out.push("")
    k = k + 1
  }
  if n <= 1 || jobs <= 1 {
    let mut i = 0
    while i < n {
      out[i] = sha256_hex(sources[i])
      i = i + 1
    }
    return out
  }
  let mut base = 0
  while base < n {
    let mut batch = n - base
    if batch > jobs {
      batch = jobs
    }
    let ch : Channel[String] = Channel::new(batch + 1)
    let done = AtomicInt::new(0)
    scope(world, fn(s : Scope) -> Unit {
      let mut off = 0
      while off < batch {
        let idx = base + off
        let src = sources[idx]
        spawn(s, fn() -> Unit {
          let h = sha256_hex(src)
          let _ = ch.send(idx.to_string() + ":" + h)
          let _ = done.fetch_add(1)
        })
        off = off + 1
      }
    })
    ch.close()
    while true {
      match ch.recv() {
        Some(msg) => {
          let mut colon = -1
          let mut j = 0
          while j < msg.length() {
            if str_code_at(msg, j) == 58 {
              colon = j
              break
            }
            j = j + 1
          }
          if colon > 0 {
            let idx_sb = StringBuilder()
            let mut a = 0
            while a < colon {
              idx_sb.write_char(str_code_at(msg, a).unsafe_to_char())
              a = a + 1
            }
            let h_sb = StringBuilder()
            let mut b = colon + 1
            while b < msg.length() {
              h_sb.write_char(str_code_at(msg, b).unsafe_to_char())
              b = b + 1
            }
            let idx = drv_parse_pos_int64(idx_sb.to_string(), 0L).to_int()
            if idx >= 0 && idx < n {
              out[idx] = h_sb.to_string()
            }
          }
        }
        None => break
      }
    }
    let _ = done.load()
    base = base + batch
  }
  out
}

///|
fn drv_cas_record_and_evict(
  world : World,
  cache_dir : String,
  key : String,
  entry_bytes : Int64,
) -> Unit {
  let index_path = cache_dir + "/index.tsv"
  let entries : Array[CasEntry] = if fs_exists(world, index_path) {
    match fs_read(world, index_path) {
      Ok(txt) => cas_parse_index(txt)
      Err(_) => []
    }
  } else {
    []
  }
  let now = clock_now_ms(world)
  let max_bytes = drv_resolve_cache_max_bytes(world)
  let ev = cas_touch_and_evict(entries, key, entry_bytes, now, max_bytes)
  let mut i = 0
  while i < ev.evicted.length() {
    let ek = ev.evicted[i]
    let _ = fs_remove(world, cache_dir + "/sig/" + ek + ".m2sig")
    let _ = fs_remove(world, cache_dir + "/ssa/" + ek + ".ssa")
    let _ = fs_remove(world, cache_dir + "/obj/" + ek + ".o")
    i = i + 1
  }
  let _ = drv_write_text_atomic(world, index_path, cas_format_index(ev.kept))
}

///|
fn drv_build_targets(
  world : World,
  targets : Array[String],
  release : Bool,
  emit_ssa_path : String,
  emit_asm_path : String,
  out_bin_arg : String,
  jobs : Int,
) -> Result[String, String] {
  let loaded = match drv_load_targets(world, targets) {
    Err(msg) => return Err(msg)
    Ok(v) => v
  }
  let pkg_name = loaded.pkg_name
  let paths = loaded.paths
  let sources = loaded.sources

  // Dogfood m2 native multithreading on multi-file builds (deterministic order)
  let src_hashes = drv_parallel_prehash(world, sources, jobs)

  let cache_dir = drv_resolve_cache_dir(world)
  let _ = fs_mkdir_p(world, cache_dir + "/sig")
  let _ = fs_mkdir_p(world, cache_dir + "/ssa")
  let _ = fs_mkdir_p(world, cache_dir + "/obj")
  let _ = fs_mkdir_p(world, cache_dir + "/bin")

  let qbe_target = drv_resolve_qbe_target(world)
  let qbe_bin = drv_resolve_qbe_bin(world)

  // Multi-file unit-level parallel compilation + unit-level global CAS
  if paths.length() > 1 && emit_ssa_path == "" && emit_asm_path == "" {
    let prep = match cli_prepare_qbe_units(pkg_name, paths, sources) {
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
      let ukey = cas_compute_unit_key(
        pkg_name,
        ui,
        paths[ui],
        src_hashes[ui],
        prep.sigs_hash,
        qbe_target,
        release,
      )
      unit_keys.push(ukey)
      pkg_key_sb.write_string(":")
      pkg_key_sb.write_string(ukey)
      let uobj = cache_dir + "/obj/" + ukey + ".o"
      obj_paths.push(uobj)
      if !fs_exists(world, uobj) {
        miss_indices.push(ui)
      }
      ui = ui + 1
    }
    let pkg_key = sha256_hex(pkg_key_sb.to_string())
    let default_bin = cache_dir + "/bin/" + pkg_name + "_" + drv_prefix16(pkg_key)
    let final_bin = if out_bin_arg != "" { out_bin_arg } else { default_bin }

    if miss_indices.length() == 0 && out_bin_arg == "" && fs_exists(world, final_bin) {
      return Ok(final_bin)
    }

    // Emit QBE SSA only for cache-missed units
    let mut mi = 0
    while mi < miss_indices.length() {
      let idx = miss_indices[mi]
      let ukey = unit_keys[idx]
      let u_ssa = cache_dir + "/ssa/" + ukey + ".ssa"
      let ssa_text = emit_qbe_unit(prep, idx, release)
      if !drv_write_text_atomic(world, u_ssa, ssa_text) {
        return Err("failed to write CAS unit ssa: " + u_ssa)
      }
      mi = mi + 1
    }

    // Compile missed units (qbe + as) in parallel across up to `jobs` OS threads
    let n_miss = miss_indices.length()
    if n_miss == 1 || jobs <= 1 {
      let stamp = clock_now_ms(world).to_string()
      mi = 0
      while mi < n_miss {
        let idx = miss_indices[mi]
        let ukey = unit_keys[idx]
        let u_ssa = cache_dir + "/ssa/" + ukey + ".ssa"
        let u_obj = obj_paths[idx]
        let u_asm = cache_dir + "/obj/" + ukey + ".s." + stamp + "_" + idx.to_string()
        let u_tmp = u_obj + ".tmp." + stamp + "_" + idx.to_string()
        let rc_qbe = proc_exec(world, [qbe_bin, "-t", qbe_target, "-o", u_asm, u_ssa])
        if rc_qbe != 0 {
          let _ = fs_remove(world, u_asm)
          return Err("qbe failed with exit code " + rc_qbe.to_string() + " on " + u_ssa)
        }
        let rc_as = proc_exec(world, ["as", "-o", u_tmp, u_asm])
        let _ = fs_remove(world, u_asm)
        if rc_as != 0 {
          let _ = fs_remove(world, u_tmp)
          return Err("as failed with exit code " + rc_as.to_string())
        }
        let _ = fs_rename(world, u_tmp, u_obj)
        mi = mi + 1
      }
    } else if n_miss > 1 {
      let mut base = 0
      while base < n_miss {
        let mut batch = n_miss - base
        if batch > jobs {
          batch = jobs
        }
        let err_ch : Channel[String] = Channel::new(batch + 1)
        let stamp_base = clock_now_ms(world).to_string()
        scope(world, fn(s : Scope) -> Unit {
          let mut off = 0
          while off < batch {
            let idx = miss_indices[base + off]
            let ukey = unit_keys[idx]
            let u_ssa = cache_dir + "/ssa/" + ukey + ".ssa"
            let u_obj = obj_paths[idx]
            let u_asm = cache_dir + "/obj/" + ukey + ".s." + stamp_base + "_" + idx.to_string()
            let u_tmp = u_obj + ".tmp." + stamp_base + "_" + idx.to_string()
            let qb = qbe_bin
            let qt = qbe_target
            spawn(s, fn() -> Unit {
              let rc_qbe = proc_exec([qb, "-t", qt, "-o", u_asm, u_ssa])
              if rc_qbe != 0 {
                let _ = fs_remove(u_asm)
                let _ = err_ch.send("qbe failed with exit code " + rc_qbe.to_string() + " on " + u_ssa)
              } else {
                let rc_as = proc_exec(["as", "-o", u_tmp, u_asm])
                let _ = fs_remove(u_asm)
                if rc_as != 0 {
                  let _ = fs_remove(u_tmp)
                  let _ = err_ch.send("as failed with exit code " + rc_as.to_string() + " on " + u_asm)
                } else {
                  let _ = fs_rename(u_tmp, u_obj)
                }
              }
            })
            off = off + 1
          }
        })
        err_ch.close()
        match err_ch.recv() {
          Some(err_msg) => return Err(err_msg)
          None => ()
        }
        base = base + batch
      }
    }

    if !prep.has_main && out_bin_arg == "" {
      return Ok(obj_paths[0])
    }

    if out_bin_arg != "" {
      drv_ensure_parent_dir(world, out_bin_arg)
    }
    let rt_lib = drv_resolve_rt_lib(world)
    let cc = {
      let e = drv_env_str(world, "CC")
      if e.length() > 0 {
        e
      } else {
        "clang"
      }
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
    let rc_ld = proc_exec(world, ld_argv)
    if rc_ld != 0 {
      return Err("linker failed with exit code " + rc_ld.to_string())
    }
    return Ok(final_bin)
  }
  let key = cas_compute_key(pkg_name, paths, sources, [], qbe_target, release)
  let sig_path = cache_dir + "/sig/" + key + ".m2sig"
  let ssa_path = cache_dir + "/ssa/" + key + ".ssa"
  let obj_path = cache_dir + "/obj/" + key + ".o"
  let default_bin = cache_dir + "/bin/" + pkg_name + "_" + drv_prefix16(key)
  let final_bin = if out_bin_arg != "" { out_bin_arg } else { default_bin }

  let mut has_main = true
  let cache_hit = fs_exists(world, obj_path) &&
    fs_exists(world, ssa_path) &&
    fs_exists(world, sig_path)

  if cache_hit {
    if emit_ssa_path != "" {
      drv_ensure_parent_dir(world, emit_ssa_path)
      match fs_read(world, ssa_path) {
        Err(msg) => return Err("failed to read cached ssa: " + msg)
        Ok(ssa_cached) =>
          if !drv_write_text_atomic(world, emit_ssa_path, ssa_cached) {
            return Err("failed to write --emit-ssa file: " + emit_ssa_path)
          }
      }
    }
    if emit_asm_path != "" {
      drv_ensure_parent_dir(world, emit_asm_path)
      let rc_qbe = proc_exec(
        world,
        [qbe_bin, "-t", qbe_target, "-o", emit_asm_path, ssa_path],
      )
      if rc_qbe != 0 {
        return Err(
          "qbe failed with exit code " + rc_qbe.to_string() + " on " + ssa_path,
        )
      }
    }
    let sz_sig = fs_size(world, sig_path)
    let sz_ssa = fs_size(world, ssa_path)
    let sz_obj = fs_size(world, obj_path)
    let total_sz = (if sz_sig > 0L { sz_sig } else { 0L }) +
      (if sz_ssa > 0L { sz_ssa } else { 0L }) +
      (if sz_obj > 0L { sz_obj } else { 0L })
    drv_cas_record_and_evict(world, cache_dir, key, total_sz)
    if out_bin_arg == "" && fs_exists(world, final_bin) {
      return Ok(final_bin)
    }
    if (emit_ssa_path != "" || emit_asm_path != "") && out_bin_arg == "" {
      return Ok(obj_path)
    }
  } else {
    let compiled = match cli_compile_qbe(pkg_name, paths, sources, release) {
      Err(diag_json) => return Err(diag_json)
      Ok(c) => c
    }
    has_main = compiled.has_main
    if !drv_write_text_atomic(world, sig_path, compiled.sig) {
      return Err("failed to write CAS sig: " + sig_path)
    }
    if !drv_write_text_atomic(world, ssa_path, compiled.ssa) {
      return Err("failed to write CAS ssa: " + ssa_path)
    }
    if emit_ssa_path != "" {
      drv_ensure_parent_dir(world, emit_ssa_path)
      if !drv_write_text_atomic(world, emit_ssa_path, compiled.ssa) {
        return Err("failed to write --emit-ssa file: " + emit_ssa_path)
      }
    }

    let stamp = clock_now_ms(world).to_string()
    let asm_path = cache_dir + "/obj/" + key + ".s." + stamp
    let obj_tmp = obj_path + ".tmp." + stamp
    let rc_qbe = proc_exec(
      world,
      [qbe_bin, "-t", qbe_target, "-o", asm_path, ssa_path],
    )
    if rc_qbe != 0 {
      let _ = fs_remove(world, asm_path)
      return Err(
        "qbe failed with exit code " + rc_qbe.to_string() + " on " + ssa_path,
      )
    }
    if emit_asm_path != "" {
      drv_ensure_parent_dir(world, emit_asm_path)
      match fs_read(world, asm_path) {
        Err(msg) => {
          let _ = fs_remove(world, asm_path)
          return Err("failed to read asm: " + msg)
        }
        Ok(asm_text) =>
          if !drv_write_text_atomic(world, emit_asm_path, asm_text) {
            let _ = fs_remove(world, asm_path)
            return Err("failed to write --emit-asm file: " + emit_asm_path)
          }
      }
    }
    let rc_as = proc_exec(world, ["as", "-o", obj_tmp, asm_path])
    let _ = fs_remove(world, asm_path)
    if rc_as != 0 {
      let _ = fs_remove(world, obj_tmp)
      return Err("as failed with exit code " + rc_as.to_string())
    }
    let _ = fs_rename(world, obj_tmp, obj_path)

    let sz_sig = fs_size(world, sig_path)
    let sz_ssa = fs_size(world, ssa_path)
    let sz_obj = fs_size(world, obj_path)
    let total_sz = (if sz_sig > 0L { sz_sig } else { 0L }) +
      (if sz_ssa > 0L { sz_ssa } else { 0L }) +
      (if sz_obj > 0L { sz_obj } else { 0L })
    drv_cas_record_and_evict(world, cache_dir, key, total_sz)
  }

  if !has_main && out_bin_arg == "" {
    return Ok(obj_path)
  }

  if out_bin_arg != "" {
    drv_ensure_parent_dir(world, out_bin_arg)
  }
  let rt_lib = drv_resolve_rt_lib(world)
  let cc = {
    let e = drv_env_str(world, "CC")
    if e.length() > 0 {
      e
    } else {
      "clang"
    }
  }
  let rc_ld = proc_exec(
    world,
    [cc, obj_path, rt_lib, "-lpthread", "-o", final_bin],
  )
  if rc_ld != 0 {
    return Err("linker failed with exit code " + rc_ld.to_string())
  }
  Ok(final_bin)
}

///|
fn drv_usage(world : World) -> Unit {
  io_eprintln(
    world,
    "usage:\n" +
    "  m2c check [--json] <input1> [input2 ...]\n" +
    "  m2c query defs|sig|callers|deps [--json] <input1> [input2 ...]\n" +
    "  m2c emit-sig <input1> [input2 ...]\n" +
    "  m2c build [--release] [--emit-ssa <path>] [--emit-asm <path>] [--jobs <n>] [-o <out>] <input1> [input2 ...]\n" +
    "  m2c run [--release] <input> [-- args...]",
  )
}

///|
pub fn main(world : World) -> Int {
  let args = world_args(world)
  if args.length() >= 2 &&
    (args[1] == "--version" || args[1] == "-V" || args[1] == "version") {
    io_println(world, "m2c2 0.1.0 (self-hosted m2 native compiler)")
    return 0
  }
  if args.length() < 3 {
    drv_usage(world)
    return 1
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
      drv_usage(world)
      return 1
    }
    match drv_load_targets(world, targets) {
      Err(msg) => {
        io_eprintln(world, "error: " + msg)
        return 1
      }
      Ok(loaded) => {
        let _ = drv_parallel_prehash(world, loaded.sources, 4)
        match cli_check_json(loaded.pkg_name, loaded.paths, loaded.sources) {
          (ok, json) => {
            io_println(world, json)
            if !ok {
              return 1
            }
            return 0
          }
          _ => return 1
        }
      }
    }
  } else if cmd == "query" {
    if args.length() < 4 {
      drv_usage(world)
      return 1
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
      drv_usage(world)
      return 1
    }
    match drv_load_targets(world, targets) {
      Err(msg) => {
        io_eprintln(world, "error: " + msg)
        return 1
      }
      Ok(loaded) =>
        match cli_query_json(kind, loaded.pkg_name, loaded.paths, loaded.sources) {
          Ok(json) => {
            io_println(world, json)
            return 0
          }
          Err(msg) => {
            io_eprintln(world, "error: " + msg)
            return 1
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
    match drv_load_targets(world, targets) {
      Err(msg) => {
        io_eprintln(world, "error: " + msg)
        return 1
      }
      Ok(loaded) => {
        let sig = cli_emit_sig(loaded.pkg_name, loaded.paths, loaded.sources)
        io_print(world, sig)
        return 0
      }
    }
  } else if cmd == "build" {
    let mut release = false
    let mut emit_ssa = ""
    let mut emit_asm = ""
    let mut out_bin = ""
    let mut jobs = 8
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
        jobs = drv_parse_pos_int(args[i + 1], 8)
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
      drv_usage(world)
      return 1
    }
    match drv_build_targets(world, targets, release, emit_ssa, emit_asm, out_bin, jobs) {
      Ok(_) => return 0
      Err(msg) => {
        io_eprintln(world, msg)
        return 1
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
      drv_usage(world)
      return 1
    }
    match drv_build_targets(world, [target], release, "", "", "", 4) {
      Err(msg) => {
        io_eprintln(world, msg)
        return 1
      }
      Ok(bin_path) => {
        let run_argv : Array[String] = [bin_path]
        let mut j = 0
        while j < prog_args.length() {
          run_argv.push(prog_args[j])
          j = j + 1
        }
        return proc_exec(world, run_argv)
      }
    }
  } else {
    drv_usage(world)
    return 1
  }
}
