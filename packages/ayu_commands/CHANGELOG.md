## 1.0.0

- Executors may be asynchronous; `execute` awaits them and logs failures.
- Added `unregister`, `has`, `commands`; names are case-insensitive;
  duplicate registration is an error.
