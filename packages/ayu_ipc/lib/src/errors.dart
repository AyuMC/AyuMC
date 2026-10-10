/// Stable error codes carried inside structured protocol errors.
abstract final class IpcErrorCode {
  /// Framing, encoding or sequencing violation. The channel is closed.
  static const protocol = 'protocol';

  /// The peer did not answer a request within its deadline.
  static const timeout = 'timeout';

  /// The channel closed before a response arrived.
  static const closed = 'closed';

  /// The outgoing message exceeds the negotiated frame limit.
  static const messageTooLarge = 'message_too_large';

  /// Too many requests are in flight in one direction.
  static const tooManyRequests = 'too_many_requests';

  static const methodNotFound = 'method_not_found';
  static const invalidParams = 'invalid_params';

  /// The handler threw an unexpected error.
  static const internal = 'internal';

  /// The plugin did not declare the capability required by the request.
  static const capabilityDenied = 'capability_denied';

  /// The target is not in a state that can serve the request.
  static const unavailable = 'unavailable';

  /// The requested registration collides with an existing one.
  static const conflict = 'conflict';

  static const notFound = 'not_found';
}

/// A structured, serialisable error.
final class IpcError {
  const IpcError(this.code, this.message, {this.data});

  factory IpcError.fromJson(Object? json) {
    if (json is! Map) {
      return const IpcError(IpcErrorCode.protocol, 'malformed error object');
    }
    final code = json['c'];
    final message = json['m'];
    return IpcError(
      code is String ? code : IpcErrorCode.internal,
      message is String ? message : 'unknown error',
      data: json['d'],
    );
  }

  final String code;
  final String message;
  final Object? data;

  Map<String, Object?> toJson() => {
    'c': code,
    'm': message,
    if (data != null) 'd': data,
  };

  @override
  String toString() => '$code: $message';
}

/// Thrown by request APIs and by handlers that want to return a structured
/// error to the peer.
final class IpcException implements Exception {
  IpcException(this.error);

  IpcException.code(String code, String message, {Object? data})
    : error = IpcError(code, message, data: data);

  final IpcError error;

  String get code => error.code;
  String get message => error.message;

  @override
  String toString() => 'IpcException($error)';
}

/// Thrown by the frame decoder when the byte stream violates the framing
/// rules. The channel treats it as fatal.
final class FrameFormatException implements Exception {
  const FrameFormatException(this.message);

  final String message;

  @override
  String toString() => 'FrameFormatException: $message';
}
