import 'play_session.dart';

/// Chooses which play sessions receive another session's entity packets.
///
/// The core evaluates this on its single isolate while handling the viewer's
/// socket. A later world or region split can replace the policy, and can move
/// ownership to another isolate only after a benchmark shows the fan-out is
/// worth the extra queue. This milestone does not do that split, and
/// [AllSessionsVisible] is not a chunk tracker.
abstract interface class PlayerVisibility {
  bool sees({required PlaySession viewer, required PlaySession subject});
}

/// Every announced play session sees every other session.
///
/// Cost grows with the number of sessions. It is the correct policy for the
/// single stone pad, not a claim that hundreds of mutually visible players
/// are cheap.
final class AllSessionsVisible implements PlayerVisibility {
  const AllSessionsVisible();

  @override
  bool sees({required PlaySession viewer, required PlaySession subject}) =>
      !identical(viewer, subject);
}
