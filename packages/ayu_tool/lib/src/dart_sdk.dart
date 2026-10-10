import 'dart:convert';
import 'dart:io';

import 'package:ayu_package/ayu_package.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'tool_exception.dart';

/// The full Dart SDK needed to compile plugins. Only developers need it;
/// servers only need `dartaotruntime`.
final class DartSdk {
  const DartSdk({required this.dartExecutable, required this.version, required this.target});

  final String dartExecutable;
  final Version version;
  final RuntimeTarget target;

  static const environmentVariable = 'DART_SDK';

  /// Finds `dart` via `DART_SDK`, the running VM's directory, or `PATH`,
  /// and verifies it by running `dart --version`.
  static Future<DartSdk> locate({Map<String, String>? environment}) async {
    final env = environment ?? Platform.environment;
    final exe = Platform.isWindows ? 'dart.exe' : 'dart';
    final attempts = <String>[];
    final candidates = <String>{
      if (env[environmentVariable] != null) p.join(env[environmentVariable]!, 'bin', exe),
      p.join(p.dirname(Platform.resolvedExecutable), exe),
      exe,
    };
    for (final candidate in candidates) {
      final bare = !candidate.contains(p.separator) && !candidate.contains('/');
      if (!bare && !File(candidate).existsSync()) {
        attempts.add('$candidate: not found');
        continue;
      }
      try {
        final result = await Process.run(candidate, const ['--version'], stdoutEncoding: utf8, stderrEncoding: utf8);
        final banner = '${result.stdout}\n${result.stderr}';
        final match = RegExp(r'Dart SDK version:\s*(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)').firstMatch(banner);
        final target = RuntimeTarget.parseDartVersionBanner(banner);
        if (match == null || target == null) {
          attempts.add('$candidate: unrecognised --version output');
          continue;
        }
        return DartSdk(dartExecutable: candidate, version: Version.parse(match.group(1)!), target: target);
      } on ProcessException catch (e) {
        attempts.add('$candidate: ${e.message}');
      }
    }
    throw ToolException('no Dart SDK found; install it or set $environmentVariable', details: attempts);
  }
}
