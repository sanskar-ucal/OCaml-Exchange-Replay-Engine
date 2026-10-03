# Axiom — OCaml Exchange & Replay Engine

[Source repository](https://github.com/sanskar-ucal/OCaml-Exchange-Replay-Engine)

A deterministic, single-instrument exchange simulator in OCaml. The core is a
pure state transition: `Book.apply : t -> command -> (t * event list, error) result`.
Every successful command produces a new immutable state and an ordered event
trace. Replaying the same command stream reconstructs the complete state,
including the command sequence and used order IDs.

The interesting engineering problems here are price–time priority, atomic
rejection, immutable snapshots, exact arithmetic, and testing an optimized
implementation against a deliberately simpler independent model.

## Features

- Limit and market orders, partial fills, multi-level sweeps, and maker-price execution.
- GTC, IOC, FOK, and post-only limit orders.
- Indexed cancellations and strict quantity reductions that retain FIFO priority.
- Abstract, checked types for prices, quantities, and order IDs; prices use integer ticks.
- Persistent balanced maps for price levels, arrival priority, and order IDs.
- Read-only FOK preflight: insufficient liquidity changes neither state nor sequence.
- Human-readable command streams, replay verification, canonical state export,
  reproducible synthetic workloads, and native-code benchmarks.
- 37 explicit fixtures and 100,000 randomized commands across 10 seeds, with
  independent-model comparison, structural invariants, conservation checks,
  and serialized replay.
- A GitHub Actions workflow configured for OCaml 4.14 and 5.2.

## Run it

Requires OCaml >= 4.13 and Dune >= 2.9. Runtime libraries: Stdlib and Unix only.
No third-party OCaml library is needed.

With an existing OCaml/opam environment:

```sh
cd ocaml-exchange
opam install . --deps-only --with-test -y
opam exec -- dune build @all
opam exec -- dune runtest
opam exec -- dune exec axiom -- replay examples/demo.commands
opam exec -- dune exec axiom -- verify examples/demo.commands
```

If you are setting up OCaml on a Mac for the first time:

```sh
brew install opam
opam init
opam switch create axiom 4.14.2
eval "$(opam env --switch=axiom --set-switch)"
```

Then run the commands above. `make build`, `make test`, `make demo`, and `make bench`
are shortcuts once the switch environment is active. See the official
[OCaml installation guide](https://ocaml.org/docs/installing-ocaml) and
[Dune quickstart](https://dune.readthedocs.io/en/stable/quick-start.html).

## A small example

```text
LIMIT first SELL 10010 7 GTC
LIMIT second SELL 10010 5 GTC
LIMIT taker BUY 10010 9 GTC
```

The third command executes 7 units against `first`, then 2 against `second`.
`second` remains in the book with 3 units and its original arrival sequence.

```text
[2] TRADE maker=first taker=taker price=10010 quantity=7 notional=70070
[2] TRADE maker=second taker=taker price=10010 quantity=2 notional=20020
```

`notional` is price ticks multiplied by quantity units; it is not a dollar amount
unless the caller defines a currency scale.

## Command protocol

Commands are uppercase and whitespace-delimited. `#` starts a comment.

| Command | Example | Meaning |
| --- | --- | --- |
| `LIMIT id side price quantity tif` | `LIMIT a BUY 10000 10 GTC` | Match eligible liquidity; handle remainder according to TIF |
| `MARKET id side quantity` | `MARKET b SELL 5` | Consume eligible liquidity; expire any remainder |
| `CANCEL id` | `CANCEL a` | Remove an active resting order |
| `REDUCE id quantity` | `REDUCE a 4` | Set a strictly smaller remaining quantity, preserving priority |

`side` is `BUY` or `SELL`. `tif` is `GTC`, `IOC`, `FOK`, or `POST_ONLY`.
Prices are positive integer ticks up to 1,000,000,000; quantities are positive
integer units up to 1,000,000. These bounds keep an individual trade notional
within signed 64-bit arithmetic. IDs contain 1–64 ASCII letters, digits,
underscores, or hyphens.

| TIF | Remainder / rejection policy |
| --- | --- |
| GTC | Rest the unfilled portion at the original limit price |
| IOC | Match immediately, then expire the unfilled portion |
| FOK | Reject before any matching unless the full quantity is executable within the limit |
| POST_ONLY | Reject if immediately marketable; otherwise rest |

Accepted submit IDs cannot be reused during a session, even after a full fill,
cancellation, or expiry. Rejected submits do not reserve an ID. Only successful
commands advance the sequence. A reduction cannot change side or price, and
cannot increase or retain the current quantity; use cancellation and a fresh
ID for a replacement.

## CLI

```sh
dune exec axiom -- replay examples/demo.commands --quiet --state /tmp/axiom-state.txt
dune exec axiom -- verify examples/demo.commands
dune exec axiom -- generate 100000 42 /tmp/axiom.commands
dune exec axiom -- replay /tmp/axiom.commands --quiet
dune exec --profile release axiom -- bench 100000 42 --json /tmp/axiom-bench.json
```

`replay` streams the input file and reports domain rejections. Malformed syntax
stops processing with a filename and line number. `verify` runs the file twice
and compares complete canonical final states and aggregate statistics.
`compare FILE_A FILE_B` compares final states; it does not compare complete event
histories. `--state` exports state for inspection; it is not a checkpoint loader.

## Design and cost

| File | Responsibility |
| --- | --- |
| `lib/types.ml/.mli` | Checked scalar types, command and event variants |
| `lib/book.ml/.mli` | Persistent matching state, indexed updates, invariant checker |
| `lib/protocol.ml/.mli` | Parse and serialize the line protocol |
| `lib/workload.ml/.mli` | Generate repeatable synthetic command streams |
| `bin/main.ml` | File I/O, replay, summaries, workload generation, benchmarks |
| `test/reference.ml` | Independent flat-list model with sorted matching candidates |
| `test/test_exchange.ml` | Fixtures, model comparison, invariants, conservation, replay |

The two sides of the book are `price -> (arrival sequence -> resting order)`.
The order index maps ID to the same immutable resting record. Bid matching uses
the highest bid; ask matching uses the lowest ask. The smallest sequence at a
price level wins. No wall clock participates in ordering.

Let P be price levels, L orders at a level, N active orders, and U previously
accepted submit IDs. Resting insertion, cancellation, reduction, and each maker
update cost `O(log P + log L + log N)`. Submit duplicate checks and ID reservation
cost `O(log U)`. A sweep pays the maker update cost for each maker it touches.
FOK adds a read-only traversal over executable levels/orders up to the required
quantity, then normal matching if successful. State memory is `O(N + U)` for
the current book; retaining old snapshots keeps structurally shared history
alive. Canonical state generation sorts through the maps and used-ID set.

This design trades allocation and tree traversal for simple snapshots,
deterministic behavior, and reliable cancellation. A mutable specialized book
may be faster, but would need a separate mechanism for snapshots and rollback.
The official [OCaml Map documentation](https://ocaml.org/manual/5.2/api/Map.html)
describes its purely applicative balanced-tree implementation.

## Correctness evidence

Every randomized transition is compared with the independent model for matching
decisions, event order, resting state, and sequence number. After every step the
tests also check:

- Book levels and the ID index agree exactly.
- Active IDs and priority sequences are unique; no price level is empty.
- Every resting order has positive quantity, the correct side/price key, and a
  previously accepted ID.
- The best bid remains strictly below the best ask.
- `submitted units = 2 × traded units + cancelled/reduced/expired units + open units`.
- A serialization-and-replay pass reconstructs complete final state.

The fixtures cover price priority in both directions, same-price FIFO, partial
fills, maker pricing, each TIF, duplicate IDs, reductions, cancellation,
independent snapshot branches, invalid protocol inputs, and maximum notional.

The configured CI matrix has not been run remotely as part of this source
package. Local validation and the exact compiler version are recorded in
`docs/validation.md`.

## Benchmarks and scope

The benchmark times `Book.apply` plus event counters over a pre-generated
synthetic command array. Parsing, generation, file I/O, canonicalization, and
invariant scans are outside the timed region. It reports accepted and rejected
commands separately, CPU/wall time, throughput, allocation, and GC counts.
Both accepted and rejected attempts contribute to commands/sec. Results depend
on hardware, compiler, allocation, and workload; rerun locally before quoting
performance. See `docs/benchmarks.md` and the raw JSON files in `benchmarks/`.

This is a single-process educational matching simulator. It has no networking,
multi-instrument routing, exchange connection, ownership/self-trade prevention,
account balances, fees, settlement, crash-safe journal, or distributed consensus.
The MD5 state fingerprint is a display label, not a security guarantee;
verification compares the full canonical bytes. No profitability or production
throughput claim is made.

## Learning and extension

Read `docs/interview-notes.md`, run the demo, and change a matching rule while
keeping the tests green. Useful next extensions are explicit cancel/replace
priority rules, a multi-instrument router, a checked position/cash ledger,
crash-safe command logging, a shrinker for failing random streams, and a mutable
book implementation measured against the same reference model.

`resume-entry.tex` contains the replacement project section with its GitHub link.
Include OCaml in your skills once you can explain and modify the code.
