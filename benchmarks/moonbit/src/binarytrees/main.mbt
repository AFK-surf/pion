enum Tree {
  Leaf
  Node(Tree, Tree)
}

fn make_tree(depth : Int) -> Tree {
  if depth > 0 {
    Node(make_tree(depth - 1), make_tree(depth - 1))
  } else {
    Leaf
  }
}

fn check_tree(t : Tree) -> Int {
  match t {
    Leaf => 1
    Node(l, r) => 1 + check_tree(l) + check_tree(r)
  }
}

fn main {
  let max_depth = 16
  let min_depth = 4
  let stretch = make_tree(max_depth + 1)
  let stretch_check = check_tree(stretch)
  let long_lived = make_tree(max_depth)
  let mut total_check : Int64 = 0L
  let mut depth = min_depth
  while depth <= max_depth {
    let iterations = 1 << (max_depth - depth + min_depth)
    let mut check = 0
    for i = 0; i < iterations; i = i + 1 {
      let t = make_tree(depth)
      check = check + check_tree(t)
    }
    total_check = total_check + check.to_int64()
    depth = depth + 2
  }
  let long_check = check_tree(long_lived)
  println(
    "stretch=" +
    stretch_check.to_string() +
    " long=" +
    long_check.to_string() +
    " total=" +
    total_check.to_string(),
  )
}
