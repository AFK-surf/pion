enum Color {
    Red,
    Green,
    Blue,
}

fn hex(c: Color) -> &'static str {
    match c {
        Color::Red => "#f00",
        Color::Green => "#0f0",
    }
}

fn main() {
    println!("{}", hex(Color::Blue));
}
