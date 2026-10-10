/// User-facing failure of a tool command. The message is printed as-is.
final class ToolException implements Exception {
  const ToolException(this.message, {this.details = const []});

  final String message;
  final List<String> details;

  @override
  String toString() => details.isEmpty ? message : '$message\n  ${details.join('\n  ')}';
}
