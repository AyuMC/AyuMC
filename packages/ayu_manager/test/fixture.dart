import 'dart:io';
import 'dart:typed_data';

import 'package:ayu_package/ayu_package.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

Future<File> writePackage(
  Directory dir, {
  required String id,
  String version = '1.0.0',
  PackageType type = PackageType.plugin,
  String api = '^1.0.0',
  String? description,
  List<String> profiles = const [],
  List<EventContractSpec> provides = const [],
  List<ContractRequirement> events = const [],
  List<DependencySpec> dependencies = const [],
  Set<String> capabilities = const {},
  RuntimeTarget? target,
  Version? dartSdk,
  String? fileName,
}) async {
  final bytes = Uint8List.fromList(
    'placeholder artifact for $id $version'.codeUnits,
  );
  final artifact = PackageWriter.describeArtifact(
    target: target ?? RuntimeTarget.current(),
    bytes: bytes,
    dartSdk:
        dartSdk ??
        Version.parse(
          RegExp(r'^(\d+\.\d+\.\d+)').firstMatch(Platform.version)!.group(1)!,
        ),
  );
  final manifest = PluginManifest(
    id: id,
    name: 'Package $id',
    version: Version.parse(version),
    api: VersionConstraint.parse(api),
    description: description,
    entryPoint: 'bin/main.dart',
    artifacts: {artifact.target.id: artifact},
    dependencies: dependencies,
    capabilities: capabilities,
    packageType: type,
    profiles: profiles,
    provides: provides,
    events: events,
  );
  final file = File(p.join(dir.path, fileName ?? '$id-$version.ayu'));
  await PackageWriter.write(
    output: file,
    manifest: manifest,
    entries: {
      artifact.path: bytes,
      'bin/main.dart': Uint8List.fromList('void main() {}'.codeUnits),
    },
  );
  return file;
}

EventContractSpec sampleContract(String id) => EventContractSpec(
  id: id,
  version: Version.parse('1.0.0'),
  delivery: const DeliverySpec(),
);

/// Other OS than the one running the test, so the package has no local artifact.
RuntimeTarget get foreignTarget =>
    RuntimeTarget.current().os == TargetOs.windows
    ? const RuntimeTarget(TargetOs.linux, TargetArch.x64)
    : const RuntimeTarget(TargetOs.windows, TargetArch.x64);
