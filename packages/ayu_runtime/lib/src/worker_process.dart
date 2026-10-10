import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ayu_ipc/ayu_ipc.dart';
import 'package:ayu_logging/ayu_logging.dart';

import 'runtime_options.dart';
import 'stderr_tail.dart';

/// How to start a worker. Arguments are passed verbatim to the OS; nothing
/// is interpolated into a shell.
final class WorkerLaunchSpec {
  const WorkerLaunchSpec({
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
    this.environment = const {},
  });

  final String executable;
  final List<String> arguments;
  final String workingDirectory;

  /// Added on top of the parent environment.
  final Map<String, String> environment;
}

enum TerminationOutcome {
  /// Worker exited on its own within the grace period.
  exitedGracefully,

  /// Worker ignored or missed the shutdown request and was killed.
  killed,

  /// The OS did not report the exit within the kill timeout. The process
  /// handle is abandoned; the host no longer routes anything to it.
  killFailed,

  alreadyExited,
}

/// Start-up or handshake failure, carrying everything the worker left
/// behind for diagnostics.
final class WorkerStartException implements Exception {
  const WorkerStartException(this.message, {this.exitCode, this.stderrTail = ''});

  final String message;
  final int? exitCode;
  final String stderrTail;

  @override
  String toString() {
    final buffer = StringBuffer('WorkerStartException: $message');
    if (exitCode != null) buffer.write(' (exit code $exitCode)');
    if (stderrTail.isNotEmpty) buffer.write('\n--- worker stderr ---\n$stderrTail');
    return buffer.toString();
  }
}

/// One supervised worker process plus its protocol channel.
///
/// Protocol frames travel over stdout/stdin; stderr is drained into a
/// bounded tail so a chatty or crashing worker can never block on a full
/// pipe. Every wait is bounded by [PluginRuntimeOptions].
final class WorkerProcess {
  WorkerProcess._(this._process, this.spec, this.options, this._log, this.debugName, this.hostVersion)
      : _stderr = StderrTail(options.stderrTailBytes) {
    _wire();
  }

  static Future<WorkerProcess> start(
    WorkerLaunchSpec spec, {
    required PluginRuntimeOptions options,
    required Logger log,
    required String debugName,
    required String hostVersion,
  }) async {
    final Process process;
    try {
      process = await Process.start(
        spec.executable,
        spec.arguments,
        workingDirectory: spec.workingDirectory,
        environment: spec.environment,
        runInShell: false,
      );
    } on ProcessException catch (e) {
      throw WorkerStartException('cannot start "${spec.executable}": ${e.message}');
    }
    return WorkerProcess._(process, spec, options, log, debugName, hostVersion);
  }

  final Process _process;
  final WorkerLaunchSpec spec;
  final PluginRuntimeOptions options;
  final Logger _log;
  final String debugName;
  final String hostVersion;
  final StderrTail _stderr;

  late final FrameChannel channel;
  late final StreamSubscription<List<int>> _stderrSubscription;
  final Completer<int> _exit = Completer<int>();
  final Completer<void> _stderrDone = Completer<void>();
  final Completer<HelloRequest> _handshake = Completer<HelloRequest>();
  Timer? _helloTimer;
  int? _exitCode;
  HelloRequest? _hello;

  /// How long an EOF on stdout waits for the exit code before the handshake
  /// is failed without it. The hello timer still bounds the total.
  static const _exitGraceAfterEof = Duration(seconds: 2);
  static const _stderrDrainGrace = Duration(milliseconds: 500);

  /// Handles requests other than `hello`. Set by the owner before init.
  RequestHandler? requestHandler;
  NotificationHandler? notificationHandler;

  /// Invoked once with the exit code, whatever the cause.
  void Function(int exitCode)? onExit;

  int get pid => _process.pid;
  bool get hasExited => _exitCode != null;
  int? get exitCode => _exitCode;
  Future<int> get exited => _exit.future;
  String get stderrTail => _stderr.toString();
  HelloRequest? get hello => _hello;

  void _wire() {
    _stderrSubscription = _process.stderr.listen(
      (chunk) {
        _stderr.add(chunk);
        final text = utf8.decode(chunk, allowMalformed: true).trimRight();
        if (text.isNotEmpty) _log.warn('[$debugName] stderr: $text');
      },
      onError: (Object error) {
        _log.warn('[$debugName] stderr read failed: $error');
        if (!_stderrDone.isCompleted) _stderrDone.complete();
      },
      onDone: () {
        if (!_stderrDone.isCompleted) _stderrDone.complete();
      },
      cancelOnError: true,
    );

    channel = FrameChannel(
      input: _process.stdout,
      output: IoFrameSink(_process.stdin),
      options: options.channelOptions,
      debugName: debugName,
    );
    channel.onRequest = _dispatchRequest;
    channel.onNotification = (method, params) {
      notificationHandler?.call(method, params);
    };
    channel.onUnhandledError = (error, stackTrace) {
      _log.error('[$debugName] handler error: $error\n$stackTrace');
    };

    _helloTimer = Timer(options.helloTimeout, () {
      _failHandshake(WorkerStartException(
        'worker did not complete the handshake within ${options.helloTimeout.inMilliseconds} ms',
        stderrTail: stderrTail,
      ));
    });

    unawaited(channel.done.then((_) async {
      if (_handshake.isCompleted) return;
      // An EOF usually means the process is exiting; wait briefly so the
      // failure carries the exit code and the last stderr output. A
      // protocol violation comes from a live process and fails at once.
      if (_exitCode == null && channel.closeReason?.kind == ChannelCloseKind.eof) {
        await _exit.future.timeout(_exitGraceAfterEof).then((_) {}, onError: (_) {});
      }
      _failHandshake(WorkerStartException(
        _exitCode == null
            ? 'channel closed before handshake (${channel.closeReason})'
            : 'worker exited before completing the handshake (${channel.closeReason})',
        exitCode: _exitCode,
        stderrTail: stderrTail,
      ));
    }));

    unawaited(_process.exitCode.then((code) async {
      _exitCode = code;
      _helloTimer?.cancel();
      await _stderrDone.future.timeout(_stderrDrainGrace).then((_) {}, onError: (_) {});
      _failHandshake(WorkerStartException(
        'worker exited before completing the handshake',
        exitCode: code,
        stderrTail: stderrTail,
      ));
      _exit.complete(code);
      onExit?.call(code);
    }));
  }

  Future<Object?> _dispatchRequest(String method, Object? params) {
    if (method == IpcMethod.hello) {
      if (_handshake.isCompleted) {
        throw IpcException.code(IpcErrorCode.protocol, 'duplicate hello');
      }
      final hello = HelloRequest.fromJson(params);
      final version = IpcProtocol.negotiate(hello.protocolVersions);
      if (version == null) {
        _failHandshake(WorkerStartException(
          'no common protocol version: worker offers ${hello.protocolVersions}, host speaks ${IpcProtocol.supportedVersions}',
        ));
        throw IpcException.code(IpcErrorCode.protocol, 'no common protocol version');
      }
      _hello = hello;
      _helloTimer?.cancel();
      _handshake.complete(hello);
      return Future.value(HelloResponse(
        protocolVersion: version,
        hostVersion: hostVersion,
        apiVersion: IpcProtocol.apiVersion,
        maxFrameBytes: options.maxFrameBytes,
      ).toJson());
    }
    final handler = requestHandler;
    if (handler == null) {
      throw IpcException.code(IpcErrorCode.unavailable, 'host is not accepting requests from this worker yet');
    }
    return Future.sync(() => handler(method, params));
  }

  void _failHandshake(WorkerStartException error) {
    if (_handshake.isCompleted) return;
    _helloTimer?.cancel();
    _handshake.completeError(error);
  }

  /// Completes when the worker said hello, or fails with
  /// [WorkerStartException] on timeout, exit or protocol error.
  Future<HelloRequest> awaitHello() => _handshake.future;

  /// Sends `init` and waits for `onEnable` to finish.
  Future<void> init(InitRequest request) async {
    try {
      await channel.request(IpcMethod.init, request.toJson(), options.initTimeout);
    } on IpcException catch (e) {
      throw WorkerStartException('initialisation failed: ${e.error}', exitCode: _exitCode, stderrTail: stderrTail);
    }
  }

  /// Asks the worker to stop; kills it when it does not exit in time.
  Future<TerminationOutcome> terminate({required String reason}) async {
    if (hasExited) return TerminationOutcome.alreadyExited;
    if (channel.isOpen) {
      // The exit code is the source of truth; the response is irrelevant.
      unawaited(channel
          .request(
            IpcMethod.shutdown,
            ShutdownRequest(reason: reason, graceMillis: options.shutdownGracePeriod.inMilliseconds).toJson(),
            options.shutdownGracePeriod,
          )
          .then((_) {}, onError: (_) {}));
    }
    if (await _waitForExit(options.shutdownGracePeriod)) {
      return TerminationOutcome.exitedGracefully;
    }
    _log.warn('[$debugName] did not exit within ${options.shutdownGracePeriod.inMilliseconds} ms; killing');
    return kill();
  }

  /// Kills the process immediately and waits (bounded) for the exit.
  Future<TerminationOutcome> kill() async {
    if (hasExited) return TerminationOutcome.alreadyExited;
    _process.kill(ProcessSignal.sigkill);
    if (await _waitForExit(options.killTimeout)) return TerminationOutcome.killed;
    _log.error('[$debugName] pid $pid still alive ${options.killTimeout.inMilliseconds} ms after kill');
    return TerminationOutcome.killFailed;
  }

  Future<bool> _waitForExit(Duration timeout) async {
    if (hasExited) return true;
    try {
      await _exit.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  /// Releases the channel and stream subscriptions. Safe to call twice.
  Future<void> dispose() async {
    await channel.close();
    await _stderrSubscription.cancel();
  }
}
