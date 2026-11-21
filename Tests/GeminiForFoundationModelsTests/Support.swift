// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import GeminiAPI
import Synchronization
import Testing

@testable import GeminiForFoundationModels

// MARK: - Streams

/// The wire body of a stream of event payloads, each sent with its
/// `event_type` as the SSE event name, followed by `[DONE]`.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
func sseBody(_ events: [JSONValue]) -> Data {
  var text = ""
  for event in events {
    text += "event: \(event["event_type"]?.stringValue ?? "message")\n"
    text += "data: \(event.jsonText)\n\n"
  }
  text += "event: done\ndata: [DONE]\n\n"
  return Data(text.utf8)
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
enum Event {
  static func created(model: String = "gemini-3.8-flash") -> JSONValue {
    [
      "event_type": "interaction.created",
      "interaction": ["object": "interaction", "model": .string(model)],
    ]
  }

  static func start(_ index: Int, _ step: JSONValue) -> JSONValue {
    ["event_type": "step.start", "index": .number(Double(index)), "step": step]
  }

  static func delta(_ index: Int, _ delta: JSONValue) -> JSONValue {
    ["event_type": "step.delta", "index": .number(Double(index)), "delta": delta]
  }

  static func stop(_ index: Int) -> JSONValue {
    ["event_type": "step.stop", "index": .number(Double(index))]
  }

  static func completed(
    status: String = "completed",
    input: Int = 10,
    cached: Int = 0,
    output: Int = 5,
    thought: Int = 0,
    extra: JSONObject = [:]
  ) -> JSONValue {
    var interaction: JSONObject = [
      "status": .string(status),
      "usage": [
        "total_input_tokens": .number(Double(input)),
        "total_cached_tokens": .number(Double(cached)),
        "total_output_tokens": .number(Double(output)),
        "total_thought_tokens": .number(Double(thought)),
        "total_tokens": .number(Double(input + output + thought)),
      ],
      "object": "interaction",
      "model": "gemini-3.8-flash",
    ]
    for (key, value) in extra { interaction[key] = value }
    return ["event_type": "interaction.completed", "interaction": .object(interaction)]
  }
}

/// A turn that streams `deltas` as one `model_output` step, optionally after
/// a `thought` step with `signature`.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
func textTurn(
  _ deltas: [String],
  thoughtSignature: String? = nil,
  summary: [String] = [],
  status: String = "completed",
  output: Int = 5
) -> Data {
  var events: [JSONValue] = [Event.created()]
  var index = 0
  if let thoughtSignature {
    events.append(Event.start(index, ["type": "thought"]))
    for text in summary {
      events.append(
        Event.delta(index, ["type": "thought_summary", "content": ["type": "text", "text": .string(text)]])
      )
    }
    events.append(Event.delta(index, ["type": "thought_signature", "signature": .string(thoughtSignature)]))
    events.append(Event.stop(index))
    index += 1
  }
  events.append(Event.start(index, ["type": "model_output"]))
  for text in deltas {
    events.append(Event.delta(index, ["type": "text", "text": .string(text)]))
  }
  events.append(Event.stop(index))
  events.append(Event.completed(status: status, output: output))
  return sseBody(events)
}

/// A turn that calls functions, after a `thought` step with `signature`.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
func functionCallTurn(
  _ calls: [(id: String, name: String, arguments: [String])],
  thoughtSignature: String? = "sig-call"
) -> Data {
  var events: [JSONValue] = [Event.created()]
  var index = 0
  if let thoughtSignature {
    events += [
      Event.start(index, ["type": "thought"]),
      Event.delta(index, ["type": "thought_signature", "signature": .string(thoughtSignature)]),
      Event.stop(index),
    ]
    index += 1
  }
  for call in calls {
    events.append(
      Event.start(
        index,
        ["id": .string(call.id), "type": "function_call", "name": .string(call.name), "arguments": [:]]
      )
    )
    for chunk in call.arguments {
      events.append(Event.delta(index, ["type": "arguments_delta", "arguments": .string(chunk)]))
    }
    events.append(Event.stop(index))
    index += 1
  }
  events.append(Event.completed(status: "requires_action"))
  return sseBody(events)
}

/// A recorded stream from `Fixtures`.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
func fixture(_ name: String) throws -> Data {
  let url = try #require(
    Bundle.module.url(forResource: name, withExtension: "sse", subdirectory: "Fixtures")
  )
  return try Data(contentsOf: url)
}

/// The JSON body of a recorded request.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
func body(of request: URLRequest?) throws -> JSONValue {
  try JSONValue.parse(try #require(request?.httpBody))
}

// MARK: - Transport

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
final class MockTransport: HTTPTransport {
  private struct Canned {
    let status: Int
    let body: Data
  }

  private let responses: [Canned]
  private let recorded = Mutex<[URLRequest]>([])

  init(status: Int = 200, body: Data) {
    self.responses = [Canned(status: status, body: body)]
  }

  init(responses: [(status: Int, body: Data)]) {
    precondition(!responses.isEmpty, "MockTransport needs at least one response")
    self.responses = responses.map { Canned(status: $0.status, body: $0.body) }
  }

  var lastRequest: URLRequest? { recorded.withLock { $0.last } }
  var requests: [URLRequest] { recorded.withLock { $0 } }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let canned = next(recording: request)
    return (canned.body, response(request, canned))
  }

  func bytes(for request: URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, URLResponse) {
    let canned = next(recording: request)
    let stream = AsyncThrowingStream<UInt8, Error> { continuation in
      for byte in canned.body { continuation.yield(byte) }
      continuation.finish()
    }
    return (stream, response(request, canned))
  }

  private func next(recording request: URLRequest) -> Canned {
    recorded.withLock {
      $0.append(request)
      return responses[min($0.count - 1, responses.count - 1)]
    }
  }

  private func response(_ request: URLRequest, _ canned: Canned) -> URLResponse {
    HTTPURLResponse(url: request.url!, statusCode: canned.status, httpVersion: "HTTP/1.1", headerFields: nil)!
  }
}

// MARK: - Stubbed model

/// A Gemini model whose executor talks to a ``MockTransport``.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
struct StubbedGeminiModel: LanguageModel {
  typealias Executor = StubbedExecutor

  let transport: MockTransport
  let auth: GeminiAuth
  let model: GeminiModel
  let thinkingLevel: GeminiModel.ThinkingLevel?
  let builtInTools: Set<GeminiBuiltInTool>

  init(
    transport: MockTransport,
    auth: GeminiAuth = .apiKey("test-key"),
    model: GeminiModel = .gemini3_8Flash,
    thinkingLevel: GeminiModel.ThinkingLevel? = nil,
    builtInTools: Set<GeminiBuiltInTool> = []
  ) {
    self.transport = transport
    self.auth = auth
    self.model = model
    self.thinkingLevel = thinkingLevel
    self.builtInTools = builtInTools
  }

  init(fixture: Data) {
    self.init(transport: MockTransport(body: fixture))
  }

  var capabilities: LanguageModelCapabilities {
    LanguageModelCapabilities([.toolCalling, .reasoning, .guidedGeneration, .vision])
  }

  var executorConfiguration: StubbedExecutor.Configuration {
    .init(
      transport: transport,
      configuration: .init(
        model: model,
        auth: auth,
        thinkingLevel: thinkingLevel,
        builtInTools: builtInTools,
        baseURL: URL(string: "https://stub.invalid")!,
        timeout: 5
      )
    )
  }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
struct StubbedExecutor: LanguageModelExecutor {
  typealias Model = StubbedGeminiModel

  struct Configuration: Hashable, Sendable {
    let transport: MockTransport
    let configuration: GeminiExecutor.Configuration

    static func == (a: Self, b: Self) -> Bool {
      a.transport === b.transport && a.configuration == b.configuration
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(ObjectIdentifier(transport))
      hasher.combine(configuration)
    }
  }

  private let configuration: Configuration
  private let inner: GeminiExecutor

  init(configuration: Configuration) throws {
    self.configuration = configuration
    self.inner = GeminiExecutor(configuration: configuration.configuration, transport: configuration.transport)
  }

  func respond(
    to request: LanguageModelExecutorGenerationRequest,
    model: StubbedGeminiModel,
    streamingInto channel: LanguageModelExecutorGenerationChannel
  ) async throws {
    try await inner.respond(
      to: request,
      model: try GeminiLanguageModel(name: configuration.configuration.model, auth: configuration.configuration.auth),
      streamingInto: channel
    )
  }
}

// MARK: - Tools and types

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
final class ConvertTool: Tool {
  let name = "convertCurrency"
  let description = "Converts an amount of US dollars into another currency."

  @Generable
  struct Arguments {
    let amount: Double
    let currency: String
  }

  private let calls = Mutex<[String]>([])
  var calledCurrencies: [String] { calls.withLock { $0 } }

  func call(arguments: Arguments) async throws -> String {
    calls.withLock { $0.append(arguments.currency) }
    let rates: [String: Double] = ["EUR": 0.92, "CHF": 0.88, "JPY": 152.0]
    let rate = rates[arguments.currency] ?? 1
    return "\(arguments.amount * rate) \(arguments.currency)"
  }
}

@Generable
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
struct Itinerary: Equatable {
  var city: String
  var days: [Day]

  @Generable
  struct Day: Equatable {
    var title: String
    var activities: [String]
    var budget: Int
  }
}

/// The `type` values of the steps of a request body's `input`.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
func stepTypes(_ body: JSONValue) -> [String] {
  (body["input"]?.arrayValue ?? []).compactMap { $0["type"]?.stringValue }
}
