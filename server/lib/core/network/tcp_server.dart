import 'dart:io';
import '../constants/network_constants.dart';
import 'connection_handler.dart';

class TcpServer {
  ServerSocket? _server;
  final List<ConnectionHandler> _connections = [];

  Future<void> start({
    String host = NetworkConstants.defaultHost,
    int port = NetworkConstants.defaultPort,
  }) async {
    if (_server != null) {
      throw Exception('Server is already running');
    }

    try {
      _server = await ServerSocket.bind(host, port);
      print('[Network] Listening on $host:$port');

      _server!.listen(_onClientConnected, onError: _onError, onDone: _onDone);
    } catch (e) {
      print('[Network] Failed to start server: $e');
      rethrow;
    }
  }

  void _onClientConnected(Socket client) {
    print(
      '[Network] Client connected: '
      '${client.remoteAddress.address}:${client.remotePort}',
    );

    final handler = ConnectionHandler(client);
    _connections.add(handler);
  }

  void _onError(Object error) {
    print('[Network] Server error: $error');
  }

  void _onDone() {
    print('[Network] Server socket closed');
  }

  Future<void> stop() async {
    if (_server == null) {
      return;
    }

    for (final connection in _connections) {
      connection.close();
    }
    _connections.clear();

    await _server!.close();
    _server = null;

    print('[Network] TCP Server stopped');
  }

  bool get isRunning => _server != null;
  int get connectionCount => _connections.length;
}
