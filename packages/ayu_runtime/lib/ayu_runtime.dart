/// Host-side plugin platform: installs `.ayu` packages, runs each plugin in
/// a supervised `dartaotruntime` worker process and owns every host-side
/// registration a plugin makes.
library;

export 'package:ayu_ipc/ayu_ipc.dart' show CommandResult, CommandSpec;
export 'package:ayu_package/ayu_package.dart'
    show
        PackageException,
        PackageErrorCode,
        PackageLimits,
        PluginManifest,
        RuntimeTarget;

export 'src/dart_runtime.dart';
export 'src/errors.dart';
export 'src/host_events.dart';
export 'src/host_registry.dart';
export 'src/plugin_host.dart';
export 'src/plugin_snapshot.dart';
export 'src/plugin_state.dart';
export 'src/plugin_store.dart' show InstalledPluginRecord, PluginStoreLayout;
export 'src/runtime_options.dart';
export 'src/worker_launcher.dart';
export 'src/worker_process.dart'
    show TerminationOutcome, WorkerLaunchSpec, WorkerStartException;
