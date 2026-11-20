use std::thread;

fn main() {
    let mut hits: Vec<i32> = Vec::new();
    thread::scope(|s| {
        for w in 0..4 {
            s.spawn(|| {
                hits.push(w);
            });
        }
    });
    println!("{}", hits.len());
}
