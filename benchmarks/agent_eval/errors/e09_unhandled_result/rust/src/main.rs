fn save(x: i64) -> Result<(), String> {
    if x < 0 {
        Err("negative".to_string())
    } else {
        Ok(())
    }
}

fn main() {
    save(-1);
    println!("saved");
}
