struct User {
    name: String,
    age: u32,
}

fn main() {
    let u = User { name: "ada".to_string(), age: 36 };
    println!("{}", u.name);
    println!("{}", u.agee);
}
