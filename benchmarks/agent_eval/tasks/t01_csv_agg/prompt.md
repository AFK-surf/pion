# t01_csv_agg — CSV parsing and grouped aggregation

Implement `aggregate(csv) -> Report` and `format_report(report) -> String`.

- Input is UTF-8 text; lines end in `\n` or `\r\n`. Blank / whitespace-only lines are ignored.
- The first non-blank line is the header `region,product,qty,price_cents` (fields trimmed).
- Every other line is a row. Fields are split on `,` and trimmed. A row is **valid** iff it has exactly
  4 fields and `qty` / `price_cents` are non-empty unsigned decimal integers (digits only, at most 9 digits).
  Invalid rows are counted, never aborting the run.
- Aggregate valid rows per `region`: `rows`, `qty` (sum), `revenue` (sum of `qty * price_cents`).
- `format_report` prints one line per region in ascending byte order of the region name:
  `<region> rows=<n> qty=<q> revenue=<r>`, then `invalid=<n>` and `total_revenue=<sum>`.

`main` aggregates the fixed sample below and prints the report (see `expected.txt`).
Unit tests cover the integer parser, CRLF input, header-only input and the sample.
