mod geo {
    pub fn area(w: i64, h: i64) -> i64 {
        w * h * secret_scale(1)
    }

    fn secret_scale(x: i64) -> i64 {
        x * 2
    }
}

fn main() {
    println!("{}", geo::area(2, 3));
    println!("{}", geo::secret_scale(3));
}
