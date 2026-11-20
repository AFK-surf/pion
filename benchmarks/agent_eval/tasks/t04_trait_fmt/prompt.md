# t04_trait_fmt — multi-type trait / interface polymorphism and collection rendering

Two traits (interfaces): `Summary { summary() -> String }` and `Serializable { to_kv() -> String }`,
implemented by three record types:

| type | `summary()` | `to_kv()` |
|---|---|---|
| `Article{title, author, words}` | `Article: <title> by <author> (<words> words)` | `type=article;title=..;author=..;words=..` |
| `Tweet{user, text, likes}` | `@<user>: <text> [<n> like(s)]` — text longer than 20 chars becomes its first 17 chars + `...`; `1 like`, otherwise `likes` | `type=tweet;user=..;likes=..` |
| `Metric{name, value, unit}` | `<name> = <value> <unit>` | `type=metric;name=..;value=..;unit=..` |

- `render_all[T: Summary](items)` — generic, statically dispatched: `"<i>. <summary>"` lines (1-based) joined by `\n`.
- `describe[T: Summary + Serializable](x)` — `"<summary> | <to_kv>"`.
- A **heterogeneous** collection (article, two tweets, metric) rendered through the same functions, using each
  language's idiom: trait objects (`Box<dyn Item>` in Rust, `&Item` in MoonBit), an interface slice in Go;
  Pion has no trait objects (monomorphization only), so it uses a closed enum wrapper that implements both traits.

`main` prints the heterogeneous `render_all`, one `describe` per item, then `render_all` over `Array[Metric]`.
