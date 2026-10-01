// AppGateCore holds the pure logic: version parsing and comparison, the gate
// state, the precedence rule, the OS-install check, the suppression rules and
// the `Decodable` config envelope.
//
// It imports Foundation only and uses no URLSession, no UserDefaults and no
// clock. The evaluator takes everything it needs as parameters, so the module
// is tested on a macOS host with no simulator and no network.
