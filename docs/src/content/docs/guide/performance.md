---
title: Performance
---

Median time per operation, lower is better, beside `postgres_async`, a
native OCaml driver on Async, and libpq, the C library, through the
`postgresql` bindings.

| | postgres-eio | postgres_async | libpq |
|---|--:|--:|--:|
| Round trip, `select $1::int` | 329 µs | 582 µs | 287 µs |
| Insert, one round trip each | 337 µs | 594 µs | 296 µs |
| Insert, 1,000 pipelined in one round trip | 5.0 µs | n/a | n/a |
| Read a 100,000-row result, per row | 138 ns | 142 ns | 169 ns |
| Client CPU per round trip | 41 µs | 51 µs | 21 µs |

Measured with postgres-eio 0.1.0, postgres_async 0.17.0, postgresql 5.4.0. Apple M4 Pro,
Postgres 18.6 in Docker, one connection per driver, text results, median of
three 5 s runs.
