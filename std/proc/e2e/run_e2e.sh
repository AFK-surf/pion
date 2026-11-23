#!/bin/sh
set -eu

# std/proc E2E + ASan/LSan + fd-leak conservation regression.
PIONC="${1:-}"
if [ -z "$PIONC" ] || [ ! -x "$PIONC" ]; then
  echo "usage: $0 <path-to-pionc>" >&2
  exit 1
fi

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CC_BIN="${CC:-cc}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

APP_DIR="$TMP_DIR/proc_e2e_app"
mkdir -p "$APP_DIR/src"

cat > "$APP_DIR/pion.toml" <<EOF
[package]
name = "proc_e2e_app"
version = "0.1.0"

[dependencies]
proc = { path = "$ROOT_DIR/std/proc" }
EOF

cat > "$APP_DIR/src/main.pion" <<'EOF'
import "proc"

fn count_open_fds(w : World) -> Int {
  let linux_fds = fs_list_dir(w, "/proc/self/fd")
  if linux_fds.length() > 0 {
    return linux_fds.length()
  }
  let mac_fds = fs_list_dir(w, "/dev/fd")
  mac_fds.length()
}

fn drain_out(w : World, c : proc::Child) -> String {
  let sb = StringBuilder()
  while true {
    match proc::child_read_stdout(w, c, 4096) {
      Ok(proc::ReadChunk::Data(b)) => sb.write_string(b.to_string())
      Ok(proc::ReadChunk::Eof) => break
      Ok(proc::ReadChunk::Timeout) => ()
      Err(e) => panic("child_read_stdout: " + e)
    }
  }
  sb.to_string()
}

fn drain_pty(w : World, p : proc::PtyChild) -> String {
  let sb = StringBuilder()
  while true {
    match proc::pty_read(w, p, 4096) {
      Ok(proc::ReadChunk::Data(b)) => sb.write_string(b.to_string())
      Ok(proc::ReadChunk::Eof) => break
      Ok(proc::ReadChunk::Timeout) => ()
      Err(e) => panic("pty_read: " + e)
    }
  }
  sb.to_string()
}

fn run_cycle(w : World, iter : Int) -> Unit {
  // 1. Streaming Child with stdin + stdout + stderr + Channel worker
  let c = match proc::child_spawn(w, ["/bin/sh", "-c", "cat; printf 'err_%d\n' 1 >&2"], proc::spawn_options()) {
    Ok(ch) => ch
    Err(e) => panic("spawn failed: " + e)
  }
  let msg = "iter_" + iter.to_string() + "\n"
  match proc::child_write_stdin_str(w, c, msg) {
    Ok(_) => ()
    Err(e) => panic("write_stdin: " + e)
  }
  proc::child_close_stdin(w, c)
  let ch : Channel[String] = Channel::new(8)
  scope(w, fn(sc : Scope) -> Unit {
    spawn(sc, fn() -> Unit {
      let child = move c
      let out = drain_out(w, child)
      let mut err_seen = false
      while true {
        match proc::child_read_stderr(w, child, 1024) {
          Ok(proc::ReadChunk::Data(b)) =>
            if b.to_string().contains("err_1") {
              err_seen = true
            }
          Ok(proc::ReadChunk::Eof) => break
          Ok(proc::ReadChunk::Timeout) => ()
          Err(e) => panic("read_stderr: " + e)
        }
      }
      if !err_seen {
        panic("missing stderr")
      }
      let _ = proc::child_wait(w, child)
      proc::child_close(w, child)
      proc::child_close(w, child)
      let _ = ch.send(out)
      ch.close()
    })
    match ch.recv() {
      Some(s) =>
        if !s.contains("iter_" + iter.to_string()) {
          panic("stream mismatch: " + s)
        }
      None => panic("missing streamed output")
    }
  })

  // 2. Child tree kill (grandchild cleanup)
  let ct = match proc::child_spawn(w, ["/bin/sh", "-c", "sleep 30 & echo rdy; wait"], proc::spawn_options()) {
    Ok(x) => x
    Err(e) => panic("spawn tree: " + e)
  }
  let mut rdy = false
  let mut tries = 0
  while !rdy && tries < 40 {
    match proc::child_read_stdout_timeout(w, ct, 1024, 100) {
      Ok(proc::ReadChunk::Data(b)) =>
        if b.to_string().contains("rdy") {
          rdy = true
        }
      Ok(proc::ReadChunk::Timeout) => ()
      _ => break
    }
    tries = tries + 1
  }
  if !rdy {
    panic("tree did not become ready")
  }
  let _ = proc::child_kill_tree(w, ct)
  match proc::child_wait(w, ct) {
    Ok(proc::ExitStatus::Signaled(9)) => ()
    _ => panic("expected Signaled(9)")
  }
  proc::child_close(w, ct)

  // 3. PTY spawn + resize + write + clean EOF
  let p = match proc::pty_spawn(w, ["/bin/sh", "-c", "stty size; read ln; echo P:$ln; stty size"], 88, 26, proc::spawn_options()) {
    Ok(x) => x
    Err(e) => panic("pty_spawn: " + e)
  }
  let psb = StringBuilder()
  let mut pinit = false
  let mut ptries = 0
  while !pinit && ptries < 40 {
    match proc::pty_read_timeout(w, p, 4096, 100) {
      Ok(proc::ReadChunk::Data(b)) => {
        psb.write_string(b.to_string())
        if psb.to_string().contains("26 88") {
          pinit = true
        }
      }
      Ok(proc::ReadChunk::Timeout) => ()
      _ => break
    }
    ptries = ptries + 1
  }
  if !pinit {
    panic("pty init size missing: " + psb.to_string())
  }
  match proc::pty_resize(w, p, 110, 35) {
    Ok(_) => ()
    Err(e) => panic("pty_resize: " + e)
  }
  match proc::pty_write_str(w, p, "hi\n") {
    Ok(_) => ()
    Err(e) => panic("pty_write_str: " + e)
  }
  psb.write_string(drain_pty(w, p))
  let pout = psb.to_string()
  if !pout.contains("P:hi") || !pout.contains("35 110") {
    panic("pty output mismatch: " + pout)
  }
  let _ = proc::pty_wait(w, p)
  proc::pty_close(w, p)
  proc::pty_close(w, p)
}

pub fn main(world : World) -> Int {
  // Warm up one cycle so any one-time OS/thread state is initialized
  run_cycle(world, 0)
  let fd_before = count_open_fds(world)
  let mut i = 1
  while i <= 6 {
    run_cycle(world, i)
    i = i + 1
  }
  let fd_after = count_open_fds(world)
  if fd_before > 0 && fd_after != fd_before {
    panic("fd leak detected: before=" + fd_before.to_string() + " after=" + fd_after.to_string())
  }
  io_println(world, "std_proc_e2e ok fds=" + fd_before.to_string() + "->" + fd_after.to_string())
  0
}
EOF

echo "=== std/proc E2E: Native Release ==="
"$PIONC" build --release -o "$TMP_DIR/proc_e2e_rel" "$APP_DIR"
REL_OUT=$("$TMP_DIR/proc_e2e_rel")
echo "std/proc native release -> $REL_OUT"
echo "$REL_OUT" | grep -q "^std_proc_e2e ok "

echo "=== std/proc E2E: ASan/LSan (0 leak / 0 UAF / fd conservation) ==="
if "$CC_BIN" -fsanitize=address -x c - -o "$TMP_DIR/asan_probe" >/dev/null 2>&1 <<'CEOF'
int main(void) { return 0; }
CEOF
then
  "$CC_BIN" -std=c11 -O1 -g -fsanitize=address -fno-omit-frame-pointer -Wall -Wextra -Werror \
    -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o"
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  cat > "$TMP_DIR/asan-cc" <<CEOF
#!/bin/sh
exec "$CC_BIN" -fsanitize=address -fno-omit-frame-pointer "\$@"
CEOF
  chmod +x "$TMP_DIR/asan-cc"
  CC="$TMP_DIR/asan-cc" PION_RT_LIB="$TMP_DIR/libpionrt_asan.a" PION_CACHE_DIR="$TMP_DIR/cas_asan" \
    "$PIONC" build --release -o "$TMP_DIR/proc_e2e_asan" "$APP_DIR"
  ASAN_OPTS="halt_on_error=1"
  if [ "$(uname -s)" = "Linux" ]; then
    ASAN_OPTS="detect_leaks=1:halt_on_error=1"
  fi
  ASAN_OUT=$(ASAN_OPTIONS="$ASAN_OPTS" "$TMP_DIR/proc_e2e_asan")
  echo "std/proc ASan/LSan -> $ASAN_OUT"
  echo "$ASAN_OUT" | grep -q "^std_proc_e2e ok "
else
  echo "NOTE: ASan unavailable on this toolchain; skipping ASan/LSan step"
fi

echo "PASS: std/proc E2E (Child + PtyChild + kill_tree + MT Channel + ASan/LSan + fd conservation)"
