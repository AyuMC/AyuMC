# AyuMC Plugin Platform

Gameplay events are no longer a core catalog. Event packs, the 1.8.9 profile
and the contract registry are described in `docs/modular-platform.md`. This
document remains the reference for the `.ayu` archive, the worker supervisor
and the IPC frame format.

Plugins are Dart programs compiled ahead of time, shipped as `.ayu` archives
and executed by the server in **separate `dartaotruntime` processes**. The
server never loads plugin code into its own process; everything crosses a
length-prefixed IPC channel as plain data.

```text
server (ayu_core + ayu_runtime)
  ├─ PluginHost ── install / enable / disable / update / uninstall
  │     ├─ PluginStore      plugins/installed, staging, data, state.json
  │     ├─ HostRegistry     commands + event subscriptions, per owner
  │     └─ WorkerController ── WorkerProcess ── dartaotruntime plugin.aot   (one per plugin)
  │                                                │ stdout/stdin: ayu_ipc frames
  │                                                │ stderr: diagnostics (bounded tail)
  └─ console: `plugin ...`, mirrored plugin commands
```

## Why this runtime model

Verified on Windows x64 with Dart 3.13.4 (see `docs/implementation-log.md`):

| Fact | Consequence |
| --- | --- |
| A compiled host (`dart compile exe`, `dartaotruntime`, Flutter release) cannot load Dart *source*; `Isolate.spawnUri` fails with "does not contain a valid AOT snapshot". | `.ayu` must carry precompiled artifacts. Sources are included for inspection only. |
| An AOT snapshot only runs on the `dartaotruntime` of the exact SDK version that produced it. | Manifests record `dartSdk`; the host refuses mismatches with a rebuild instruction. |
| `Isolate.spawnUri` creates an isolate group with no shared objects; a bad artifact can wedge the host VM. | Plugins run as child processes. Fault containment is a process boundary, kill is `Process.kill`. |
| `dartaotruntime bogus.aot` exits in ~40 ms with a clear stderr message. | Malformed artifacts fail fast; deadlines cover anything slower. |

Rejected: `dart_eval` (language subset, interpreter speed), in-process
`Isolate.spawn` (cannot load code from disk), loading `.aot` into the server
process (an invalid artifact wedges the server VM).

## Package format (`.ayu`)

A ZIP archive (stored or deflate, no ZIP64, no encryption) with a custom
extension. Specification constants live in `ayu_package/lib/src/spec.dart`.

```text
<id>-<version>.ayu
├── manifest.json                 formatVersion 1
├── bin/<os>-<arch>/plugin.aot    one AOT snapshot per supported target
├── src/                          lib/, bin/, pubspec.yaml, pubspec.lock, ayu_plugin.yaml
├── assets/                       optional
└── config/config.json            optional defaults
```

### `manifest.json`

| Field | Required | Meaning |
| --- | --- | --- |
| `formatVersion` | yes | Package format version. Hosts reject versions they do not know. |
| `id` | yes | `^[a-z][a-z0-9_]{1,63}$`; never changes across versions. |
| `name`, `version` | yes | Display name; semantic version. |
| `api` | yes | Version constraint over the host plugin API (`IpcProtocol.apiVersion`, currently `1.0.0`). |
| `entryPoint` | no | Archive path of the source entry (informational). |
| `artifacts` | yes to run | Map `target id -> {path, sha256, size, dartSdk}`. |
| `dependencies` | no | `[{id, version, optional}]`. Required deps must be installed, version-compatible and active. |
| `capabilities` | no | Subset of `commands`, `events`, `config`. The host refuses requests outside the declared set. |
| `description`, `authors`, `homepage`, `license`, `build` | no | Metadata; `build` records tool, SDK and timestamp. |

Validation collects every problem and reports them together
(`PackageException(manifestInvalid)`).

### Archive safety

Enforced before anything is extracted (`AyuPackage.open`):

- no `..`, absolute paths, drive letters, backslashes, control characters,
  Windows device names (`CON`, `NUL`, …), trailing dots/spaces;
- case-insensitive duplicate detection (Windows file systems);
- limits on entry count, file size, total uncompressed size, per-entry size,
  manifest size, central directory size, path depth and name length;
- declared sizes verified against inflated sizes (a lying header can never
  inflate past its own claim), CRC-32 on every entry;
- artifacts must exist with the declared size; SHA-256 is verified while
  extracting and the destination is removed on any mismatch.

Installation extracts into `plugins/staging/<token>/`, then renames the
directory into `plugins/installed/<id>/<version>/`. Leftover staging
directories are purged when the host starts. The state file is written via
temp file + rename.

A valid archive with matching digests proves *integrity* (the bytes are the
ones the manifest describes), not *authenticity* or *safety*. Signatures
are not implemented yet.

## Compatibility rules

The host refuses, with an actionable message, a package that

- requires a plugin API range that excludes the host's version;
- has no artifact for the host's `<os>-<arch>` (source-only packages are
  rejected: "Build it with `ayu plugin build --target <id>`");
- has an artifact built with a different Dart SDK than the host's
  `dartaotruntime`;
- declares a capability the host does not know;
- has unsatisfied required dependencies.

## Runtime location

`DartRuntimeLocator` searches, in order: an explicit path, the
`AYUMC_DARTAOTRUNTIME` variable, `dartaotruntime` next to the running
executable, and `PATH`. Each candidate is verified with `--version` under a
deadline. Production servers only need the `dartaotruntime` binary of the
matching SDK version; the full SDK is needed only by plugin developers.

## IPC protocol (version 1)

Transport: the worker's stdout carries frames to the host, stdin carries
frames from the host. stderr is diagnostics only and is drained into a
bounded tail. `print()` inside a plugin is redirected to the structured log,
never to stdout. A plugin that writes to stdout directly corrupts its own
channel; the host detects the violation and kills the worker.

Frame: `[u32 length][u8 kind][u32 id][payload]`, big-endian. `kind` is
1 request, 2 response, 3 notification. Payload is a UTF-8 JSON object:
requests/notifications `{"m": method, "p": params}`, responses
`{"ok": true, "r": result}` or `{"ok": false, "e": {"c": code, "m": message}}`.

Limits: 1 MiB per frame (negotiated in hello), 256 pending requests per
direction, 256 in-flight inbound handlers, notifications dropped above a
4 MiB unflushed outbound watermark (counted per plugin as `droppedEvents`).
Requests are never dropped; they are bounded by the pending limit and by
timeouts.

| Direction | Method | Purpose |
| --- | --- | --- |
| worker → host | `hello` | First message. Offers protocol versions; the host picks one. |
| host → worker | `init` | Plugin identity, directories, capabilities, config. Worker runs `onEnable`. |
| host → worker | `shutdown` | Worker runs `onDisable` within the grace period, responds, exits 0. |
| host → worker | `ping`, `command.execute`, `event` (notification) | Steady state. |
| worker → host | `command.register/unregister`, `event.subscribe/unsubscribe`, `config.get`, `log` (notification) | Steady state; capability-checked. |

Error codes: `protocol`, `timeout`, `closed`, `message_too_large`,
`too_many_requests`, `method_not_found`, `invalid_params`, `internal`,
`capability_denied`, `unavailable`, `conflict`, `not_found`.

Worker exit codes: 0 normal, 2 host connection lost, 70 handshake/protocol
failure.

## Plugin SDK (`package:ayu_plugin_api`)

```dart
import 'package:ayu_plugin_api/ayu_plugin_api.dart';

void main() => runPlugin(MyPlugin());

final class MyPlugin extends AyuPlugin {
  @override
  Future<void> onEnable() async {
    await context.commands.register('hello', (call) => CommandResult.ok('Hi ${call.sender}'));
    await context.events.subscribe('player.join', (event) => context.log.info('${event.data}'));
    context.timers.periodic(const Duration(minutes: 1), (_) {});
  }

  @override
  void onDisable() => context.log.info('bye');
}
```

`PluginContext` exposes `plugin` (id/name/version), `installDirectory`,
`dataDirectory`, `config` + `reloadConfig()`, `log`, `commands`, `events`,
`timers` (cancelled automatically on disable) and `host.request()` for
future methods. Registrations are owned by the host and removed the moment
the plugin leaves the active state, whatever the worker does.

## Lifecycle

```text
discovered → validating → staged → starting → active → stopping → disabled
                 ↓                    ↓          ↓          ↓
               failed               failed    crashed     failed
```

| Operation | Behaviour |
| --- | --- |
| install | open + validate → compatibility → dependencies → stage → commit → (start). A start failure leaves the plugin installed in `failed` with the error, exit code and stderr tail. |
| enable | Fresh process from the installed artifact. Required deps must be active. |
| disable | Registrations removed first (no routing), then `shutdown` request; after `shutdownGracePeriod` the process is killed; after `killTimeout` with no exit the plugin is marked `failed` and abandoned. Refused while active plugins require it. |
| update | New version staged next to the old one; old worker stopped only after staging succeeded; new worker started; on failure the new files are removed and the old version restarted. Dependents' constraints must accept the new version. |
| uninstall | Stop if needed, remove installed files. `plugins/data/<id>` is kept. Refused while installed plugins require it. |
| crash | Worker exit while active → registrations removed, state `crashed`, automatic restart within a budget (default 3 per minute), then left crashed. |
| host restart | Enabled plugins restart in dependency order; cycles are reported and skipped. |

Every operation on a plugin id is serialised; the server event loop is never
blocked. All deadlines are in `PluginRuntimeOptions`.

Disabling logically (stop routing) happens instantly. Terminating the process
is bounded. Reclaiming memory is done by the operating system when the process
ends; a plugin's objects never live in the server, so nothing has to be
"unloaded" from the server heap.

## Security model

| Property | Status |
| --- | --- |
| Process separation | Yes. One `dartaotruntime` process per plugin. |
| Fault isolation | Yes. Crashes, hangs, protocol corruption and init failures are contained and bounded by deadlines. |
| Package integrity | Yes. Structural validation, CRC-32, SHA-256 of artifacts, atomic staging. |
| Package authenticity | No. No signatures yet; a matching digest does not make a plugin trustworthy. |
| API capability checks | Yes, for the official API only. |
| Resource limits | Partial. Message sizes, queues, timeouts and restart budgets; **no CPU or memory limits** on workers. |
| Filesystem/network restrictions | **No.** A worker runs with the server's OS privileges and may use `dart:io` freely. |
| OS sandboxing | **No.** Windows Job Objects / restricted tokens and Linux namespaces/seccomp are future, platform-specific work. |
| Process-tree cleanup | **No.** Killing a worker does not kill processes the plugin spawned. |

Threat model handled today: defective plugins, corrupt or malicious archives
(traversal, bombs, tampering after packaging), unresponsive or crashing
workers, oversized or malformed messages. Not handled: a plugin author who
intends harm; treat third-party plugins as code you trust at the OS level.

## Performance

Measured with `packages/ayu_runtime/benchmark/plugin_bench.dart`; recorded
runs are in `docs/implementation-log.md`. The benchmark reports cold start,
per-worker RSS, command round trip, event fan-out with drop counts, and
disable latency. Numbers are machine-specific; the one-process-per-plugin
model is the measured baseline, not a final answer — if realistic plugin
counts make it unsuitable, pooled or in-process profiles will be evaluated
against the fault-containment loss.

## Developer workflow

```sh
cd my_plugin
dart pub get
dart run <repo>/packages/ayu_tool/bin/ayu.dart plugin build  [--target windows-x64 --target linux-x64]
dart run <repo>/packages/ayu_tool/bin/ayu.dart plugin package
dart run <repo>/packages/ayu_tool/bin/ayu.dart plugin inspect build/ayu/my_plugin-1.0.0.ayu
```

`ayu plugin build` runs `dart compile aot-snapshot`. Cross-compilation
follows the SDK: any 64-bit host can target Linux; Windows artifacts must
be built on Windows. A package for both targets contains both snapshots.
Project metadata comes from `ayu_plugin.yaml` (see
`examples/example_plugin`).
