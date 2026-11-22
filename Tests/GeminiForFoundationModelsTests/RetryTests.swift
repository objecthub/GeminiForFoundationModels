// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import GeminiAPI
import Testing

@testable import GeminiForFoundationModels

/// Retries after temporary failures.
@Suite struct RetryTests {
  /// An error in Google's RPC shape.
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  static func rpcError(_ code: Int, _ status: String, retryDelay: String? = nil) -> Data {
    let details = retryDelay.map {
      #","details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"\#($0)"}]"#
    } ?? ""
    return Data(#"[{"error":{"code":\#(code),"message":"Failed.","status":"\#(status)"\#(details)}}]"#.utf8)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `an exhausted quota is retried after the server's wait`() async throws {
    let transport = MockTransport(responses: [
      (429, Self.rpcError(429, "RESOURCE_EXHAUSTED", retryDelay: "1.5s")),
      (200, textTurn(["Hello."])),
    ])
    let session = LanguageModelSession(model: StubbedGeminiModel(transport: transport))
    #expect(try await session.respond(to: "hi").content == "Hello.")
    #expect(transport.requests.count == 2)
    #expect(transport.sleeps == [1.5])
    let entry = session.transcript.compactMap { entry -> Transcript.Response? in
      if case .response(let response) = entry { response } else { nil }
    }.last
    #expect(entry?.metadata[EventTranslator.attemptsMetadataKey] == GeneratedContent(2))
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `an overloaded model is retried with backoff`() async throws {
    let transport = MockTransport(responses: [
      (503, Self.rpcError(503, "UNAVAILABLE")),
      (500, Data(#"{"error":{"code":"internal","message":"Internal error."}}"#.utf8)),
      (200, textTurn(["Hello."])),
    ])
    let session = LanguageModelSession(model: StubbedGeminiModel(transport: transport))
    #expect(try await session.respond(to: "hi").content == "Hello.")
    #expect(transport.requests.count == 3)
    #expect(transport.sleeps == [0.5, 1])
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `retries are limited`() async throws {
    let transport = MockTransport(responses: [(503, Self.rpcError(503, "UNAVAILABLE"))])
    let session = LanguageModelSession(model: StubbedGeminiModel(transport: transport))
    await #expect(throws: LanguageModelError.self) {
      _ = try await session.respond(to: "hi")
    }
    #expect(transport.requests.count == 3)

    let disabled = MockTransport(responses: [(503, Self.rpcError(503, "UNAVAILABLE"))])
    let once = LanguageModelSession(model: StubbedGeminiModel(transport: disabled, retry: .disabled))
    await #expect(throws: LanguageModelError.self) {
      _ = try await once.respond(to: "hi")
    }
    #expect(disabled.requests.count == 1)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `a long wait is left to the app`() async throws {
    let transport = MockTransport(responses: [
      (429, Self.rpcError(429, "RESOURCE_EXHAUSTED", retryDelay: "45s")),
      (200, textTurn(["Hello."])),
    ])
    let session = LanguageModelSession(model: StubbedGeminiModel(transport: transport))
    do {
      _ = try await session.respond(to: "hi")
      Issue.record("Expected an error")
    } catch let error as LanguageModelError {
      guard case .rateLimited(let context) = error else {
        Issue.record("Unexpected error \(error)")
        return
      }
      #expect(abs((context.resetDate?.timeIntervalSinceNow ?? 0) - 45) < 10)
    }
    #expect(transport.requests.count == 1)
    #expect(transport.sleeps.isEmpty)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `permanent failures are not retried`() async throws {
    let failures: [(Int, Data)] = [
      (402, Self.rpcError(402, "RESOURCE_EXHAUSTED")),
      (400, Data(#"[{"error":{"code":400,"message":"API key not valid.","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID"}]}}]"#.utf8)),
      (400, Data(#"{"error":{"code":"invalid_request","message":"Bad."}}"#.utf8)),
      (404, Data(#"{"error":{"code":"not_found","message":"No such model."}}"#.utf8)),
    ]
    for (status, body) in failures {
      let transport = MockTransport(responses: [(status, body), (200, textTurn(["Hello."]))])
      let session = LanguageModelSession(model: StubbedGeminiModel(transport: transport))
      await #expect(throws: (any Error).self) {
        _ = try await session.respond(to: "hi")
      }
      #expect(transport.requests.count == 1, "\(status)")
    }
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `nothing is retried once text reached the session`() async throws {
    let broken = sseBody([
      Event.created(),
      Event.start(0, ["type": "model_output"]),
      Event.delta(0, ["type": "text", "text": "Hel"]),
      ["event_type": "error", "error": ["code": "service_unavailable", "message": "Overloaded."]],
    ])
    let transport = MockTransport(responses: [(200, broken), (200, textTurn(["Hello."]))])
    let session = LanguageModelSession(model: StubbedGeminiModel(transport: transport))
    await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "hi")
    }
    #expect(transport.requests.count == 1)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `a failed interaction without content is retried`() async throws {
    let failed = sseBody([
      Event.created(),
      Event.completed(status: "failed", extra: ["errors": [["code": "internal", "message": "Internal error."]]]),
    ])
    let transport = MockTransport(responses: [(200, failed), (200, textTurn(["Hello."]))])
    let session = LanguageModelSession(model: StubbedGeminiModel(transport: transport))
    #expect(try await session.respond(to: "hi").content == "Hello.")
    #expect(transport.requests.count == 2)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `earlier thoughts are sent on request`() async throws {
    let transport = MockTransport(responses: [
      (200, textTurn(["First."], thoughtSignature: "sig-a")),
      (200, textTurn(["Second."])),
    ])
    let session = LanguageModelSession(model: StubbedGeminiModel(transport: transport, replaysEarlierThoughts: true))
    _ = try await session.respond(to: "one")
    _ = try await session.respond(to: "two")
    let second = try body(of: transport.requests.last)
    #expect(stepTypes(second) == ["user_input", "thought", "model_output", "user_input"])
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `the current tool loop's thought is always sent`() async throws {
    let transport = MockTransport(responses: [
      (200, functionCallTurn([(id: "c1", name: "convertCurrency", arguments: [#"{"amount":80,"currency":"EUR"}"#])])),
      (200, textTurn(["73.60 EUR."])),
    ])
    let session = LanguageModelSession(model: StubbedGeminiModel(transport: transport), tools: [ConvertTool()])
    _ = try await session.respond(to: "80 USD in EUR?")
    let followup = try body(of: transport.requests.last)
    #expect(stepTypes(followup) == ["user_input", "thought", "function_call", "function_result"])
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `the backoff doubles`() {
    #expect(GeminiRetryPolicy.backoff(1, jitter: 1) == 0.5)
    #expect(GeminiRetryPolicy.backoff(2, jitter: 1) == 1)
    #expect(GeminiRetryPolicy.isTemporary(URLError(.networkConnectionLost)))
    #expect(!GeminiRetryPolicy.isTemporary(URLError(.notConnectedToInternet)))
    #expect(!GeminiRetryPolicy.isTemporary(CancellationError()))
  }
}
