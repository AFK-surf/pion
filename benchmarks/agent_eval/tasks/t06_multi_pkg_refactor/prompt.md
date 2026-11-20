# t06_multi_pkg_refactor — multi-package module boundaries (internal edit vs exported signature)

Three packages with a strict dependency direction `app -> inventory -> shapes` (and `app -> shapes`):

- `shapes`: a `Shape` sum type (`Rect(w,h)`, `Square(s)`, `RightTri(base,height)`), exported `area2(shape)`
  (twice the area, so it stays integral), `kind_name(shape)` (`rect|square|tri`); a private helper
  `unit_scale()` is used by `area2`.
- `inventory`: `Part{name, shape, qty}`, exported `total_area2(parts)`, `largest(parts)` (first maximum by
  `area2`) and `qty_by_kind(parts)` (lines `kind <k> qty=<n>` in ascending kind order).
- `app`: builds four parts and prints a per-part line, the total, the largest part and the per-kind totals.

Refactor scenario used by dimension 3 of the suite (marker comments in the sources):
- **internal edit** (`AE_EDIT_BODY`): change the body of the private `shapes::unit_scale` without touching any
  exported signature — downstream packages should not need re-checking beyond their dependency on `shapes`' interface;
- **interface edit** (`AE_EDIT_IFACE`): rename an exported (unused) probe function in `shapes`, which changes the
  package's public interface and invalidates its dependents.

Every package carries its own unit tests.
