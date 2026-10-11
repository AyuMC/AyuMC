# Session Audit

Example plugin. It stays suspended until `session_events` is installed and active, then logs one join line and one leave line per play session.

It is not part of the base server. Package it with:

```text
dart run ../../packages/ayu_tool/bin/ayu.dart plugin package
```
