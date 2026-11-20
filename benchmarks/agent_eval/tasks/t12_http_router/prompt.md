# t12_http_router — HTTP route matching, path parameters, query parsing, status codes

Route table (first match wins): `GET /health` (health), `GET /users` (user_list), `POST /users` (user_create),
`GET /users/:id` (user_get), `DELETE /users/:id` (user_delete), `GET /files/*path` (file_get).

- Paths split on `/`, empty segments ignored (so a trailing slash is irrelevant). `:name` binds one segment,
  `*name` binds the non-empty remainder joined with `/`.
- A route whose pattern matches but whose method differs makes the result `405` with `allow=` the sorted
  methods of all matching patterns; no pattern match is `404`.
- `user_get` / `user_delete` require `id` to be all digits, else `400 error=invalid id`.
- Query string: `&`-separated `k=v` pairs, percent-decoding (`%XX`) and `+` as space for keys and values,
  later duplicates win, printed sorted by key.

Output per request: `<METHOD> <target> -> <status>` followed by the non-empty parts among
`route=<name>`, `params=<k=v,...>`, `query=<k=v,...>`, `error=<msg>`, `allow=<methods>`.
Each language uses its standard library where it has one: Pion `std/http` (`query_params`), Go `net/url`
(`ParseQuery`); Rust and MoonBit decode by hand.
