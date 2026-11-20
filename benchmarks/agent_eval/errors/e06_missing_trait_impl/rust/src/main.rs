trait Describe {
    fn describe(&self) -> String;
}

#[allow(dead_code)]
struct Point {
    x: i64,
    y: i64,
}

impl Describe for i64 {
    fn describe(&self) -> String {
        format!("int {}", self)
    }
}

fn show_all<T: Describe>(x: T) -> String {
    x.describe()
}

fn main() {
    println!("{}", show_all(1i64));
    println!("{}", show_all(Point { x: 1, y: 2 }));
}
