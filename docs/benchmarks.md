# Native synthetic benchmarks

Measured with OCaml 4.14.1 and Dune 3.14.0, `release` profile, x86-64 Linux in
a shared virtualized environment. Reported CPU: INTEL(R) XEON(R) PLATINUM 8573C.
Each run is one single-threaded process; runs were sequential. Timing variation
and host contention limit comparisons with other environments.

The pre-generated seed-42 workload uses 75% submit attempts, 15% cancellation
attempts, and 10% strict-reduction attempts in expectation. Submits mix market,
GTC, IOC, FOK, and post-only orders; prices span 21 integer tick levels. Cancel
and reduce targets are sampled from earlier numeric IDs, so many refer to
already filled or nonexistent orders. This explains the substantial rejection
fraction. It is an exercise workload, not a captured exchange feed.

Generation and a separate 1,000-command warmup run precede measurements. The
timed region includes `Book.apply` and event statistics. It excludes parsing,
file I/O, generation, invariant scans, canonicalization, and hashing. Both
accepted and rejected commands are counted in throughput. Runtime allocations
and GC are included. A single trade event may execute many units.

| Commands | Run | Wall seconds | Commands/sec | Accepted | Rejected | Trade events |
| --- | --- | --- | --- | --- | --- | --- |
| 100,000 | 1 | 0.114002 | 877,178 | 69,745 | 30,255 | 57,077 |
| 100,000 | 2 | 0.121955 | 819,975 | 69,745 | 30,255 | 57,077 |
| 100,000 | 3 | 0.117188 | 853,330 | 69,745 | 30,255 | 57,077 |
| 1,000,000 | 1 | 1.469079 | 680,699 | 697,968 | 302,032 | 570,754 |

The three 100,000-command runs produced identical complete-state display
fingerprints. Raw outputs retain allocation and GC counts in `benchmarks/`;
`environment.json` records measurement metadata. Correctness is checked in the
separate test suite, including full canonical-byte replay comparisons.

Reproduce on your own machine:

```sh
opam exec -- dune exec --profile release axiom -- bench 100000 42 --json /tmp/axiom-100k.json
opam exec -- dune exec --profile release axiom -- bench 1000000 42 --json /tmp/axiom-1m.json
```

These results measure an in-memory educational simulator under one workload.
They do not establish end-to-end, durable, distributed, or real-market capacity.
The supplied resume entry intentionally quotes correctness coverage rather than
using synthetic throughput as a deployment claim.
