import '../../domain/entities/server_status.dart';
import '../bloc/server_state.dart';

extension ServerStateExtensions on ServerState {
  bool get isLoading => this is ServerLoading;

  bool get isRunning {
    final currentStatus = status;
    return currentStatus != null &&
        (currentStatus.type == ServerStatusType.running ||
            currentStatus.type == ServerStatusType.starting);
  }

  bool get isStopped {
    final currentStatus = status;
    return currentStatus != null &&
        (currentStatus.type == ServerStatusType.stopped ||
            currentStatus.type == ServerStatusType.stopping);
  }

  ServerStatus? get status {
    if (this is ServerSuccess) {
      return (this as ServerSuccess).status;
    }
    return null;
  }
}
