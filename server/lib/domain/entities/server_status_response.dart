class ServerStatusResponse {
  final String version;
  final int protocol;
  final int maxPlayers;
  final int onlinePlayers;
  final String description;
  final String? favicon;

  const ServerStatusResponse({
    required this.version,
    required this.protocol,
    required this.maxPlayers,
    required this.onlinePlayers,
    required this.description,
    this.favicon,
  });

  Map<String, dynamic> toJson() {
    return {
      'version': {'name': version, 'protocol': protocol},
      'players': {'max': maxPlayers, 'online': onlinePlayers},
      'description': {'text': description},
      if (favicon != null) 'favicon': favicon,
    };
  }
}
