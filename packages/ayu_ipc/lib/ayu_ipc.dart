/// Wire protocol shared by the AyuMC plugin host and plugin workers.
///
/// Frames are length-prefixed binary records carrying a JSON payload; see
/// `docs/plugin-platform.md` for the normative description.
library;

export 'src/channel.dart';
export 'src/errors.dart';
export 'src/frame.dart';
export 'src/messages.dart';
export 'src/protocol.dart';
