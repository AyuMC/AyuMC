# ayu_core

Server core: lifecycle states, built-in console commands and the integration
of the plugin host (`ayu_runtime`). Plugins never run in this process.

- `AyuServer.start()` starts the `PluginHost`, restores enabled plugins and
  emits `server.started` to them.
- Commands plugins register are mirrored onto the console for as long as the
  plugin is active.
- `plugin list|info|install|enable|disable|update|uninstall` manages plugins
  at runtime.
