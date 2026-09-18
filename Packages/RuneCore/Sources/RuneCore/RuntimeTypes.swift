import Foundation
import RuneKernel

public struct RuntimeFileChange: Codable, Hashable, Identifiable, Sendable {
    public var id: String { callID + ":" + path }
    public let callID: String
    public let path: String
    public let before: String?
    public let after: String?
    public var applied = false
    public var reverted: Bool? = nil
}
public struct RuntimeApproval: Codable, Sendable {
    public let call: ToolCall
    public let reason: String
    public let recovery: Bool
    public let changes: [RuntimeFileChange]
    public var reviewError: String? = nil
}
public struct RuntimeMetadata: Codable, Sendable {
    public var workspaceID: UUID
    public var providerID: String
    public var modelID: String
    public var paused = false
    public var cancelled = false
    public var approval: RuntimeApproval?
    public var changes: [RuntimeFileChange] = []
    public var failure: String?
    public var partialText = ""
    public var hasPricing = false
    public var price: ModelPrice? = nil
    public var interruptedRequest = false
    public var inFlightModel: Bool? = nil
    public var suggestedBudgetMicroUSD: Int? = nil
}
public struct RuntimeSnapshot: Sendable {
    public let state: TurnState
    public let metadata: RuntimeMetadata
}
public enum RuntimeUpdate: Sendable {
    case snapshot(RuntimeSnapshot)
    case textPreview(String)
}
public enum RuntimeAction: Sendable {
    case proceed
    case cancel
    case undo(changeID: String)
    case resume
    case approve(callID: String)
    case reject(callID: String)
    case followUp(String)
    case raiseBudget(Int)
}
public struct RuntimeConfiguration: Sendable {
    public let sessionID: UUID
    public let workspaceID: UUID
    public let workspaceURL: URL
    public let artifactsURL: URL
    public let provider: ProviderConfig
    public let modelID: String
    public let secret: String
    public let trust: TrustDial
    public let price: ModelPrice?
    public let budgetMicroUSD: Int
    public let maxRounds: Int
    public let maxOutputTokens: Int
    public let allowPrivateNetwork: Bool
    public init(sessionID: UUID, workspaceID: UUID, workspaceURL: URL, artifactsURL: URL,
                provider: ProviderConfig, modelID: String, secret: String, trust: TrustDial = .collaborate,
                price: ModelPrice? = nil, budgetMicroUSD: Int = 3_000_000, maxRounds: Int = 8, maxOutputTokens: Int = 2048, allowPrivateNetwork: Bool = false) {
        self.sessionID = sessionID; self.workspaceID = workspaceID; self.workspaceURL = workspaceURL
        self.artifactsURL = artifactsURL; self.provider = provider; self.modelID = modelID
        self.secret = secret; self.trust = trust; self.price = price; self.budgetMicroUSD = budgetMicroUSD
        self.allowPrivateNetwork = allowPrivateNetwork
        self.maxRounds = max(1, min(32, maxRounds)); self.maxOutputTokens = max(128, min(8192, maxOutputTokens))
    }
}
public struct RuntimeFailure: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
