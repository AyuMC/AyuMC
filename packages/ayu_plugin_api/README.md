# ayu_plugin_api

The SDK AyuMC plugins compile against. A plugin runs in its own process; this
package speaks the IPC protocol for it.

```dart
import 'package:ayu_plugin_api/ayu_plugin_api.dart';

void main() => runPlugin(MyPlugin());

final class MyPlugin extends AyuPlugin {
  @override
  Future<void> onEnable() async {
    await context.commands.register('hello', (call) => CommandResult.ok('Hi ${call.sender}'));
    await context.events.subscribe('player.join', (event) => context.log.info('${event.data}'));
  }
}
```

Declare the capabilities you use (`commands`, `events`, `config`) in
`ayu_plugin.yaml`; the host refuses undeclared ones. Never write to stdout
directly — it carries the protocol. `print()` is redirected to the log.

See `docs/plugin-platform.md` in the repository for the full contract.
