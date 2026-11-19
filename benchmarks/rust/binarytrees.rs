enum Tree {
    Leaf,
    Node(Box<Tree>, Box<Tree>),
}

fn make_tree(depth: i32) -> Tree {
    if depth > 0 {
        Tree::Node(Box::new(make_tree(depth - 1)), Box::new(make_tree(depth - 1)))
    } else {
        Tree::Leaf
    }
}

fn check_tree(t: &Tree) -> i32 {
    match t {
        Tree::Leaf => 1,
        Tree::Node(l, r) => 1 + check_tree(l) + check_tree(r),
    }
}

fn main() {
    let mut max_depth: i32 = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(16);
    let min_depth = 4;
    if min_depth + 2 > max_depth {
        max_depth = min_depth + 2;
    }

    let stretch = make_tree(max_depth + 1);
    let stretch_check = check_tree(&stretch);
    drop(stretch);

    let long_lived = make_tree(max_depth);

    let mut total_check: i64 = 0;
    let mut depth = min_depth;
    while depth <= max_depth {
        let iterations = 1 << (max_depth - depth + min_depth);
        let mut check = 0;
        for _ in 0..iterations {
            let t = make_tree(depth);
            check += check_tree(&t);
        }
        total_check += check as i64;
        depth += 2;
    }

    let long_check = check_tree(&long_lived);
    println!("stretch={} long={} total={}", stretch_check, long_check, total_check);
}
