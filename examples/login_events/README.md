# Login Events

Optional event pack for `AyuMC-1.8.9-release`. It is not part of the base
server. It observes the internal primitive `core.session.login` (a client
sent the 1.8.9 login-start packet) and publishes `session.login_started`.

That contract means a login packet arrived. The server does not yet enter
the play state.

```sh
dart pub get
dart run ../../packages/ayu_tool/bin/ayu.dart plugin package
```

On the server console: `event install build/ayu/login_events-1.0.0.ayu`.
