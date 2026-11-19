///| Pure m2 native compiler driver (zero MoonBit runtime dependency)

///|
struct DrvLoaded {
  pkg_name : String
  paths : Array[String]
  sources : Array[String]
}

///|
struct AppleTools {
  ok : Bool
  clang_bin : String
  ld_bin : String
  sdk_path : String
  macos_ver : String
}

///|
fn drv_starts_with(s : String, pre : String) -> Bool {
  let sl = s.length()
  let pl = pre.length()
  if sl < pl {
    return false
  }
  let mut i = 0
  while i < pl {
    if str_code_at(s, i) != str_code_at(pre, i) {
      return false
    }
    i = i + 1
  }
  true
}

///|
fn drv_find_substr(s : String, needle : String, start : Int) -> Int {
  let sl = s.length()
  let nl = needle.length()
  if nl == 0 || start + nl > sl {
    return -1
  }
  let mut i = start
  while i + nl <= sl {
    let mut j = 0
    let mut ok = true
    while j < nl {
      if str_code_at(s, i + j) != str_code_at(needle, j) {
        ok = false
        break
      }
      j = j + 1
    }
    if ok {
      return i
    }
    i = i + 1
  }
  -1
}

///|
fn drv_parse_macos_ver_from_plist(plist : String) -> String {
  let kpos = drv_find_substr(plist, "<key>ProductVersion</key>", 0)
  if kpos < 0 {
    return "15.0"
  }
  let spos = drv_find_substr(plist, "<string>", kpos + 25)
  if spos < 0 {
    return "15.0"
  }
  let vstart = spos + 8
  let vend = drv_find_substr(plist, "</string>", vstart)
  if vend <= vstart {
    return "15.0"
  }
  let sb = StringBuilder()
  let mut dots = 0
  let mut i = vstart
  while i < vend {
    let c = str_code_at(plist, i)
    if c == 46 {
      dots = dots + 1
      if dots >= 2 {
        break
      }
      sb.write_char('.')
    } else if c >= 48 && c <= 57 {
      sb.write_char(c.unsafe_to_char())
    } else {
      break
    }
    i = i + 1
  }
  let v = sb.to_string()
  if v.length() == 0 {
    "15.0"
  } else if dots == 0 {
    v + ".0"
  } else {
    v
  }
}

///|
/// Pure filesystem probe (0 subprocesses, <0.2ms) for real clang (-cc1as), ld, and MacOSX.sdk
/// on macOS arm64_apple when CC is not overridden.
fn drv_probe_apple_tools(world : World, qbe_target : String) -> AppleTools {
  let empty = AppleTools::{
    ok: false,
    clang_bin: "",
    ld_bin: "",
    sdk_path: "",
    macos_ver: "",
  }
  if qbe_target != "arm64_apple" {
    return empty
  }
  if drv_env_str(world, "CC").length() > 0 {
    return empty
  }
  let mut clang_bin = ""
  let mut ld_bin = ""
  let mut sdk_path = ""

  let clt_c = "/Library/Developer/CommandLineTools/usr/bin/clang"
  let clt_l = "/Library/Developer/CommandLineTools/usr/bin/ld"
  let clt_s = "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
  if fs_exists(world, clt_c) && fs_exists(world, clt_l) && fs_exists(world, clt_s) {
    clang_bin = clt_c
    ld_bin = clt_l
    sdk_path = clt_s
  } else if fs_is_dir(world, "/Applications") {
    let apps = fs_list_dir(world, "/Applications")
    let mut i = 0
    while i < apps.length() {
      let name = apps[i]
      if drv_starts_with(name, "Xcode") && drv_ends_with(name, ".app") {
        let dev = "/Applications/" + name + "/Contents/Developer"
        let xc_c = dev + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
        let xc_l = dev + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/ld"
        let xc_s = dev + "/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
        if fs_exists(world, xc_c) && fs_exists(world, xc_l) && fs_exists(world, xc_s) {
          clang_bin = xc_c
          ld_bin = xc_l
          sdk_path = xc_s
          break
        }
      }
      i = i + 1
    }
  }
  if clang_bin == "" {
    return empty
  }
  let macos_ver = match fs_read(world, "/System/Library/CoreServices/SystemVersion.plist") {
    Ok(txt) => drv_parse_macos_ver_from_plist(txt)
    Err(_) => "15.0"
  }
  AppleTools::{
    ok: true,
    clang_bin: clang_bin,
    ld_bin: ld_bin,
    sdk_path: sdk_path,
    macos_ver: macos_ver,
  }
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
fn drv_split_lines(s : String) -> Array[String] {
  let out : Array[String] = []
  let mut cur = StringBuilder()
  let mut has_any = false
  let mut i = 0
  while i < s.length() {
    let c = str_code_at(s, i)
    if c == 10 {
      out.push(cur.to_string())
      cur = StringBuilder()
      has_any = false
    } else {
      cur.write_char(c.unsafe_to_char())
      has_any = true
    }
    i = i + 1
  }
  if has_any {
    out.push(cur.to_string())
  }
  out
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
  let _ = fs_mkdir_p(world, cache_dir + "/usig")

  let qbe_target = drv_resolve_qbe_target(world)
  let qbe_bin = drv_resolve_qbe_bin(world)
  let apple_tools = drv_probe_apple_tools(world, qbe_target)
  let direct_obj = qbe_target == "arm64_apple" &&
    emit_asm_path == "" &&
    drv_env_str(world, "M2_NO_DIRECT_OBJ") != "1"
  let qbe_macos_ver = if apple_tools.macos_ver.length() > 0 {
    apple_tools.macos_ver
  } else {
    "15.0"
  }
  let cc1as_triple = "arm64-apple-macosx" + qbe_macos_ver + ".0"
  let ld_ver = qbe_macos_ver + ".0"

  // Multi-file unit-level parallel compilation + unit-level global CAS + incremental .sig/.stub skip
  if paths.length() > 1 && emit_ssa_path == "" && emit_asm_path == "" {
    let n_units = paths.length()
    let has_usig : Array[Bool] = []
    let file_sigs : Array[String] = []
    let mut n_usig_hits = 0
    let mut ui = 0
    while ui < n_units {
      let usig_p = cache_dir + "/usig/" + src_hashes[ui] + ".sig"
      let ustub_p = cache_dir + "/usig/" + src_hashes[ui] + ".stub"
      if fs_exists(world, usig_p) && fs_exists(world, ustub_p) {
        match fs_read(world, usig_p) {
          Ok(sig_txt) => {
            has_usig.push(true)
            file_sigs.push(sig_txt)
            n_usig_hits = n_usig_hits + 1
          }
          Err(_) => {
            has_usig.push(false)
            file_sigs.push("")
          }
        }
      } else {
        has_usig.push(false)
        file_sigs.push("")
      }
      ui = ui + 1
    }

    let mut sigs_hash = ""
    let mut const_units : Array[Int] = []
    let mut has_main = false
    let mut prep_opt : Option[PreparedPackage] = None
    let parsed_dirty : Array[Option[SourceFile]] = []

    if n_usig_hits > 0 {
      let parse_diags : Array[Diagnostic] = []
      ui = 0
      while ui < n_units {
        if has_usig[ui] {
          parsed_dirty.push(None)
        } else {
          let pr = parse_source(paths[ui], sources[ui])
          let mut di = 0
          while di < pr.diagnostics.length() {
            parse_diags.push(pr.diagnostics[di])
            di = di + 1
          }
          file_sigs[ui] = emit_file_sig_entries(pr.file)
          parsed_dirty.push(Some(pr.file))
        }
        ui = ui + 1
      }
      if parse_diags.length() > 0 {
        return Err(check_result_to_json(parse_diags))
      }
      let summary = summarize_file_sigs(pkg_name, file_sigs)
      sigs_hash = summary.sigs_hash
      const_units = summary.const_units
      has_main = summary.has_main
    } else {
      let prep = match cli_prepare_qbe_units(pkg_name, paths, sources) {
        Err(diag_json) => return Err(diag_json)
        Ok(p) => p
      }
      sigs_hash = prep.sigs_hash
      const_units = prep.const_units
      has_main = prep.has_main
      prep_opt = Some(prep)
      // Populate global CAS per-file .sig and .stub for subsequent incremental builds
      ui = 0
      while ui < n_units {
        let usig_p = cache_dir + "/usig/" + src_hashes[ui] + ".sig"
        let ustub_p = cache_dir + "/usig/" + src_hashes[ui] + ".stub"
        if !fs_exists(world, usig_p) {
          let _ = drv_write_text_atomic(world, usig_p, emit_file_sig_entries(prep.pkg.files[ui]))
        }
        if !fs_exists(world, ustub_p) {
          let _ = drv_write_text_atomic(world, ustub_p, emit_file_stub(prep.pkg.files[ui]))
        }
        ui = ui + 1
      }
    }

    let unit_keys : Array[String] = []
    let obj_paths : Array[String] = []
    let miss_indices : Array[Int] = []
    let is_miss : Array[Bool] = []
    let pkg_key_sb = StringBuilder()
    pkg_key_sb.write_string(sigs_hash)
    ui = 0
    while ui < n_units {
      let ukey = cas_compute_unit_key(
        pkg_name,
        ui,
        paths[ui],
        src_hashes[ui],
        sigs_hash,
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
        is_miss.push(true)
      } else {
        is_miss.push(false)
      }
      ui = ui + 1
    }
    let pkg_key = sha256_hex(pkg_key_sb.to_string())
    let default_bin = cache_dir + "/bin/" + pkg_name + "_" + drv_prefix16(pkg_key)
    let final_bin = if out_bin_arg != "" { out_bin_arg } else { default_bin }

    if miss_indices.length() == 0 && out_bin_arg == "" && fs_exists(world, final_bin) {
      return Ok(final_bin)
    }

    if miss_indices.length() > 0 {
      let prep = match prep_opt {
        Some(p) => p
        None => {
          // Incremental selective frontend: parse full source only for missed/uncached units,
          // and lightweight `.stub` for cached unchanged units!
          let files : Array[SourceFile] = []
          let check_file : Array[Bool] = []
          let parse_diags : Array[Diagnostic] = []
          ui = 0
          while ui < n_units {
            if is_miss[ui] || !has_usig[ui] {
              match parsed_dirty[ui] {
                Some(sf) => files.push(sf)
                None => {
                  let pr = parse_source(paths[ui], sources[ui])
                  let mut di = 0
                  while di < pr.diagnostics.length() {
                    parse_diags.push(pr.diagnostics[di])
                    di = di + 1
                  }
                  files.push(pr.file)
                }
              }
              check_file.push(true)
            } else {
              let ustub_p = cache_dir + "/usig/" + src_hashes[ui] + ".stub"
              let stub_loaded = match fs_read(world, ustub_p) {
                Ok(stxt) => {
                  let spr = parse_source(paths[ui], stxt)
                  if spr.diagnostics.length() == 0 {
                    Some(spr.file)
                  } else {
                    None
                  }
                }
                Err(_) => None
              }
              match stub_loaded {
                Some(sf) => {
                  files.push(sf)
                  check_file.push(false)
                }
                None => {
                  let pr = parse_source(paths[ui], sources[ui])
                  let mut di = 0
                  while di < pr.diagnostics.length() {
                    parse_diags.push(pr.diagnostics[di])
                    di = di + 1
                  }
                  files.push(pr.file)
                  check_file.push(true)
                }
              }
            }
            ui = ui + 1
          }
          if parse_diags.length() > 0 {
            return Err(check_result_to_json(parse_diags))
          }
          let sel = match cli_prepare_qbe_units_selective(
            pkg_name,
            files,
            check_file,
            sigs_hash,
            const_units,
          ) {
            Err(diag_json) => return Err(diag_json)
            Ok(p) => p
          }
          has_main = sel.has_main
          // Save newly validated dirty units' .sig and .stub to CAS
          ui = 0
          while ui < n_units {
            if !has_usig[ui] {
              let usig_p = cache_dir + "/usig/" + src_hashes[ui] + ".sig"
              let ustub_p = cache_dir + "/usig/" + src_hashes[ui] + ".stub"
              if !fs_exists(world, usig_p) {
                let _ = drv_write_text_atomic(world, usig_p, file_sigs[ui])
              }
              if !fs_exists(world, ustub_p) {
                let _ = drv_write_text_atomic(world, ustub_p, emit_file_stub(sel.pkg.files[ui]))
              }
            }
            ui = ui + 1
          }
          sel
        }
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
    }

    // Compile missed units (qbe --obj / --obj-batch or qbe + cc1as/as) in parallel across up to `jobs` OS threads
    let n_miss = miss_indices.length()
    if n_miss == 1 || (n_miss > 1 && !direct_obj && jobs <= 1) {
      let stamp = clock_now_ms(world).to_string()
      let mut mi = 0
      while mi < n_miss {
        let idx = miss_indices[mi]
        let ukey = unit_keys[idx]
        let u_ssa = cache_dir + "/ssa/" + ukey + ".ssa"
        let u_obj = obj_paths[idx]
        let u_tmp = u_obj + ".tmp." + stamp + "_" + idx.to_string()
        if direct_obj {
          let rc_qbe = proc_exec(
            world,
            [qbe_bin, "-t", qbe_target, "--obj", "--macos-ver", qbe_macos_ver, "-o", u_tmp, u_ssa],
          )
          if rc_qbe != 0 {
            let _ = fs_remove(world, u_tmp)
            return Err("qbe failed with exit code " + rc_qbe.to_string() + " on " + u_ssa)
          }
          let _ = fs_rename(world, u_tmp, u_obj)
        } else {
          let u_asm = cache_dir + "/obj/" + ukey + ".s." + stamp + "_" + idx.to_string()
          let rc_qbe = proc_exec(world, [qbe_bin, "-t", qbe_target, "-o", u_asm, u_ssa])
          if rc_qbe != 0 {
            let _ = fs_remove(world, u_asm)
            return Err("qbe failed with exit code " + rc_qbe.to_string() + " on " + u_ssa)
          }
          let rc_as = if apple_tools.ok {
            proc_exec(
              world,
              [apple_tools.clang_bin, "-cc1as", "-triple", cc1as_triple, "-filetype", "obj", "-o", u_tmp, u_asm],
            )
          } else {
            proc_exec(world, ["as", "-o", u_tmp, u_asm])
          }
          let _ = fs_remove(world, u_asm)
          if rc_as != 0 {
            let _ = fs_remove(world, u_tmp)
            return Err("as failed with exit code " + rc_as.to_string())
          }
          let _ = fs_rename(world, u_tmp, u_obj)
        }
        mi = mi + 1
      }
    } else if n_miss > 1 && direct_obj {
      let nw = if jobs <= 1 {
        1
      } else if n_miss < jobs {
        n_miss
      } else {
        jobs
      }
      let stamp_base = clock_now_ms(world).to_string()
      if nw == 1 {
        let argv : Array[String] = [qbe_bin, "-t", qbe_target, "--obj-batch", "--macos-ver", qbe_macos_ver]
        let tmps : Array[String] = []
        let objs : Array[String] = []
        let mut mi = 0
        while mi < n_miss {
          let idx = miss_indices[mi]
          let ukey = unit_keys[idx]
          let u_ssa = cache_dir + "/ssa/" + ukey + ".ssa"
          let u_obj = obj_paths[idx]
          let u_tmp = u_obj + ".tmp." + stamp_base + "_" + idx.to_string()
          argv.push(u_ssa)
          argv.push(u_tmp)
          tmps.push(u_tmp)
          objs.push(u_obj)
          mi = mi + 1
        }
        let rc_qbe = proc_exec(world, argv)
        if rc_qbe != 0 {
          let mut j = 0
          while j < tmps.length() {
            let _ = fs_remove(world, tmps[j])
            j = j + 1
          }
          return Err("qbe --obj-batch failed with exit code " + rc_qbe.to_string())
        }
        let mut j = 0
        while j < tmps.length() {
          let _ = fs_rename(world, tmps[j], objs[j])
          j = j + 1
        }
      } else {
        let err_ch : Channel[String] = Channel::new(nw + 1)
        let qmv = qbe_macos_ver
        let qb = qbe_bin
        let qt = qbe_target
        scope(world, fn(s : Scope) -> Unit {
          let mut wi = 0
          while wi < nw {
            let start = wi * n_miss / nw
            let end = (wi + 1) * n_miss / nw
            let spec_sb = StringBuilder()
            let mut k = start
            while k < end {
              let idx = miss_indices[k]
              let ukey = unit_keys[idx]
              let u_ssa = cache_dir + "/ssa/" + ukey + ".ssa"
              let u_obj = obj_paths[idx]
              let u_tmp = u_obj + ".tmp." + stamp_base + "_" + idx.to_string()
              spec_sb.write_string(u_ssa)
              spec_sb.write_char('\n')
              spec_sb.write_string(u_tmp)
              spec_sb.write_char('\n')
              spec_sb.write_string(u_obj)
              spec_sb.write_char('\n')
              k = k + 1
            }
            let spec = spec_sb.to_string()
            spawn(s, fn() -> Unit {
              let lines = drv_split_lines(spec)
              let argv : Array[String] = [qb, "-t", qt, "--obj-batch", "--macos-ver", qmv]
              let tmps : Array[String] = []
              let objs : Array[String] = []
              let mut li = 0
              while li + 2 < lines.length() {
                argv.push(lines[li])
                argv.push(lines[li + 1])
                tmps.push(lines[li + 1])
                objs.push(lines[li + 2])
                li = li + 3
              }
              let rc_qbe = proc_exec(argv)
              if rc_qbe != 0 {
                let mut j = 0
                while j < tmps.length() {
                  let _ = fs_remove(tmps[j])
                  j = j + 1
                }
                let _ = err_ch.send("qbe --obj-batch failed with exit code " + rc_qbe.to_string())
              } else {
                let mut j = 0
                while j < tmps.length() {
                  let _ = fs_rename(tmps[j], objs[j])
                  j = j + 1
                }
              }
            })
            wi = wi + 1
          }
        })
        err_ch.close()
        match err_ch.recv() {
          Some(err_msg) => return Err(err_msg)
          None => ()
        }
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
        let use_direct = direct_obj
        let qmv = qbe_macos_ver
        let use_cc1as = apple_tools.ok
        let cc1as_bin = apple_tools.clang_bin
        let cc1as_tr = cc1as_triple
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
              if use_direct {
                let rc_qbe = proc_exec([qb, "-t", qt, "--obj", "--macos-ver", qmv, "-o", u_tmp, u_ssa])
                if rc_qbe != 0 {
                  let _ = fs_remove(u_tmp)
                  let _ = err_ch.send("qbe failed with exit code " + rc_qbe.to_string() + " on " + u_ssa)
                } else {
                  let _ = fs_rename(u_tmp, u_obj)
                }
              } else {
                let rc_qbe = proc_exec([qb, "-t", qt, "-o", u_asm, u_ssa])
                if rc_qbe != 0 {
                  let _ = fs_remove(u_asm)
                  let _ = err_ch.send("qbe failed with exit code " + rc_qbe.to_string() + " on " + u_ssa)
                } else {
                  let rc_as = if use_cc1as {
                    proc_exec([cc1as_bin, "-cc1as", "-triple", cc1as_tr, "-filetype", "obj", "-o", u_tmp, u_asm])
                  } else {
                    proc_exec(["as", "-o", u_tmp, u_asm])
                  }
                  let _ = fs_remove(u_asm)
                  if rc_as != 0 {
                    let _ = fs_remove(u_tmp)
                    let _ = err_ch.send("as failed with exit code " + rc_as.to_string() + " on " + u_asm)
                  } else {
                    let _ = fs_rename(u_tmp, u_obj)
                  }
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

    if !has_main && out_bin_arg == "" {
      return Ok(obj_paths[0])
    }

    if out_bin_arg != "" {
      drv_ensure_parent_dir(world, out_bin_arg)
    }
    let rt_lib = drv_resolve_rt_lib(world)
    let rc_ld = if apple_tools.ok {
      let ld_argv : Array[String] = [
        apple_tools.ld_bin,
        "-arch",
        "arm64",
        "-platform_version",
        "macos",
        ld_ver,
        ld_ver,
        "-syslibroot",
        apple_tools.sdk_path,
        "-o",
        final_bin,
      ]
      let mut oi = 0
      while oi < obj_paths.length() {
        ld_argv.push(obj_paths[oi])
        oi = oi + 1
      }
      ld_argv.push(rt_lib)
      ld_argv.push("-lSystem")
      proc_exec(world, ld_argv)
    } else {
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
      proc_exec(world, ld_argv)
    }
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
    let obj_tmp = obj_path + ".tmp." + stamp
    if direct_obj {
      let rc_qbe = proc_exec(
        world,
        [qbe_bin, "-t", qbe_target, "--obj", "--macos-ver", qbe_macos_ver, "-o", obj_tmp, ssa_path],
      )
      if rc_qbe != 0 {
        let _ = fs_remove(world, obj_tmp)
        return Err(
          "qbe failed with exit code " + rc_qbe.to_string() + " on " + ssa_path,
        )
      }
      let _ = fs_rename(world, obj_tmp, obj_path)
    } else {
      let asm_path = cache_dir + "/obj/" + key + ".s." + stamp
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
      let rc_as = if apple_tools.ok {
        proc_exec(
          world,
          [apple_tools.clang_bin, "-cc1as", "-triple", cc1as_triple, "-filetype", "obj", "-o", obj_tmp, asm_path],
        )
      } else {
        proc_exec(world, ["as", "-o", obj_tmp, asm_path])
      }
      let _ = fs_remove(world, asm_path)
      if rc_as != 0 {
        let _ = fs_remove(world, obj_tmp)
        return Err("as failed with exit code " + rc_as.to_string())
      }
      let _ = fs_rename(world, obj_tmp, obj_path)
    }

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
  let rc_ld = if apple_tools.ok {
    proc_exec(
      world,
      [
        apple_tools.ld_bin,
        "-arch",
        "arm64",
        "-platform_version",
        "macos",
        ld_ver,
        ld_ver,
        "-syslibroot",
        apple_tools.sdk_path,
        "-o",
        final_bin,
        obj_path,
        rt_lib,
        "-lSystem",
      ],
    )
  } else {
    let cc = {
      let e = drv_env_str(world, "CC")
      if e.length() > 0 {
        e
      } else {
        "clang"
      }
    }
    proc_exec(
      world,
      [cc, obj_path, rt_lib, "-lpthread", "-o", final_bin],
    )
  }
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
    let mut jobs = 16
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
        jobs = drv_parse_pos_int(args[i + 1], 16)
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
