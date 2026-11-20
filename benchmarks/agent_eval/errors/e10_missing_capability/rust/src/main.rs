/// A "pure" helper that quietly does file IO.
fn load_config(path: &str) -> String {
    std::fs::read_to_string(path).unwrap_or_default()
}

fn main() {
    println!("{}", load_config("/etc/hosts").len());
}
