import 'dart:io';

enum TargetOs { windows, linux, macos }

enum TargetArch { x64, arm64 }

/// An operating-system/architecture pair identified as `<os>-<arch>`.
final class RuntimeTarget {
  const RuntimeTarget(this.os, this.arch);

  final TargetOs os;
  final TargetArch arch;

  String get id => '${os.name}-${arch.name}';

  /// Targets the platform ships and tests artifacts for.
  static const supported = <RuntimeTarget>[
    RuntimeTarget(TargetOs.windows, TargetArch.x64),
    RuntimeTarget(TargetOs.linux, TargetArch.x64),
  ];

  static bool isSupported(RuntimeTarget target) =>
      supported.any((t) => t == target);

  static RuntimeTarget? tryParse(String id) {
    final parts = id.split('-');
    if (parts.length != 2) return null;
    final os = TargetOs.values.where((v) => v.name == parts[0]).firstOrNull;
    final arch = TargetArch.values.where((v) => v.name == parts[1]).firstOrNull;
    if (os == null || arch == null) return null;
    return RuntimeTarget(os, arch);
  }

  /// Target of the running Dart VM, derived from `Platform.version`, whose
  /// tail reads `on "<os>_<arch>"`.
  static RuntimeTarget current() {
    final parsed = parseDartVersionBanner(Platform.version);
    if (parsed == null) {
      throw UnsupportedError(
          'cannot determine runtime target from "${Platform.version}"');
    }
    return parsed;
  }

  /// Parses the `on "<os>_<arch>"` tail of a Dart SDK version banner.
  static RuntimeTarget? parseDartVersionBanner(String banner) {
    final match = RegExp(r'on "([a-z]+)_([a-z0-9]+)"').firstMatch(banner);
    if (match == null) return null;
    return tryParse('${match.group(1)}-${match.group(2)}');
  }

  @override
  bool operator ==(Object other) =>
      other is RuntimeTarget && other.os == os && other.arch == arch;

  @override
  int get hashCode => Object.hash(os, arch);

  @override
  String toString() => id;
}
