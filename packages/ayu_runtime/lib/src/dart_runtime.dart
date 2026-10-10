import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ayu_package/ayu_package.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'errors.dart';

/// A verified `dartaotruntime` executable.
final class DartAotRuntime {
  const DartAotRuntime({required this.executable, required this.version, required this.target});

  final String executable;

  /// SDK version that produced the runtime. Snapshots must match exactly.
  final Version version;
  final RuntimeTarget target;

  @override
  String toString() => 'dartaotruntime $version ($target) at $executable';
}

/// Outcome of running a short-lived process with a deadline.
final class BoundedProcessResult {
  const BoundedProcessResult({required this.exitCode, required this.stdout, required this.stderr, required this.timedOut});

  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;
}

/// Runs [executable] with [arguments] and waits at most [timeout]; the
/// process is killed on expiry. Never leaves a child behind.
Future<BoundedProcessResult> runBounded(
  String executable,
  List<String> arguments, {
  required Duration timeout,
  String? workingDirectory,
}) async {
  final process = await Process.start(executable, arguments, workingDirectory: workingDirectory, runInShell: false);
  final stdoutFuture = process.stdout.transform(utf8.decoder).join();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  var timedOut = false;
  int exitCode;
  try {
    exitCode = await process.exitCode.timeout(timeout);
  } on TimeoutException {
    timedOut = true;
    process.kill(ProcessSignal.sigkill);
    exitCode = await process.exitCode;
  }
  return BoundedProcessResult(
    exitCode: exitCode,
    stdout: await stdoutFuture,
    stderr: await stderrFuture,
    timedOut: timedOut,
  );
}

/// Finds and verifies a `dartaotruntime` binary.
///
/// Search order: explicit path, `AYUMC_DARTAOTRUNTIME`, the directory of the
/// running executable (covers `dart run` and a runtime shipped next to a
/// compiled server), then `PATH`.
final class DartRuntimeLocator {
  const DartRuntimeLocator({this.probeTimeout = const Duration(seconds: 10)});

  static const environmentVariable = 'AYUMC_DARTAOTRUNTIME';
  static const executableName = 'dartaotruntime';

  final Duration probeTimeout;

  Future<DartAotRuntime> locate({String? explicitPath, Map<String, String>? environment}) async {
    final env = environment ?? Platform.environment;
    final attempts = <String>[];
    for (final candidate in _candidates(explicitPath, env)) {
      final result = await probe(candidate);
      if (result.runtime != null) return result.runtime!;
      attempts.add('${result.candidate}: ${result.failure}');
    }
    throw PluginHostException(
      PluginHostErrorCode.runtimeUnavailable,
      'no usable dartaotruntime found; install the Dart SDK or set $environmentVariable to the dartaotruntime binary',
      details: attempts,
    );
  }

  /// Runs `<candidate> --version` and parses the banner.
  Future<RuntimeProbe> probe(String candidate) async {
    final isBarePath = !candidate.contains(p.separator) && !candidate.contains('/');
    if (!isBarePath && !File(candidate).existsSync()) {
      return RuntimeProbe._(candidate, failure: 'file does not exist');
    }
    final BoundedProcessResult result;
    try {
      result = await runBounded(candidate, const ['--version'], timeout: probeTimeout);
    } on ProcessException catch (e) {
      return RuntimeProbe._(candidate, failure: 'cannot execute (${e.message})');
    }
    if (result.timedOut) {
      return RuntimeProbe._(candidate, failure: '--version did not return within ${probeTimeout.inSeconds}s');
    }
    final banner = '${result.stdout}\n${result.stderr}';
    final version = parseVersionBanner(banner);
    final target = RuntimeTarget.parseDartVersionBanner(banner);
    if (version == null || target == null) {
      return RuntimeProbe._(candidate, failure: 'unrecognised --version output: ${banner.trim()}');
    }
    final executable = isBarePath ? candidate : p.normalize(p.absolute(candidate));
    return RuntimeProbe._(candidate, runtime: DartAotRuntime(executable: executable, version: version, target: target));
  }

  /// Extracts `3.13.4` from `Dart SDK version: 3.13.4 (stable) ...`.
  static Version? parseVersionBanner(String banner) {
    final match = RegExp(r'Dart SDK version:\s*(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)').firstMatch(banner);
    if (match == null) return null;
    try {
      return Version.parse(match.group(1)!);
    } on FormatException {
      return null;
    }
  }

  Iterable<String> _candidates(String? explicitPath, Map<String, String> env) sync* {
    final seen = <String>{};
    String? emit(String? path) => path != null && seen.add(path) ? path : null;

    final suffix = Platform.isWindows ? '.exe' : '';
    for (final candidate in [
      explicitPath,
      env[environmentVariable],
      p.join(p.dirname(Platform.resolvedExecutable), '$executableName$suffix'),
      '$executableName$suffix',
    ]) {
      final path = emit(candidate);
      if (path != null) yield path;
    }
  }
}

final class RuntimeProbe {
  const RuntimeProbe._(this.candidate, {this.runtime, this.failure});

  final String candidate;
  final DartAotRuntime? runtime;
  final String? failure;
}
