# Example Plugin

Reference AyuMC plugin. Build and package it from this directory:

```sh
dart pub get
dart run ../../packages/ayu_tool/bin/ayu.dart plugin package
```

The archive lands in `build/ayu/example_plugin-1.0.0.ayu` and contains the
compiled artifact for the current machine (`bin/<os>-<arch>/plugin.aot`), the
sources under `src/`, `assets/`, `config/` and the generated `manifest.json`.

Install it on a running server from the console:

```text
plugin install build/ayu/example_plugin-1.0.0.ayu
hello Ayu
stats
plugin disable example_plugin
```

Configuration lives in `config/config.json` inside the package; a server
operator overrides it by creating `plugins/data/example_plugin/config.json`.
