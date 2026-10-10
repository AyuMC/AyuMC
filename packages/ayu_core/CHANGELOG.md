## 1.0.0

- `AyuServer` owns a `PluginHost`; plugin commands are mirrored onto the
  console; `plugin ...` console command added.
- Removed in-process `PluginManager`, `PluginDiscovery`,
  `PluginDependencyResolver` and the YAML `PluginManifest` (superseded by
  `ayu_runtime` and `ayu_package`).
