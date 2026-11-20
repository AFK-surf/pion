trait Area {
    fn area(&self) -> i64;
}

struct Sq {
    side: i64,
}

impl Area for Sq {
    fn area(&self) -> String {
        (self.side * self.side).to_string()
    }
}

fn total<T: Area>(x: T) -> i64 {
    x.area()
}

fn main() {
    println!("{}", total(Sq { side: 3 }));
}
