pub val struct Msg {
  id : Int
  body : String
}

pub fn main(w : World) -> Int {
  let total = 2000
  let ch : Channel[Msg] = Channel::new(64)
  let recv_count = AtomicInt::new(0)
  let recv_sum = AtomicInt::new(0)
  let recv_len_sum = AtomicInt::new(0)

  scope(w, fn(s : Scope) -> Unit {
    spawn(s, fn() -> Unit {
      let mut i = 0
      while i < total {
        let m = Msg::{ id: i, body: "msg-" + i.to_string() }
        let _ = ch.send(m)
        i = i + 1
      }
      ch.close()
    })
    let mut wi = 0
    while wi < 4 {
      spawn(s, fn() -> Unit {
        while true {
          match ch.recv() {
            Some(m) => {
              let _ = recv_count.fetch_add(1)
              let _ = recv_sum.fetch_add(m.id)
              let _ = recv_len_sum.fetch_add(m.body.length())
            }
            None => break
          }
        }
      })
      wi = wi + 1
    }
  })

  let c = recv_count.load()
  let sm = recv_sum.load()
  let ls = recv_len_sum.load()
  let expected_sum = (total * (total - 1)) / 2
  if c == total && sm == expected_sum && ls > total * 4 {
    io_println(w, "deep_freeze_ok:" + c.to_string() + ":" + sm.to_string() + ":" + ls.to_string())
    0
  } else {
    io_eprintln(w, "deep_freeze_fail:" + c.to_string() + ":" + sm.to_string() + ":" + ls.to_string())
    1
  }
}
