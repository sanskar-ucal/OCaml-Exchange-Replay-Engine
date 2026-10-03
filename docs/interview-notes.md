# Understanding Axiom

Use these notes to understand the implementation before discussing it as your
project. The package was created with AI assistance. Your strongest interview
material will come from reviewing it, making an extension yourself, and being
able to explain the consequences of a changed rule.

## A 45-second explanation

"Axiom is a deterministic exchange simulator in OCaml. It matches limit and
market orders using price–time priority and handles partial fills, cancellation,
and several time-in-force policies. The core returns a new immutable order book
and an ordered list of events. I tested its matching decisions against an
independent list-based model, checked structural and quantity invariants, and
verified that serialized command replay reconstructs the complete state."

Use this as a description of the project. Attribute implementation work in a
way that reflects what you personally reviewed, changed, and understand.

## Questions worth being able to answer

**Why OCaml?** Commands and events are variants; exhaustive pattern matching
makes policies explicit. Abstract module types prevent mixing prices and
quantities. Persistent maps keep old snapshots valid without manual copying.
The price is allocation and tree traversal, which the benchmark exposes.

**Why two levels of maps?** The first level selects the best price. The second
selects the earliest arrival and supports deleting a cancelled order without
walking a FIFO list. The separate ID map locates the order's side, price, and
sequence for cancellation.

**Why not use system timestamps?** A monotone successful-command sequence gives
an unambiguous total order. Identical inputs produce identical output regardless
of clock precision, host time, or scheduling.

**What happens when a limit order crosses?** Match against the best eligible
opposing order at the maker's price. Remove or reduce the maker. Continue until
the incoming quantity is exhausted or the next price is ineligible. GTC rests
the remainder; IOC and market orders expire it.

**How is FOK atomic?** First traverse eligible liquidity without changing the
book. Reject if it is insufficient. In this single-threaded pure transition the
book cannot change between preflight and matching, so successful matching fully
fills. A concurrent implementation would need a single sequencer or an atomic
commit/validation mechanism.

**Does reducing an order move it to the back of the queue?** No. Only a strict
quantity decrease is allowed and the original priority sequence remains. A
price change or increase is intentionally a fresh order after cancellation.

**Why integer ticks?** Floating-point arithmetic can lose exactness. Separate
bounded prices and quantities give exact comparisons, and their product fits
in signed 64-bit arithmetic. A production ledger would also need checked
cumulative arithmetic and an explicit currency/tick scale.

**How does replay work?** Serialize commands in order, parse them, and call the
same transition function starting from `Book.empty`. Rejections do not advance
state. The canonical state includes used IDs and sequence as well as resting
orders, because those hidden details affect later commands.

**What do the property tests prove?** They provide evidence across 100,000
seeded commands, not a formal proof. Agreement with an independently structured
model catches algorithm errors; independent expected-value fixtures reduce the
risk of both models encoding the same wrong rule. Conservation catches dropped
or duplicated quantity even if final top-of-book prices look plausible.

**Why is the trade factor two in conservation?** Every filled unit removes one
unit from the resting maker and one from the incoming taker. The submitted total
contains both sides, so a matched unit consumes two submitted units.

**What would you optimize?** First profile allocation and level traversal. Then
test cached best prices or a mutable data structure against the same reference
model. Compare identical workloads, include acceptance/rejection and depth,
and measure GC and memory rather than relying on a headline throughput number.

**Is it distributed or crash-safe?** No. The current project is a deterministic
single-process state machine. Replay is a useful building block, but durable
logging, replication, networking, and consensus require separate work.

## Exercises to make it your own

1. Trace the demo manually and predict all eight trade events before running it.
2. Add a fixture where an IOC sell sweeps two bid levels but leaves a remainder.
3. Implement cancel/replace with a fresh ID, then test exactly when priority changes.
4. Add a randomized counterexample shrinker that removes chunks of a failing stream.
5. Benchmark a second book design against the current engine using identical inputs.

## Sources

- [Jane Street technology](https://www.janestreet.com/technology/): context for
  OCaml and functional programming; no claim about specific hiring criteria.
- [OCaml Map](https://ocaml.org/manual/5.2/api/Map.html): persistent balanced maps.
- [Dune quickstart](https://dune.readthedocs.io/en/stable/quick-start.html): build workflow.
- [setup-ocaml](https://github.com/ocaml/setup-ocaml): CI action configuration.
