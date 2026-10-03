# Local validation

Compiler: OCaml 4.14.1. Build system: Dune 3.14.0. Platform: x86-64 Linux.
Source validation completed during project creation. The remote CI workflow is
configured, but has not been executed on a hosted GitHub repository.

| Check | Result |
| --- | --- |
| `dune build @all` in the default development profile | Passed, with default strict warning settings |
| `dune runtest` | 37 fixtures and 100,000 randomized commands across 10 seeds passed |
| Large sweep fixture | All 100,000 makers filled in FIFO order, without stack overflow |
| Randomized independent model comparison | Exact event traces, open orders, accept/reject decisions, and sequence numbers agree |
| Randomized structural and conservation checks | Passed after every one of 100,000 commands |
| Serialization/replay check | Full canonical state agrees for each random seed |
| Demo replay | 15 commands, 13 accepted, 2 rejected, 8 trades, 27 matched units, 0 active orders |
| CLI generated workload replay | 10,000 commands, seed 42: replay verified |
| CLI state export and final-state compare | Passed, including detecting unequal states |
| CLI malformed input | Exit code 2 with source filename and line number |
| CLI invalid benchmark count | Exit code 2 |
| CLI identical input/state-output path | Rejected without changing the input |
| Release build and native benchmark | Three 100,000-command runs and one 1,000,000-command run completed |

The tests are evidence for the stated rules, not a formal proof or a claim about
unimplemented exchange behavior. The independent reference matcher uses flat
lists and sorted candidates rather than the engine's nested maps and ID index.
The fixture expectations are specified separately from that model.

See `demo-output.txt` for the complete reproducible demo trace, and
`benchmarks.md` plus `../benchmarks/*.json` for measured performance and scope.
