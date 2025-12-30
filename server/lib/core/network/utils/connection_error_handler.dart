import 'dart:io';

class ConnectionErrorHandler {
  ConnectionErrorHandler._();

  static bool isConnectionError(Object error) {
    if (error is SocketException) {
      return true;
    }

    final errorString = error.toString().toLowerCase();
    return errorString.contains('write failed') ||
        errorString.contains('broken pipe') ||
        errorString.contains('connection') ||
        errorString.contains('aborted');
  }
}

