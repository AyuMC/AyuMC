/// Official AyuMC plugin SDK.
///
/// A plugin is a Dart program whose `main` hands an [AyuPlugin] to
/// [runPlugin]. The program is compiled ahead of time, packaged into an
/// `.ayu` archive and executed by the server in a dedicated worker process.
/// Everything the plugin sees from the server arrives as plain data over the
/// IPC channel; there are no shared objects.
library;

export 'package:ayu_config/ayu_config.dart';
export 'package:ayu_ipc/ayu_ipc.dart'
    show
        CommandInvocation,
        CommandResult,
        ContractAvailability,
        DecisionRequest,
        DeliveryGap,
        EventEnvelope,
        IpcErrorCode,
        IpcException,
        PluginCapability,
        PluginDescriptor,
        PrimitiveEnvelope,
        Verdict;

export 'src/context.dart';
export 'src/listeners.dart';
export 'src/plugin.dart' hide attachContext;
export 'src/runner.dart'
    show Ayu, PluginExitCode, PluginRunnerOptions, runPlugin, sdkVersion;
