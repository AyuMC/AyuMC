/// Why a holder wants a column. Lower index is served first.
enum TicketReason { p0, p1, p2, p3, p4 }

extension TicketReasonOrder on TicketReason {
  bool get isPlayerRequired =>
      this == TicketReason.p0 || this == TicketReason.p1;

  bool get isBackground =>
      this == TicketReason.p2 || this == TicketReason.p4;

  TicketReason get aged {
    return switch (this) {
      TicketReason.p4 => TicketReason.p3,
      TicketReason.p3 => TicketReason.p3,
      TicketReason.p2 => TicketReason.p1,
      TicketReason.p1 => TicketReason.p1,
      TicketReason.p0 => TicketReason.p0,
    };
  }
}

enum ChunkPhase { wanted, queued, reading, generating, resident, failed }
