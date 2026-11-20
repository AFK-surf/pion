# t10_graph_topo — topological sort (Kahn) with deterministic order and cycle detection

Input: one item per line, blank lines ignored, items trimmed. `u -> v` is an edge (both names non-empty
after trimming, else `Err("line <n>: malformed edge '<line>'")`, `n` 1-based); a bare `x` declares a node.
Duplicate edges count once; self-loops are cycles.

`toposort(text) -> Result[{order, blocked}, String]`: Kahn's algorithm that always takes the
**byte-wise smallest** ready node, so the order is unique. Nodes never released (on or behind a cycle) are
returned sorted in `blocked`.

`main` prints, for three fixed graphs: `graphN order: <nodes>` when acyclic,
`graphN cycle: ordered=<nodes> blocked=<nodes>` otherwise (comma-separated), or `graphN error: <msg>`.
