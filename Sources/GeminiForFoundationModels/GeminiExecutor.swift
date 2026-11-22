// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import GeminiAPI
import Synchronization

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
    public let replaysEarlierThoughts: Bool
    public let retry: GeminiRetryPolicy
    public let baseURL: URL
    public let apiVersion: String
    public let timeout: TimeInterval

    public init(
      model: GeminiModel,
      auth: GeminiAuth,
      thinkingLevel: GeminiModel.ThinkingLevel? = nil,
      thoughtSummaries: Bool = true,
      builtInTools: Set<GeminiBuiltInTool> = [],
      replaysEarlierThoughts: Bool = false,
      retry: GeminiRetryPolicy = .default,
      baseURL: URL,
      apiVersion: String = "v1beta",
      timeout: TimeInterval
    ) {
      self.model = model
      self.auth = auth
      self.thinkingLevel = thinkingLevel
      self.thoughtSummaries = thoughtSummaries
      self.builtInTools = builtInTools
      self.replaysEarlierThoughts = replaysEarlierThoughts
      self.retry = retry
      self.baseURL = baseURL
      self.apiVersion = apiVersion
      self.timeout = timeout
    }
  }

  /// How often a turn the API pauses (`requires_continuation`) is resumed.
  static let maxContinuations = 8

  private let configuration: Configuration
  private let transport: any HTTPTransport
  /// Waits before a retry; injectable so tests don't sleep.
  private let sleep: @Sendable (TimeInterval) async throws -> Void
  /// The jitter factor of a backoff.
  private let jitter: @Sendable () -> Double

  public init(configuration: Configuration) throws {
    self.init(configuration: configuration, transport: Self.makeTransport(timeout: configuration.timeout))
  }

  /// Injects the transport (and the clock) so the executor can be exercised
  /// without a network.
  init(
    configuration: Configuration,
    transport: any HTTPTransport,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
    jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.75...1.25) }
  ) {
    self.configuration = configuration
    self.transport = transport
    self.sleep = sleep
    self.jitter = jitter
  }

  /// A transport honoring the configured request timeout, on the session
  /// shared by all requests with that timeout.
  static func makeTransport(timeout: TimeInterval) -> URLSessionTransport {
    URLSessionTransport.shared(timeout: timeout)
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
        builtInTools: configuration.builtInTools,
        earlierThoughts: configuration.replaysEarlierThoughts
      )
      let body = built.body.objectValue ?? [:]
      let policy = configuration.retry
      var retries = 0
      var attempt = 1
      while true {
        var translator = EventTranslator(structured: built.isStructured, attempt: attempt)
        let started = Flag()
        do {
          try await run(body, client: client, translator: &translator, into: channel, started: started)
          return
        } catch {
          // Retried only while nothing reached the session.
          guard !started.isSet, !Task.isCancelled, !(error is CancellationError),
            retries < policy.maxRetries, GeminiRetryPolicy.isTemporary(error)
          else { throw error }
          let delay =
            (error as? APIError)?.retryDelay ?? GeminiRetryPolicy.backoff(retries + 1, jitter: jitter())
          // A server asking for a longer wait gets its answer to the app,
          // with the reset time, instead of a call that hangs.
          guard delay <= policy.maxDelay else { throw error }
          try await sleep(delay)
          retries += 1
          attempt += 1
        }
      }
    } catch {
      throw ErrorMapper.map(error)
    }
  }

  /// Streams one attempt: the interaction and the continuations the API asks
  /// for. Throws for an interaction that failed, or a structured response
  /// that is incomplete.
  private func run(
    _ initial: JSONObject,
    client: GeminiClient,
    translator: inout EventTranslator,
    into channel: LanguageModelExecutorGenerationChannel,
    started: Flag
  ) async throws {
    var body = initial
    var continuations = 0
    while true {
      try await translator.translate(
        client.stream(.object(body)),
        into: channel,
        onFirstChannelWrite: { started.set() }
      )
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
      // The error's code decides whether the attempt is retried.
      throw APIError(
        status: nil,
        error: translator.errors.first ?? ["code": "failed", "message": "The interaction failed."]
      )
    case "incomplete" where translator.structuredRequest:
      throw GeminiError.incompleteResponse
    default:
      break
    }
  }

  /// A flag set from a `@Sendable` callback.
  private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
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
