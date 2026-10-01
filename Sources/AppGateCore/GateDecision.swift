/// What to show, and which input decided it.
///
/// `evaluate` returns this and not a bare ``GateState`` because two different
/// paths resolve to ``GateState/open``. "Nothing applied" and "a wall applied
/// and was released" need different responses from the host, and only the
/// diagnosis tells them apart.
public struct GateDecision: Equatable, Sendable {
    public let state: GateState
    public let diagnosis: GateDiagnosis

    public init(state: GateState, diagnosis: GateDiagnosis) {
        self.state = state
        self.diagnosis = diagnosis
    }

    /// No gate, and nothing applied. A store holds this before its first read.
    public static let open = GateDecision(state: .open, diagnosis: .noGateApplies)
}
