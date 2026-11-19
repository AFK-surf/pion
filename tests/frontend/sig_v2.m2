// Different comments, different private helpers, different body
pub val struct Config {
  port : Int
}

fn priv_b(x : Int, y : Int) -> Int {
  x * y
}

pub fn make_port(c : Config) -> Int {
  let doubled = priv_b(c.port, 2)
  doubled - c.port
}
