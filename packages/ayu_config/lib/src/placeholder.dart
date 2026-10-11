import 'errors.dart';

/// Where a message is being produced. A player placeholder cannot run in a console context.
enum PlaceholderContextKind { player, command, server }

/// Values already known to the caller. Nothing here is fetched over IPC.
final class PlaceholderContext {
  const PlaceholderContext({
    this.playerName,
    this.kind = PlaceholderContextKind.player,
  });

  final String? playerName;
  final PlaceholderContextKind kind;

  String requirePlayerName() {
    final name = playerName;
    if (name == null || kind == PlaceholderContextKind.server) {
      throw PlaceholderException(
        'placeholder needs a player name, which a ${kind.name} message does not have',
      );
    }
    return name;
  }
}

/// A named value a message template may insert. The same object is used to
/// allow the placeholder in a [MessageOption] and to resolve it later.
final class Placeholder<T> {
  const Placeholder({
    required this.id,
    required this.description,
    required this.resolve,
    this.contexts = const {PlaceholderContextKind.player, PlaceholderContextKind.command},
  });

  /// Namespaced id such as `session_audit.player.name`.
  final String id;
  final String description;
  final Set<PlaceholderContextKind> contexts;
  final T Function(PlaceholderContext context) resolve;

  static final idPattern = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$');

  String render(PlaceholderContext context) {
    if (!contexts.contains(context.kind)) {
      throw PlaceholderException('{$id} is not available in a ${context.kind.name} message');
    }
    final value = resolve(context);
    return '$value';
  }
}

final class _Hole {
  const _Hole(this.id);
  final String id;
}

/// One piece of a message: literal text or a placeholder id.
final class ParsedTemplate {
  ParsedTemplate(this.parts);

  final List<Object> parts;

  static final _token = RegExp(r'\{\{|\}\}|\{([a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+)\}|\{|\}');

  /// Parses [source]. [problems] receives syntax errors; the result is null when any were added.
  static ParsedTemplate? parse(String source, void Function(String message) problem) {
    final parts = <Object>[];
    var cursor = 0;
    var failed = false;
    for (final match in _token.allMatches(source)) {
      if (match.start > cursor) parts.add(source.substring(cursor, match.start));
      final token = match.group(0)!;
      if (token == '{{') {
        parts.add('{');
      } else if (token == '}}') {
        parts.add('}');
      } else if (token == '{' || token == '}') {
        problem('unbalanced "$token"');
        failed = true;
      } else {
        final id = match.group(1);
        if (id == null || !Placeholder.idPattern.hasMatch(id)) {
          problem('malformed placeholder "$token"');
          failed = true;
        } else {
          parts.add(_Hole(id));
        }
      }
      cursor = match.end;
    }
    if (cursor < source.length) parts.add(source.substring(cursor));
    if (failed) return null;
    return ParsedTemplate(parts);
  }

  Iterable<String> get placeholderIds => [for (final part in parts) if (part is _Hole) part.id];

  String render(PlaceholderContext context, Map<String, Placeholder<Object?>> allowed) {
    final buffer = StringBuffer();
    for (final part in parts) {
      if (part is! _Hole) {
        buffer.write(part);
        continue;
      }
      final placeholder = allowed[part.id];
      if (placeholder == null) {
        throw PlaceholderException('{${part.id}} is not allowed in this message');
      }
      buffer.write(placeholder.render(context));
    }
    return buffer.toString();
  }
}
