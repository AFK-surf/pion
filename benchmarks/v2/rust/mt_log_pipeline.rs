// V2 Benchmark 3: mt_log_pipeline (Rust, std::thread + bounded MPMC channel)
// Usage: mt_log_pipeline <logs.txt> [1|4]
use std::collections::{HashMap, VecDeque};
use std::env;
use std::fs;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;

struct BoundedChan<T> {
    cap: usize,
    state: Mutex<(VecDeque<T>, bool)>,
    not_empty: Condvar,
    not_full: Condvar,
}

impl<T> BoundedChan<T> {
    fn new(cap: usize) -> Self {
        Self {
            cap,
            state: Mutex::new((VecDeque::with_capacity(cap), false)),
            not_empty: Condvar::new(),
            not_full: Condvar::new(),
        }
    }

    fn send(&self, v: T) -> bool {
        let mut g = self.state.lock().unwrap();
        while g.0.len() == self.cap && !g.1 {
            g = self.not_full.wait(g).unwrap();
        }
        if g.1 {
            return false;
        }
        g.0.push_back(v);
        self.not_empty.notify_one();
        true
    }

    fn recv(&self) -> Option<T> {
        let mut g = self.state.lock().unwrap();
        while g.0.is_empty() && !g.1 {
            g = self.not_empty.wait(g).unwrap();
        }
        if let Some(v) = g.0.pop_front() {
            self.not_full.notify_one();
            Some(v)
        } else {
            None
        }
    }

    fn close(&self) {
        let mut g = self.state.lock().unwrap();
        g.1 = true;
        self.not_empty.notify_all();
        self.not_full.notify_all();
    }
}

struct WorkerStats {
    lines: i32,
    errs: i32,
    slow: i32,
    sum_lat: i64,
    svc_sum: i64,
    msg_xor: i32,
}

fn poly_hash(s: &[u8]) -> i32 {
    let mut h: u32 = 0;
    for &b in s {
        h = (h.wrapping_mul(31).wrapping_add(b as u32)) & 0x3fffffff;
    }
    h as i32
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: {} <logs.txt> [1|4]", args[0]);
        std::process::exit(2);
    }
    let nworkers: usize = args
        .get(2)
        .and_then(|s| s.parse().ok())
        .unwrap_or(1)
        .clamp(1, 16);

    let src = fs::read_to_string(&args[1]).expect("read logs.txt");

    let work_ch = Arc::new(BoundedChan::<String>::new(64));
    let alert_ch = Arc::new(BoundedChan::<String>::new(256));
    let active = Arc::new(AtomicI32::new(nworkers as i32));

    let prod_ch = Arc::clone(&work_ch);
    let prod_handle = thread::spawn(move || {
        let b = src.as_bytes();
        let n = b.len();
        let mut pos = 0;
        while pos < n {
            let start = pos;
            let mut nl = 0;
            while pos < n && nl < 10 {
                if b[pos] == b'\n' {
                    nl += 1;
                }
                pos += 1;
            }
            let chunk = src[start..pos].to_string();
            prod_ch.send(chunk);
        }
        prod_ch.close();
    });

    let mut worker_handles = Vec::with_capacity(nworkers);
    for _ in 0..nworkers {
        let w_in = Arc::clone(&work_ch);
        let w_out = Arc::clone(&alert_ch);
        let w_act = Arc::clone(&active);
        worker_handles.push(thread::spawn(move || {
            let mut svc_lat: HashMap<String, i64> = HashMap::new();
            let mut lines: i32 = 0;
            let mut errs: i32 = 0;
            let mut slow: i32 = 0;
            let mut sum_lat: i64 = 0;
            let mut msg_xor: i32 = 0;

            while let Some(chunk) = w_in.recv() {
                let s = chunk.as_bytes();
                let n = s.len();
                let mut i = 0;
                while i < n {
                    let line_start = i;
                    while i < n && s[i] != b'\n' {
                        i += 1;
                    }
                    let line_end = i;
                    if i < n && s[i] == b'\n' {
                        i += 1;
                    }
                    if line_end <= line_start {
                        continue;
                    }
                    lines += 1;
                    let mut p = line_start;
                    while p < line_end && s[p] != b' ' {
                        p += 1;
                    }
                    if p < line_end {
                        p += 1;
                    }
                    p += 6; // level=
                    let lvl_s = p;
                    while p < line_end && s[p] != b' ' {
                        p += 1;
                    }
                    let lvl_e = p;
                    if p < line_end {
                        p += 1;
                    }
                    p += 4; // svc=
                    let svc_s = p;
                    while p < line_end && s[p] != b' ' {
                        p += 1;
                    }
                    let svc_e = p;
                    if p < line_end {
                        p += 1;
                    }
                    p += 4; // lat=
                    let mut lat: i32 = 0;
                    while p < line_end && s[p] != b' ' {
                        lat = lat * 10 + (s[p] - b'0') as i32;
                        p += 1;
                    }
                    if p < line_end {
                        p += 1;
                    }
                    p += 4; // msg=
                    let msg_s = p;

                    let lat64 = lat as i64;
                    sum_lat += lat64;
                    let svc_str = &chunk[svc_s..svc_e];
                    if let Some(v) = svc_lat.get_mut(svc_str) {
                        *v += lat64;
                    } else {
                        svc_lat.insert(svc_str.to_string(), lat64);
                    }
                    msg_xor ^= poly_hash(&s[msg_s..line_end]);

                    let is_err = (lvl_e - lvl_s == 3)
                        && s[lvl_s] == b'E'
                        && s[lvl_s + 1] == b'R'
                        && s[lvl_s + 2] == b'R';
                    let is_slow = lat >= 500;
                    if is_err {
                        errs += 1;
                    }
                    if is_slow {
                        slow += 1;
                    }
                    if is_err || is_slow {
                        let lvl_str = &chunk[lvl_s..lvl_e];
                        let msg_str = &chunk[msg_s..line_end];
                        let mut alert = String::with_capacity(
                            6 + svc_str.len() + 1 + lvl_str.len() + 12 + msg_str.len(),
                        );
                        alert.push_str("ALERT|");
                        alert.push_str(svc_str);
                        alert.push('|');
                        alert.push_str(lvl_str);
                        alert.push('|');
                        alert.push_str(&lat.to_string());
                        alert.push('|');
                        alert.push_str(msg_str);
                        w_out.send(alert);
                    }
                }
            }

            let svc_sum: i64 = svc_lat.values().sum();
            if w_act.fetch_sub(1, Ordering::AcqRel) == 1 {
                w_out.close();
            }
            WorkerStats {
                lines,
                errs,
                slow,
                sum_lat,
                svc_sum,
                msg_xor,
            }
        }));
    }

    let mut alert_cnt: i32 = 0;
    let mut alert_len_sum: i64 = 0;
    let mut alert_xor: i32 = 0;
    while let Some(alert) = alert_ch.recv() {
        alert_cnt += 1;
        alert_len_sum += alert.len() as i64;
        alert_xor ^= poly_hash(alert.as_bytes());
    }

    prod_handle.join().unwrap();
    let mut lines: i32 = 0;
    let mut errs: i32 = 0;
    let mut slow: i32 = 0;
    let mut sum_lat: i64 = 0;
    let mut svc_sum: i64 = 0;
    let mut msg_xor: i32 = 0;
    for h in worker_handles {
        let st = h.join().unwrap();
        lines += st.lines;
        errs += st.errs;
        slow += st.slow;
        sum_lat += st.sum_lat;
        svc_sum += st.svc_sum;
        msg_xor ^= st.msg_xor;
    }
    assert_eq!(svc_sum, sum_lat);

    println!(
        "{} {} {} {} {} {} {} {}",
        lines, errs, slow, sum_lat, msg_xor, alert_cnt, alert_len_sum, alert_xor
    );
}
