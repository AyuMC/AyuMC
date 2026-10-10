/// Server profiles: the identity a running AyuMC presents to packages and
/// the protocol implementation it loads.
library;

import 'dart:convert';
import 'dart:io';

/// A supported game/protocol combination. Packages declare the profile ids
/// they support; the host refuses packages that do not list the active one.
final class ServerProfile {
  const ServerProfile({
    required this.id,
    required this.gameVersion,
    required this.protocolVersion,
    required this.description,
  });

  /// Stable identifier such as `AyuMC-1.8.9-release`.
  final String id;

  /// Minecraft Java Edition version string shown to clients.
  final String gameVersion;

  /// Protocol number negotiated during the handshake.
  final int protocolVersion;
  final String description;

  @override
  String toString() => '$id (Minecraft $gameVersion, protocol $protocolVersion)';
}

/// Profiles this build of AyuMC ships. Adding a profile means adding a
/// protocol implementation package and an entry here.
abstract final class ProfileCatalog {
  static const release189 = ServerProfile(
    id: 'AyuMC-1.8.9-release',
    gameVersion: '1.8.9',
    protocolVersion: 47,
    description: 'Minecraft Java Edition 1.8.9 (protocol 47). First supported release profile.',
  );

  static const all = <ServerProfile>[release189];

  static const defaultProfile = release189;

  static ServerProfile? byId(String id) => all.where((p) => p.id == id).firstOrNull;
}

/// The selected profile, persisted in a small JSON file. Selection takes
/// effect when the server starts; a running server keeps its profile.
final class ProfileSelection {
  const ProfileSelection(this.file);

  static const _key = 'profile';

  final File file;

  Future<ServerProfile> load() async {
    if (!await file.exists()) return ProfileCatalog.defaultProfile;
    final Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on FormatException catch (e) {
      throw ProfileException('${file.path} is not valid JSON: ${e.message}');
    }
    if (decoded is! Map) throw ProfileException('${file.path} must contain a JSON object');
    final id = decoded[_key];
    if (id == null) return ProfileCatalog.defaultProfile;
    if (id is! String) throw ProfileException('"$_key" in ${file.path} must be a string');
    final profile = ProfileCatalog.byId(id);
    if (profile == null) {
      throw ProfileException(
          'unknown profile "$id" in ${file.path}; available: ${ProfileCatalog.all.map((p) => p.id).join(', ')}');
    }
    return profile;
  }

  /// Writes the selection through a temporary file so a crash cannot leave
  /// a truncated file. Other keys in the file are preserved.
  Future<void> save(ServerProfile profile) async {
    Map<String, Object?> existing = {};
    if (await file.exists()) {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) existing = decoded.cast<String, Object?>();
    }
    existing[_key] = profile.id;
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(const JsonEncoder.withIndent('  ').convert(existing), flush: true);
    await temp.rename(file.path);
  }
}

final class ProfileException implements Exception {
  const ProfileException(this.message);

  final String message;

  @override
  String toString() => 'ProfileException: $message';
}
