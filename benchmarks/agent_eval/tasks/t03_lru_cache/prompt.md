# t03_lru_cache — fixed-capacity LRU cache (struct + map + eviction)

Implement an LRU cache from `String` keys to `Int` values with O(1) `get` / `put`:
a hash map `key -> slot` plus an index-linked (arena) doubly linked recency list, slots reused on eviction.

- `get(key) -> Option[Int]`: a hit moves the key to most-recently-used and counts `hits`; a miss counts `misses`.
- `put(key, value) -> Option[String]`: an existing key is updated and promoted; a new key on a full cache
  evicts the least-recently-used key (returned, counted in `evictions`).
- `order()`: keys from most- to least-recently used.

`main` runs the fixed script (capacity 3) `put a 1, put b 2, put c 3, get a, put d 4, get b, put c 30, put e 5,
get a, get c, get d, get e`, printing every `get` result and eviction, then
`order=<keys> hits=<h> misses=<m> evictions=<e>`.
