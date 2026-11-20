///| t04_trait_fmt: traits, generic static dispatch, trait-object heterogeneous collection

///|
trait Summary {
  summary(Self) -> String
}

///|
trait Serializable {
  to_kv(Self) -> String
}

///| Umbrella trait used as a trait object (`&Item`).
trait Item: Summary + Serializable {}

///|
struct Article {
  title : String
  author : String
  words : Int
}

///|
struct Tweet {
  user : String
  text : String
  likes : Int
}

///|
struct Metric {
  name : String
  value : Int
  unit : String
}

///|
fn shorten(s : String) -> String {
  if s.length() > 20 {
    s.unsafe_substring(start=0, end=17) + "..."
  } else {
    s
  }
}

///|
impl Summary for Article with summary(self) {
  "Article: \{self.title} by \{self.author} (\{self.words} words)"
}

///|
impl Serializable for Article with to_kv(self) {
  "type=article;title=\{self.title};author=\{self.author};words=\{self.words}"
}

///|
impl Summary for Tweet with summary(self) {
  let unit = if self.likes == 1 { "like" } else { "likes" }
  "@\{self.user}: \{shorten(self.text)} [\{self.likes} \{unit}]"
}

///|
impl Serializable for Tweet with to_kv(self) {
  "type=tweet;user=\{self.user};likes=\{self.likes}"
}

///|
impl Summary for Metric with summary(self) {
  "\{self.name} = \{self.value} \{self.unit}"
}

///|
impl Serializable for Metric with to_kv(self) {
  "type=metric;name=\{self.name};value=\{self.value};unit=\{self.unit}"
}

///|
impl Item for Article

///|
impl Item for Tweet

///|
impl Item for Metric

///|
fn[T : Summary] render_all(items : Array[T]) -> String {
  let lines = []
  for i, x in items {
    lines.push("\{i + 1}. \{x.summary()}")
  }
  lines.join("\n")
}

///|
fn[T : Summary + Serializable] describe(x : T) -> String {
  "\{x.summary()} | \{x.to_kv()}"
}

///|
fn mixed() -> Array[&Item] {
  [
    ({ title: "Agents and Compilers", author: "Ada", words: 1200 } : Article),
    ({ user: "grace", text: "shipping structured diagnostics today", likes: 42 } : Tweet),
    ({ user: "linus", text: "ok", likes: 1 } : Tweet),
    ({ name: "p99_latency", value: 87, unit: "ms" } : Metric),
  ]
}

///|
fn main {
  let items = mixed()
  println(render_all(items))
  for it in items {
    println(describe(it))
  }
  let metrics : Array[Metric] = [
    { name: "p99_latency", value: 87, unit: "ms" },
    { name: "cpu", value: 63, unit: "%" },
  ]
  println(render_all(metrics))
}

///|
test "tweet truncation boundary" {
  let t20 : Tweet = { user: "u", text: "12345678901234567890", likes: 0 }
  let t21 : Tweet = { user: "u", text: "123456789012345678901", likes: 2 }
  assert_eq(Summary::summary(t20), "@u: 12345678901234567890 [0 likes]")
  assert_eq(Summary::summary(t21), "@u: 12345678901234567... [2 likes]")
}

///|
test "render_all" {
  let empty : Array[Metric] = []
  assert_eq(render_all(empty), "")
  assert_true(render_all(mixed()).has_prefix("1. Article: Agents"))
  assert_eq(describe(mixed()[2]), "@linus: ok [1 like] | type=tweet;user=linus;likes=1")
}
