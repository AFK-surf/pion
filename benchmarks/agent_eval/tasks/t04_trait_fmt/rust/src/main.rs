//! t04_trait_fmt: traits, generic static dispatch, trait-object heterogeneous collection

pub trait Summary {
    fn summary(&self) -> String;
}

pub trait Serializable {
    fn to_kv(&self) -> String;
}

/// Object-safe umbrella trait for heterogeneous collections.
pub trait Item: Summary + Serializable {}
impl<T: Summary + Serializable> Item for T {}

pub struct Article {
    pub title: String,
    pub author: String,
    pub words: u32,
}

pub struct Tweet {
    pub user: String,
    pub text: String,
    pub likes: u32,
}

pub struct Metric {
    pub name: String,
    pub value: i64,
    pub unit: String,
}

fn shorten(s: &str) -> String {
    if s.len() > 20 {
        format!("{}...", &s[..17])
    } else {
        s.to_string()
    }
}

impl Summary for Article {
    fn summary(&self) -> String {
        format!("Article: {} by {} ({} words)", self.title, self.author, self.words)
    }
}
impl Serializable for Article {
    fn to_kv(&self) -> String {
        format!("type=article;title={};author={};words={}", self.title, self.author, self.words)
    }
}
impl Summary for Tweet {
    fn summary(&self) -> String {
        let unit = if self.likes == 1 { "like" } else { "likes" };
        format!("@{}: {} [{} {}]", self.user, shorten(&self.text), self.likes, unit)
    }
}
impl Serializable for Tweet {
    fn to_kv(&self) -> String {
        format!("type=tweet;user={};likes={}", self.user, self.likes)
    }
}
impl Summary for Metric {
    fn summary(&self) -> String {
        format!("{} = {} {}", self.name, self.value, self.unit)
    }
}
impl Serializable for Metric {
    fn to_kv(&self) -> String {
        format!("type=metric;name={};value={};unit={}", self.name, self.value, self.unit)
    }
}
impl Summary for Box<dyn Item> {
    fn summary(&self) -> String {
        (**self).summary()
    }
}

pub fn render_all<T: Summary>(items: &[T]) -> String {
    items.iter().enumerate().map(|(i, x)| format!("{}. {}", i + 1, x.summary())).collect::<Vec<_>>().join("\n")
}

pub fn describe<T: Summary + Serializable + ?Sized>(x: &T) -> String {
    format!("{} | {}", x.summary(), x.to_kv())
}

pub fn mixed() -> Vec<Box<dyn Item>> {
    vec![
        Box::new(Article { title: "Agents and Compilers".into(), author: "Ada".into(), words: 1200 }),
        Box::new(Tweet { user: "grace".into(), text: "shipping structured diagnostics today".into(), likes: 42 }),
        Box::new(Tweet { user: "linus".into(), text: "ok".into(), likes: 1 }),
        Box::new(Metric { name: "p99_latency".into(), value: 87, unit: "ms".into() }),
    ]
}

fn main() {
    let items = mixed();
    println!("{}", render_all(&items));
    for it in &items {
        println!("{}", describe(it.as_ref()));
    }
    let metrics = vec![
        Metric { name: "p99_latency".into(), value: 87, unit: "ms".into() },
        Metric { name: "cpu".into(), value: 63, unit: "%".into() },
    ];
    println!("{}", render_all(&metrics));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tweet_truncation_boundary() {
        let t20 = Tweet { user: "u".into(), text: "12345678901234567890".into(), likes: 0 };
        let t21 = Tweet { user: "u".into(), text: "123456789012345678901".into(), likes: 2 };
        assert_eq!(t20.summary(), "@u: 12345678901234567890 [0 likes]");
        assert_eq!(t21.summary(), "@u: 12345678901234567... [2 likes]");
    }

    #[test]
    fn render_all_cases() {
        let empty: Vec<Metric> = vec![];
        assert_eq!(render_all(&empty), "");
        assert!(render_all(&mixed()).starts_with("1. Article: Agents"));
        assert_eq!(describe(mixed()[2].as_ref()), "@linus: ok [1 like] | type=tweet;user=linus;likes=1");
    }
}
