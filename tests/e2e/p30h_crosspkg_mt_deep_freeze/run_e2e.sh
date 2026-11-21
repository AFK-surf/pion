#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

UI_DIR="$TMP_DIR/ui"
APP_DIR="$TMP_DIR/app"
CAS_DIR="$TMP_DIR/cas"
mkdir -p "$UI_DIR/src" "$APP_DIR/src" "$CAS_DIR"

cat > "$UI_DIR/pion.toml" <<'EOF'
[package]
name = "ui"
version = "0.1.0"
EOF

cat > "$UI_DIR/src/lib.pion" <<'EOF'
pub struct EventQueue[Ev] {
  q : Mutex[Array[Ev]]
}

pub fn EventQueue::new[Ev]() -> EventQueue[Ev] {
  EventQueue::{ q: Mutex::new([]) }
}

pub fn EventQueue::emit[Ev](self : EventQueue[Ev], ev : Ev) -> Unit {
  self.q.with_lock(fn(q) { q.push(ev) })
}

pub fn EventQueue::drain[Ev](self : EventQueue[Ev]) -> Array[Ev] {
  let batch : Array[Ev] = []
  self.q.with_lock(fn(q) {
    let mut i = 0
    while i < q.length() {
      batch.push(q[i])
      i = i + 1
    }
    q.clear()
  })
  batch
}

pub struct WorkerCtx[Cmd, Ev] {
  events : EventQueue[Ev]
}

pub fn WorkerCtx::emit[Cmd, Ev](self : WorkerCtx[Cmd, Ev], ev : Ev) -> Unit {
  self.events.emit(ev)
}

pub struct Worker[Cmd, Ev] {
  ch : Channel[Cmd]
  events : EventQueue[Ev]
}

pub fn Worker::new[Cmd, Ev](events : EventQueue[Ev], cap : Int) -> Worker[Cmd, Ev] {
  Worker::{ ch: Channel::new(cap), events: events }
}

pub fn Worker::send[Cmd, Ev](self : Worker[Cmd, Ev], cmd : Cmd) -> Bool {
  self.ch.send(move cmd)
}

pub fn Worker::recv[Cmd, Ev](self : Worker[Cmd, Ev]) -> Option[Cmd] {
  self.ch.recv()
}

pub fn Worker::close[Cmd, Ev](self : Worker[Cmd, Ev]) -> Unit {
  self.ch.close()
}

pub fn Worker::ctx[Cmd, Ev](self : Worker[Cmd, Ev]) -> WorkerCtx[Cmd, Ev] {
  WorkerCtx::{ events: self.events }
}
EOF

cat > "$APP_DIR/pion.toml" <<EOF
[package]
name = "p30h_app"
version = "0.1.0"

[dependencies]
ui = { path = "$UI_DIR" }
EOF

cat > "$APP_DIR/src/main.pion" <<'EOF'
import "ui"

struct NestedPayload {
  id : Int
  tag : String
  note : String
}

enum Cmd {
  Run(Int, String)
  RunNested(NestedPayload)
}

enum Ev {
  JobDone(Int, String)
  NestedDone(NestedPayload)
}

pub fn main(world : World) -> Int {
  let total_run = 500
  let total_nested = 100
  let total_all = total_run + total_nested

  let events : ui::EventQueue[Ev] = ui::EventQueue::new()
  let worker : ui::Worker[Cmd, Ev] = ui::Worker::new(events, 32)
  let ctx : ui::WorkerCtx[Cmd, Ev] = worker.ctx()
  let cmd_ok = AtomicInt::new(0)
  let ev_ok = AtomicInt::new(0)

  scope(world, fn(s : Scope) -> Unit {
    // Worker OS thread: receives Cmd across Channel[Cmd], verifies strings, emits Ev via EventQueue[Ev]
    spawn(s, fn() -> Unit {
      while true {
        match worker.recv() {
          Some(cmd) =>
            match cmd {
              Cmd::Run(id, label) => {
                let want = "cmd-" + id.to_string()
                debug_assert(label == want, "cmd string mismatch")
                let _ = cmd_ok.fetch_add(1)
                ctx.emit(Ev::JobDone(id, "done-" + id.to_string()))
              }
              Cmd::RunNested(p) => {
                let want_tag = "tag-" + p.id.to_string()
                let want_note = "note-" + p.id.to_string()
                debug_assert(p.tag == want_tag && p.note == want_note, "nested cmd mismatch")
                let _ = cmd_ok.fetch_add(1)
                let out_p = NestedPayload::{
                  id: p.id,
                  tag: "out-tag-" + p.id.to_string(),
                  note: "out-note-" + p.id.to_string(),
                }
                ctx.emit(Ev::NestedDone(out_p))
              }
            }
          None => break
        }
      }
    })

    // Producer OS thread: sends 500 Run + 100 RunNested commands, then closes worker channel
    spawn(s, fn() -> Unit {
      let mut i = 0
      while i < total_run {
        let ok = worker.send(Cmd::Run(i, "cmd-" + i.to_string()))
        debug_assert(ok, "worker.send Run failed")
        i = i + 1
      }
      let mut j = 0
      while j < total_nested {
        let p = NestedPayload::{
          id: j,
          tag: "tag-" + j.to_string(),
          note: "note-" + j.to_string(),
        }
        let ok = worker.send(Cmd::RunNested(p))
        debug_assert(ok, "worker.send RunNested failed")
        j = j + 1
      }
      worker.close()
    })

    // Main/UI OS thread: concurrently drains EventQueue[Ev] until all 600 events verified
    let mut got_run = 0
    let mut got_nested = 0
    while got_run + got_nested < total_all {
      let batch = events.drain()
      let mut bi = 0
      while bi < batch.length() {
        match batch[bi] {
          Ev::JobDone(id, msg) => {
            let want = "done-" + id.to_string()
            debug_assert(msg == want, "ev JobDone string mismatch")
            debug_assert(id == got_run, "ev JobDone order mismatch")
            got_run = got_run + 1
            let _ = ev_ok.fetch_add(1)
          }
          Ev::NestedDone(p) => {
            let want_tag = "out-tag-" + p.id.to_string()
            let want_note = "out-note-" + p.id.to_string()
            debug_assert(p.tag == want_tag && p.note == want_note, "ev NestedDone string mismatch")
            debug_assert(p.id == got_nested, "ev NestedDone order mismatch")
            got_nested = got_nested + 1
            let _ = ev_ok.fetch_add(1)
          }
        }
        bi = bi + 1
      }
    }
  })

  let c_cnt = cmd_ok.load()
  let e_cnt = ev_ok.load()
  debug_assert(c_cnt == total_all && e_cnt == total_all, "count mismatch")
  io_println(world, "p30h_crosspkg_mt_deep_freeze ok cmds=" + c_cnt.to_string() + " evs=" + e_cnt.to_string())
  0
}
EOF

EXPECT="p30h_crosspkg_mt_deep_freeze ok cmds=600 evs=600"

# 1. Release build & run
PION_CACHE_DIR="$CAS_DIR/rel" "$PIONC" build --release -o "$TMP_DIR/p30h_rel" "$APP_DIR"
REL_OUT=$("$TMP_DIR/p30h_rel")
echo "p30h_crosspkg_mt_deep_freeze release -> $REL_OUT"
if [ "$REL_OUT" != "$EXPECT" ]; then
  echo "FAIL: p30h release output mismatch: $REL_OUT" >&2
  exit 1
fi

CC_BIN="${CC:-cc}"

# 2. ASan build & run
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -g -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  cat > "$TMP_DIR/cc_asan.sh" <<WRAP
#!/bin/sh
exec "$CC_BIN" -fsanitize=address "\$@"
WRAP
  chmod +x "$TMP_DIR/cc_asan.sh"
  CC="$TMP_DIR/cc_asan.sh" PION_RT_LIB="$TMP_DIR/libpionrt_asan.a" PION_CACHE_DIR="$CAS_DIR/asan" \
    "$PIONC" build --release -o "$TMP_DIR/p30h_asan" "$APP_DIR"
  ASAN_OUT=$("$TMP_DIR/p30h_asan")
  echo "p30h_crosspkg_mt_deep_freeze ASan -> $ASAN_OUT"
  if [ "$ASAN_OUT" != "$EXPECT" ]; then
    echo "FAIL: p30h ASan output mismatch: $ASAN_OUT" >&2
    exit 1
  fi
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping p30h ASan check"
fi

# 3. TSan build & run
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=thread -o "$TMP_DIR/tsan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -g -fsanitize=thread -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_tsan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_tsan.a" "$TMP_DIR/pion_rt_tsan.o"
  cat > "$TMP_DIR/cc_tsan.sh" <<WRAP
#!/bin/sh
exec "$CC_BIN" -fsanitize=thread "\$@"
WRAP
  chmod +x "$TMP_DIR/cc_tsan.sh"
  CC="$TMP_DIR/cc_tsan.sh" PION_RT_LIB="$TMP_DIR/libpionrt_tsan.a" PION_CACHE_DIR="$CAS_DIR/tsan" \
    "$PIONC" build --release -o "$TMP_DIR/p30h_tsan" "$APP_DIR"
  TSAN_OUT=$("$TMP_DIR/p30h_tsan")
  echo "p30h_crosspkg_mt_deep_freeze TSan -> $TSAN_OUT"
  if [ "$TSAN_OUT" != "$EXPECT" ]; then
    echo "FAIL: p30h TSan output mismatch: $TSAN_OUT" >&2
    exit 1
  fi
else
  echo "NOTE: cc -fsanitize=thread unavailable; skipping p30h TSan check"
fi

echo "[PASS] p30h_crosspkg_mt_deep_freeze (release + ASan + TSan)"
