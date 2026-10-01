import Foundation

/// Every number the session depends on, in one place. `sizeCap` is the only user setting;
/// the rest are design constants (docs/designs/outflow-v1.md).
public struct SessionConfiguration: Sendable, Equatable {
    /// Selections above this need a confirmation. Settable in Settings > General.
    public var sizeCap: Int = 10_000
    /// The ElevenLabs Flash v2.5 input limit. Nothing above this is ever sent (D1).
    public static let hardMax = 40_000
    /// No first audio within this -> fall to Apple.
    public var firstChunkTimeout: Duration = .seconds(5)
    /// Claude must answer within this.
    public var transformTimeout: Duration = .seconds(20)
    public var hotkeyConfirmWindow: Duration = .seconds(5)
    public var menuConfirmWindow: Duration = .seconds(10)
    public var smartReadModel: String = "claude-haiku-4-5"
    public var briefMaxTokens: Int = 800

    public init() {}

    /// cleanup: ceil(input chars / 3) + 200, capped so the spoken text stays under hardMax (D12).
    public func maxTokens(for mode: SmartReadMode, inputCharacters: Int) -> Int {
        switch mode {
        case .brief:
            return briefMaxTokens
        case .cleanup:
            let wanted = Int((Double(inputCharacters) / 3).rounded(.up)) + 200
            let cap = Self.hardMax / 3
            return min(wanted, cap)
        }
    }
}
