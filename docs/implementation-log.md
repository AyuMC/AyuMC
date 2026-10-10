# Implementation log — plugin platform

## 2026-10-10 — runtime experiment, root cause of the hang

Environment: Windows 10 x64, Dart SDK 3.13.4 (Flutter 3.47.5 bundle).

Experiment (outside the repository, `%TEMP%/ayumc-plugin-poc`):

| Host | Artifact | Result |
| --- | --- | --- |
| `dart run` (JIT) | `plugin_main.dart` | spawned, message received |
| `dartaotruntime` / `dart compile exe` host | `plugin_main.aot` | spawned, message received |
| `dartaotruntime` / exe host | `plugin_main.dart` | `does not contain a valid AOT snapshot` |
| `dart run` (JIT) | `plugin_main.aot` | `the JIT VM cannot spawn an isolate using it` |

**Root cause of the hang.** In every failure case the *host* process stayed
alive until killed. The harness created a `ReceivePort` before calling
`Isolate.spawnUri`; when `spawnUri` threw, the code path that would have
consumed (and thereby closed) the port was never reached. An open
`ReceivePort` keeps a Dart VM alive indefinitely. This was a test-harness
defect, not a VM or runtime bug: `dartaotruntime bogus.aot` on its own exits
in ~40 ms with `bogus.aot is not an AOT snapshot`. The forced kill (exit
code -1) was the harness being terminated, never a success signal.

Design consequence: the host never calls `spawnUri` on user artifacts. Each
plugin is a child process; every wait on it is bounded; stdout/stderr are
always drained.

## 2026-10-10 — implementation

New packages: `ayu_ipc` (framing + channel), `ayu_package` (manifest, ZIP,
validation, extraction, authoring), `ayu_runtime` (store, supervisor,
lifecycle, registry, host), `ayu_tool` (`ayu plugin build|package|inspect`),
`examples/example_plugin`. Rewritten: `ayu_plugin_api` (worker SDK),
`ayu_core` (server uses `PluginHost`; in-process `PluginManager`, YAML
discovery and stub plugins removed), `ayu_commands` (async executors,
unregister).

Decisions:

- Backpressure through a single pump loop per channel. `IOSink.add` while a
  `flush` is pending throws `StreamSink is bound to a stream`; the first
  channel design hit this with real pipes and was replaced.
- JIT test fixtures launch `dartvm` directly: under `dart test`,
  `Platform.resolvedExecutable` is the `dart` CLI, which runs scripts in a
  separate `dartvm` child, so pids and kills would not refer to the worker.
- A fixture that "never speaks" must hold a timer: a bare pending `Future`
  lets the VM exit as soon as `main` returns (the inverse of the
  `ReceivePort` hang).
- EOF on a worker's stdout waits up to 2 s for the exit code so failures
  carry the code and the stderr tail; protocol violations from a live
  process fail immediately.

Test commands and results (all on Windows x64, Dart 3.13.4):

| Command | Result |
| --- | --- |
| `packages/ayu_ipc`: `dart analyze && dart test` | 20 passed |
| `packages/ayu_package`: `dart analyze && dart test` | 30 passed |
| `packages/ayu_plugin_api`: `dart analyze && dart test` | 6 passed |
| `packages/ayu_runtime`: `dart analyze && dart test` | 41 passed, 1 skipped (locator "not found" case is skipped because a real runtime exists here) |
| `packages/ayu_tool`: `dart analyze && dart test` | 7 passed (includes the AOT end-to-end: compile → package → install → command → event → disable → enable → uninstall under `dartaotruntime`) |
| root, `ayu_core`, `ayu_commands`, `examples/example_plugin`: `dart analyze` | no issues |
| live run: `Get-Content cmds.txt \| dart run bin/ayumc.dart --plugins <tmp>` | install, hello, stats, disable, enable, stop; exit 0; no leftover `dartaotruntime` |

Bounded-failure proofs in `ayu_runtime/test/worker_process_test.dart`:
silent worker killed at the hello deadline; garbage on stdout detected
immediately as a protocol error; early exit reports code 7 and stderr;
`onEnable` failure reported as a structured init error; busy-loop worker
killed within grace + kill timeout; malformed `.aot` under the real
`dartaotruntime` fails in well under a second. The suite asserts the worker
pid is gone afterwards.

Benchmark (`dart run benchmark/plugin_bench.dart --plugins 10`, example
plugin AOT, host running under `dart run`, this machine):

| Metric | Measured |
| --- | --- |
| cold install → active, 10 sequential | p50 61 ms, p95 98 ms |
| worker RSS | median 13.9 MiB, 10 workers 138.7 MiB |
| host RSS | 220 MiB before, 243 MiB with 10 active, 282 MiB after disabling all |
| command round trip, 1000 sequential | p50 0.18 ms, p95 0.22 ms, p99 0.30 ms |
| event fan-out | 20 000 events × 10 plugins enqueued in 377 ms (~530 k deliveries/s), 0 dropped, all 20 000 received by the sampled plugin |
| disable (graceful), 10 plugins | p50 8.5 ms, p95 12.4 ms |
| hot install → active in the AOT integration test | 157 ms (includes archive extraction and digest verification) |

Interpretation: a JIT host inflates the host RSS baseline; the growth after
disable is not yet attributed (GC timing vs. retained buffers) and needs a
repeated-cycle measurement before any claim. Per-worker cost (~14 MiB,
~60 ms start) is the baseline for deciding whether pooling is ever needed.

Not verified: Linux x64. The implementation uses portable APIs only
(`Process.start` with argument lists, `path`, no shell), but no Linux run
has been performed from this environment (no WSL available).

## 2026-10-10 — modular profile and event packs

The worker runtime stayed. Added on top of it:

- `packageType` `plugin` or `event-pack`, profile constraints, `provides` and
  `events` in the manifest. Existing plugin manifests stay valid: the type
  defaults to `plugin` and an empty profile list matches every profile.
- `ContractRegistry`, a batching outbox and `PrimitiveBus`. The core emits
  only `core.*` primitives. Public contracts come from event packs.
- Profile `AyuMC-1.8.9-release` and `ayu_protocol_189`: handshake, status
  ping and login start. Login does not enter play.
- Console: `event`, `profile`, `contracts`. `plugin` lists only regular
  plugins. Disabling a pack that active plugins require needs `--cascade`,
  which suspends those plugins.

A plugin whose required contract has no provider is installed in state
`suspended` and resumed when a compatible pack becomes active. A failed
`onEnable` still leaves the package installed in `failed`. A contract
conflict during install deletes the staged copy and leaves no record.

## Open items

1. Linux x64 run of the full suite and the AOT integration test.
2. Snapshot compatibility across SDK patch versions is enforced as "exact
   match" until measured otherwise.
3. Package signatures and a trusted-publisher list.
4. Resource limits (Windows Job Objects, Linux cgroups/rlimits) and
   process-tree cleanup.
5. Repeated install/disable cycles to characterise host memory behaviour.
6. Management IPC for the future desktop application (the console `plugin`
   command is the only management surface today).
