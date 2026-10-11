/// Typed plugin configuration and message placeholders.
///
/// `.ayuconf` files are TOML 1.0. The Dart schema is the source of defaults
/// and validation. A successful load replaces one immutable snapshot; a
/// failed load leaves the previous snapshot in place.
library;

export 'src/errors.dart';
export 'src/file.dart';
export 'src/placeholder.dart';
export 'src/schema.dart';
