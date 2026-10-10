# AyuMC

A Minecraft server platform written in Dart with a process-isolated plugin
system. The server core (protocol, worlds, players) is not implemented yet;
the plugin platform is.

## Layout

| Path | Purpose |
| --- | --- |
| `bin/ayumc.dart`, `lib/ayumc.dart` | Server entry point and console loop |
| `packages/ayu_core` | Server lifecycle, built-in commands, plugin host integration |
| `packages/ayu_runtime` | Plugin host: install/enable/disable/update/uninstall, supervised `dartaotruntime` workers |
| `packages/ayu_package` | `.ayu` package format: manifest, validation, safe extraction, authoring |
| `packages/ayu_ipc` | Wire protocol shared by host and workers |
| `packages/ayu_plugin_api` | SDK plugins compile against |
| `packages/ayu_tool` | `ayu plugin build \| package \| inspect` |
| `packages/ayu_commands`, `ayu_events`, `ayu_logging` | Console commands, in-process events, logging |
| `examples/example_plugin` | Reference plugin project |
| `docs/plugin-platform.md` | Format, protocol, lifecycle, security model |
| `docs/implementation-log.md` | Decisions, measurements, test results |

## Run

```sh
dart pub get
dart run bin/ayumc.dart [--plugins <dir>]
```

Console: `ping`, `say <text>`, `plugin list|info|install|enable|disable|update|uninstall`, `stop`.
Plugin commands appear on the console while their plugin is active.

The server needs a `dartaotruntime` binary of the same Dart SDK version the
plugins were built with (found next to `dart`, via `AYUMC_DARTAOTRUNTIME`, or
on `PATH`).

## Build a plugin

```sh
cd examples/example_plugin
dart pub get
dart run ../../packages/ayu_tool/bin/ayu.dart plugin package
# -> build/ayu/example_plugin-1.0.0.ayu
```

## Test

Each package has its own suite: `dart test` inside `packages/<name>`.
`packages/ayu_tool` includes the AOT end-to-end test (tag `aot`), which
compiles the example plugin and runs it under `dartaotruntime`.

Supported targets: Windows x64 (verified), Linux x64 (portable
implementation, not yet verified on Linux).
