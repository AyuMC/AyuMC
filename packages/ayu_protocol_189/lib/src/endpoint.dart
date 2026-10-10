import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'buffer.dart';
import 'primitives.dart';

/// Why a connection was closed. Useful in tests and logs.
enum ProtocolCloseReason { completed, malformed, unsupportedState, remoteClosed }

typedef PrimitiveListener = void Function(String id, Map<String, Object?> data);

/// Accepts Minecraft 1.8.9 handshakes and answers status ping. A login start
/// is reported as [ProtocolPrimitive.login] and the connection is then
/// closed; play state is intentionally not implemented.
final class ProtocolEndpoint {
  ProtocolEndpoint({
    required this.versionName,
    required this.protocolVersion,
    required this.description,
    this.maxPlayers = 5000,
    this.onPrimitive,
    this.maxFrameBytes = 32767,
  });

  final String versionName;
  final int protocolVersion;
  final String description;
  final int maxPlayers;
  final PrimitiveListener? onPrimitive;
  final int maxFrameBytes;

  ServerSocket? _server;
  final Set<_Connection> _connections = {};
  int _online = 0;

  int get port => _server?.port ?? 0;
  int get connections => _connections.length;

  Future<void> bind({InternetAddress? address, int port = 25565}) async {
    if (_server != null) throw StateError('endpoint already bound');
    _server = await ServerSocket.bind(address ?? InternetAddress.loopbackIPv4, port);
    _server!.listen(_accept, onError: (Object _) {});
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close();
    for (final connection in List.of(_connections)) {
      await connection.close(ProtocolCloseReason.completed);
    }
  }

  void _accept(Socket socket) {
    final connection = _Connection(socket, this);
    _connections.add(connection);
    _online++;
    connection.done.future.whenComplete(() {
      _connections.remove(connection);
      _online--;
    });
  }

  void _emit(String id, Map<String, Object?> data) => onPrimitive?.call(id, data);

  Map<String, Object?> get _status => {
        'version': {'name': versionName, 'protocol': protocolVersion},
        'players': {'max': maxPlayers, 'online': _online},
        'description': {'text': description},
      };
}

enum _Phase { handshake, status, login }

final class _Connection {
  _Connection(this._socket, this._endpoint) {
    _subscription = _socket.listen(_onData, onError: (_) => close(ProtocolCloseReason.remoteClosed), onDone: () => close(ProtocolCloseReason.remoteClosed));
  }

  final Socket _socket;
  final ProtocolEndpoint _endpoint;
  final PacketBuffer _inbound = PacketBuffer();
  late final StreamSubscription<List<int>> _subscription;
  final Completer<void> done = Completer<void>();
  _Phase _phase = _Phase.handshake;
  bool _closed = false;
  Future<void>? _shutdown;

  void _onData(List<int> chunk) {
    _inbound.add(chunk);
    try {
      while (!_closed) {
        final frame = _inbound.readFrame(maxFrameBytes: _endpoint.maxFrameBytes);
        if (frame == null) return;
        _handle(PacketBuffer()..add(frame));
      }
    } on PacketFormatException {
      close(ProtocolCloseReason.malformed);
    }
  }

  void _handle(PacketBuffer packet) {
    final id = packet.readVarInt();
    switch (_phase) {
      case _Phase.handshake:
        if (id != 0x00) {
          close(ProtocolCloseReason.malformed);
          return;
        }
        final announced = packet.readVarInt();
        final address = packet.readString();
        final port = packet.readUnsignedShort();
        final next = packet.readVarInt();
        _endpoint._emit(ProtocolPrimitive.handshake, {
          'protocol': announced,
          'address': address,
          'port': port,
          'nextState': next,
        });
        if (announced != _endpoint.protocolVersion) {
          close(ProtocolCloseReason.unsupportedState);
          return;
        }
        if (next == 1) {
          _phase = _Phase.status;
        } else if (next == 2) {
          _phase = _Phase.login;
        } else {
          close(ProtocolCloseReason.unsupportedState);
        }
      case _Phase.status:
        if (id == 0x00) {
          _socket.add(encodePacket(0x00, encodeString(jsonEncode(_endpoint._status))));
        } else if (id == 0x01) {
          _socket.add(encodePacket(0x01, encodeLong(packet.readLong())));
        } else {
          close(ProtocolCloseReason.malformed);
        }
      case _Phase.login:
        if (id != 0x00) {
          close(ProtocolCloseReason.malformed);
          return;
        }
        final name = packet.readString(maxBytes: 16);
        _endpoint._emit(ProtocolPrimitive.login, {'name': name, 'protocol': _endpoint.protocolVersion});
        close(ProtocolCloseReason.completed,
            farewell: encodePacket(0x00, encodeString(jsonEncode({'text': 'AyuMC has no play session yet'}))));
    }
  }

  /// Closes after the current socket callback returns, so cancelling the
  /// subscription cannot deadlock the read that triggered it. [farewell] is
  /// flushed before the socket is closed.
  Future<void> close(ProtocolCloseReason _, {Uint8List? farewell}) {
    _closed = true;
    return _shutdown ??= _shutdownNow(farewell);
  }

  Future<void> _shutdownNow(Uint8List? farewell) async {
    await Future<void>.delayed(Duration.zero);
    if (farewell != null) {
      _socket.add(farewell);
      try {
        await _socket.flush().timeout(const Duration(milliseconds: 500));
      } on Object {
        // The peer may already be gone, or the flush outlived its budget.
      }
    }
    // destroy() returns immediately. Waiting for the socket subscription to
    // cancel can stall on Windows after the peer has already finished.
    _socket.destroy();
    unawaited(_subscription.cancel().then((_) {}, onError: (_, _) {}));
    if (!done.isCompleted) done.complete();
  }
}
