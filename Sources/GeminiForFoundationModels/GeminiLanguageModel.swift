// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import GeminiAPI
import UniformTypeIdentifiers

/// Gemini as a Foundation Models server-side language model.
///
/// ```swift
/// let model = try GeminiLanguageModel(name: .gemini3_8Flash, auth: .apiKey("..."))
/// let session = LanguageModelSession(model: model)
/// let response = try await session.respond(to: "Plan a 4-day trip to Buenos Aires")
/// ```
///
/// Requests go to the Interactions API and are stateless: nothing is stored
/// on Google's side, and the session's transcript is the conversation.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct GeminiLanguageModel: Sendable {
  public let model: GeminiModel
  public let thinkingLevel: GeminiModel.ThinkingLevel?
  public let thoughtSummaries: Bool
  public let builtInTools: Set<GeminiBuiltInTool>
  public let baseURL: URL
  public let timeout: TimeInterval
  let auth: GeminiAuth

  /// - Parameters:
  ///   - name: The Gemini model. Use a constant (`.gemini3_8Flash`,
  ///     `.gemini4Neon`, …) or a ``GeminiModel`` with explicit capabilities.
  ///   - auth: `.apiKey` to call the API directly; `.proxied` with a custom
  ///     `baseURL` to route through a relay that adds the credential.
  ///   - thinkingLevel: A fixed `thinking_level` for every request. It takes
  ///     precedence over the framework's per-request reasoning hint and must
  ///     be a level the model accepts, which is checked here. `nil` lets the
  ///     hint (or the model's default) decide.
  ///   - thoughtSummaries: Whether the model returns summaries of its
  ///     thoughts, which appear as reasoning entries in the transcript.
  ///   - builtInTools: Tools that run on Google's infrastructure (search,
  ///     URL context, code execution). Distinct from the framework's
  ///     `tools:`, which the framework invokes client-side.
  ///   - baseURL: API endpoint. Credentials are only ever sent to its scheme,
  ///     host, and port: a redirect elsewhere fails the request.
  ///   - timeout: Request timeout in seconds.
  /// - Throws: ``GeminiError/unsupportedThinkingLevel(model:level:)`` when
  ///   `thinkingLevel` isn't one the model accepts.
  public init(
    name: GeminiModel,
    auth: GeminiAuth,
    thinkingLevel: GeminiModel.ThinkingLevel? = nil,
    thoughtSummaries: Bool = true,
    builtInTools: Set<GeminiBuiltInTool> = [],
    baseURL: URL = GeminiLanguageModel.defaultBaseURL,
    timeout: TimeInterval = 120
  ) throws {
    if let thinkingLevel, !name.capabilities.thinkingLevels.contains(thinkingLevel) {
      throw GeminiError.unsupportedThinkingLevel(model: name.id, level: thinkingLevel)
    }
    self.model = name
    self.auth = auth
    self.thinkingLevel = thinkingLevel
    self.thoughtSummaries = thoughtSummaries
    self.builtInTools = builtInTools
    self.baseURL = baseURL
    self.timeout = timeout
  }

  public static let defaultBaseURL = URL(string: "https://generativelanguage.googleapis.com")!
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
extension GeminiLanguageModel: LanguageModel {
  public typealias Executor = GeminiExecutor

  /// Derived from the model's ``GeminiModel/Capabilities`` so the framework
  /// only routes work the bridge will actually send.
  public var capabilities: LanguageModelCapabilities {
    var capabilities: [LanguageModelCapabilities.Capability] = [.toolCalling]
    if model.capabilities.imageInput { capabilities.append(.vision) }
    if !model.capabilities.thinkingLevels.isEmpty { capabilities.append(.reasoning) }
    if model.capabilities.structuredOutput { capabilities.append(.guidedGeneration) }
    return LanguageModelCapabilities(capabilities)
  }

  public var executorConfiguration: GeminiExecutor.Configuration {
    .init(
      model: model,
      auth: auth,
      thinkingLevel: thinkingLevel,
      thoughtSummaries: thoughtSummaries,
      builtInTools: builtInTools,
      baseURL: baseURL,
      timeout: timeout
    )
  }

  /// PDFs, images, audio, and video, as far as the model takes them.
  nonisolated(nonsending) public func supportsDataAttachmentType(_ type: UTType) async throws -> Bool {
    let capabilities = model.capabilities
    switch GeminiMedia.blockType(for: type) {
    case "document": return capabilities.documentInput
    case "image": return capabilities.imageInput
    case "audio": return capabilities.audioInput
    case "video": return capabilities.videoInput
    default: return false
    }
  }
}

/// A model of the Gemini API's catalog.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct GeminiModelInfo: Sendable, Hashable {
  /// The model ID, e.g. `gemini-3.8-flash`.
  public let id: String
  public let displayName: String
  public let description: String
  public let inputTokenLimit: Int?
  public let outputTokenLimit: Int?
  /// Whether the model thinks.
  public let thinking: Bool
  /// API methods the model supports, e.g. `generateContent`.
  public let supportedGenerationMethods: [String]
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
extension GeminiModel {
  /// The models the Gemini API offers.
  public static func available(
    auth: GeminiAuth,
    baseURL: URL = GeminiLanguageModel.defaultBaseURL,
    timeout: TimeInterval = 60
  ) async throws -> [GeminiModelInfo] {
    try await available(auth: auth, baseURL: baseURL, transport: GeminiExecutor.makeTransport(timeout: timeout))
  }

  static func available(
    auth: GeminiAuth,
    baseURL: URL,
    transport: any HTTPTransport
  ) async throws -> [GeminiModelInfo] {
    do {
      let client = GeminiClient(
        configuration: .init(baseURL: baseURL, headers: try auth.headers()),
        transport: transport
      )
      return try await client.models().map { model in
        let name = model["name"]?.stringValue ?? ""
        return GeminiModelInfo(
          id: name.hasPrefix("models/") ? String(name.dropFirst(7)) : name,
          displayName: model["displayName"]?.stringValue ?? name,
          description: model["description"]?.stringValue ?? "",
          inputTokenLimit: model["inputTokenLimit"]?.intValue,
          outputTokenLimit: model["outputTokenLimit"]?.intValue,
          thinking: model["thinking"]?.boolValue ?? false,
          supportedGenerationMethods: (model["supportedGenerationMethods"]?.arrayValue ?? [])
            .compactMap(\.stringValue)
        )
      }
    } catch {
      throw ErrorMapper.map(error)
    }
  }
}
