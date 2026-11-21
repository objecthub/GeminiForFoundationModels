// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import GeminiAPI

/// Executes generation requests against the Interactions API.
///
/// One executor is created per unique ``Configuration`` and reused. Heavy
/// resources (the URL session) live here, not on ``GeminiLanguageModel``.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct GeminiExecutor: LanguageModelExecutor {
  public typealias Model = GeminiLanguageModel

  public struct Configuration: Hashable, Sendable {
    public let model: GeminiModel
    public let auth: GeminiAuth
    public let thinkingLevel: GeminiModel.ThinkingLevel?
    public let thoughtSummaries: Bool
    public let builtInTools: Set<GeminiBuiltInTool>
    public let baseURL: URL
    public let apiVersion: String
    public let timeout: TimeInterval

    public init(
      model: GeminiModel,
      auth: GeminiAuth,
      thinkingLevel: GeminiModel.ThinkingLevel? = nil,
      thoughtSummaries: Bool = true,
      builtInTools: Set<GeminiBuiltInTool> = [],
      baseURL: URL,
      apiVersion: String = "v1beta",
      timeout: TimeInterval
    ) {
      self.model = model
      self.auth = auth
      self.thinkingLevel = thinkingLevel
      self.thoughtSummaries = thoughtSummaries
      self.builtInTools = builtInTools
      self.baseURL = baseURL
      self.apiVersion = apiVersion
      self.timeout = timeout
    }
  }

  /// How often a turn the API pauses (`requires_continuation`) is resumed.
  static let maxContinuations = 8

  private let configuration: Configuration
  private let transport: any HTTPTransport

  public init(configuration: Configuration) throws {
    self.init(configuration: configuration, transport: Self.makeTransport(timeout: configuration.timeout))
  }

  /// Injects the transport so the executor can be exercised without a
  /// network.
  init(configuration: Configuration, transport: any HTTPTransport) {
    self.configuration = configuration
    self.transport = transport
  }

  /// A transport honoring the configured request timeout.
  static func makeTransport(timeout: TimeInterval) -> URLSessionTransport {
    let sessionConfig = URLSessionConfiguration.default
    sessionConfig.timeoutIntervalForRequest = timeout
    return URLSessionTransport(session: URLSession(configuration: sessionConfig))
  }

  public func respond(
    to request: LanguageModelExecutorGenerationRequest,
    model: GeminiLanguageModel,
    streamingInto channel: LanguageModelExecutorGenerationChannel
  ) async throws {
    do {
      let client = try makeClient()
      let built = try RequestBuilder.build(
        from: request,
        model: configuration.model,
        thinkingLevel: configuration.thinkingLevel,
        thoughtSummaries: configuration.thoughtSummaries,
        builtInTools: configuration.builtInTools
      )
      var translator = EventTranslator(structured: built.isStructured)
      var body = built.body.objectValue ?? [:]
      var continuations = 0
      while true {
        try await translator.translate(client.stream(.object(body)), into: channel)
        guard translator.status == "requires_continuation",
          let token = translator.continuationToken,
          continuations < Self.maxContinuations
        else { break }
        try Task.checkCancellation()
        continuations += 1
        body["continuation_token"] = .string(token)
      }
      switch translator.status {
      case "failed":
        let error = translator.errors.first ?? [:]
        throw APIError(
          status: nil,
          code: error["code"]?.stringValue ?? "failed",
          message: error["message"]?.stringValue ?? "The interaction failed."
        )
      case "incomplete" where built.isStructured:
        throw GeminiError.incompleteResponse
      default:
        break
      }
    } catch {
      throw ErrorMapper.map(error)
    }
  }

  public func prewarm(model: GeminiLanguageModel, transcript: Transcript) {
    // Nothing to set up ahead of the first request.
  }

  /// A client authenticated per the configuration. Throws
  /// ``GeminiError/missingCredential`` for an empty API key.
  func makeClient() throws -> GeminiClient {
    GeminiClient(
      configuration: .init(
        baseURL: configuration.baseURL,
        apiVersion: configuration.apiVersion,
        headers: try configuration.auth.headers(),
        // Thinking can keep a stream quiet for a while, so the limit is
        // generous: it only turns a stalled stream into an error.
        idleTimeout: configuration.timeout * 3
      ),
      transport: transport
    )
  }
}
