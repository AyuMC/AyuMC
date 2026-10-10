/// Classification of package failures. Stable so hosts and UIs can branch
/// on it.
enum PackageErrorCode {
  notFound,
  tooLarge,
  invalidArchive,
  unsupportedArchiveFeature,
  unsafeEntryPath,
  duplicateEntry,
  tooManyEntries,
  entryTooLarge,
  manifestMissing,
  manifestInvalid,
  artifactMissing,
  artifactMismatch,
  extractionFailed,
  destinationNotEmpty,
  ioError,
}

final class PackageException implements Exception {
  const PackageException(this.code, this.message, {this.problems = const []});

  final PackageErrorCode code;
  final String message;

  /// Detailed findings, e.g. every manifest field that failed validation.
  final List<String> problems;

  @override
  String toString() {
    if (problems.isEmpty) return 'PackageException(${code.name}): $message';
    return 'PackageException(${code.name}): $message\n  - ${problems.join('\n  - ')}';
  }
}
