## 1.0.0

- Plugin platform: `.ayu` package format, process-isolated workers under
  `dartaotruntime`, hot install/enable/disable/update/uninstall, versioned
  IPC protocol, plugin SDK and `ayu` developer tool.
- Server console gained `plugin ...` and `stop`; plugin commands are mirrored
  while their plugin is active.
- Removed the in-process `PluginManager`, YAML plugin discovery and the
  sample `TestPlugin`.
