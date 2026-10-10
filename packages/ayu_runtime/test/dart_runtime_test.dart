import 'dart:io';

import 'package:ayu_runtime/ayu_runtime.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('parses the Dart SDK version banner', () {
    expect(
      DartRuntimeLocator.parseVersionBanner('Dart SDK version: 3.13.4 (stable) (Tue Sep 15 01:01:15 2026 -0700) on "windows_x64"'),
      Version(3, 13, 4),
    );
    expect(DartRuntimeLocator.parseVersionBanner('Dart SDK version: 3.14.0-123.0.dev (dev) on "linux_x64"'), Version.parse('3.14.0-123.0.dev'));
    expect(DartRuntimeLocator.parseVersionBanner('garbage'), isNull);
  });

  test('probing a missing path fails with a reason instead of throwing', () async {
    final probe = await const DartRuntimeLocator().probe('${Directory.systemTemp.path}/definitely-missing-dartaotruntime');
    expect(probe.runtime, isNull);
    expect(probe.failure, contains('does not exist'));
  });

  test('locate reports every attempted candidate when nothing is found', () async {
    final locator = const DartRuntimeLocator();
    await expectLater(
      locator.locate(explicitPath: '${Directory.systemTemp.path}/nope', environment: const {}),
      throwsA(isA<PluginHostException>()
          .having((e) => e.code, 'code', PluginHostErrorCode.runtimeUnavailable)
          .having((e) => e.details, 'details', isNotEmpty)),
    );
  }, skip: siblingAotRuntime != null ? 'a real dartaotruntime sits next to the VM and would be found' : null);

  test('locate finds the runtime shipped with the SDK and reads its version', () async {
    final runtime = await const DartRuntimeLocator().locate(explicitPath: siblingAotRuntime);
    expect(runtime.version, jitRuntime.version);
    expect(runtime.target, RuntimeTarget.current());
    expect(File(runtime.executable).existsSync(), isTrue);
  }, skip: siblingAotRuntime == null ? 'dartaotruntime not available next to the Dart VM' : null);

  test('runBounded kills a process that outlives its deadline', () async {
    final watch = Stopwatch()..start();
    final result = await runBounded(dartExecutable, [fixture('worker_silent')], timeout: const Duration(seconds: 2));
    expect(result.timedOut, isTrue);
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
  });
}
