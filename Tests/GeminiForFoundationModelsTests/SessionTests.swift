// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import GeminiAPI
import Testing

@testable import GeminiForFoundationModels

/// `LanguageModelSession` end to end against canned streams.
@Suite struct SessionTests {
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `text deltas stream as cumulative snapshots`() async throws {
    let session = LanguageModelSession(model: StubbedGeminiModel(fixture: textTurn(["Hello", ", world"])))
    var snapshots: [String] = []
    for try await snapshot in session.streamResponse(to: "hi") {
      snapshots.append(snapshot.content)
    }
    #expect(snapshots.count >= 2)
    #expect(snapshots.last == "Hello, world")
    #expect(snapshots.allSatisfy { "Hello, world".hasPrefix($0) })
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `a recorded thinking turn yields reasoning and a response`() async throws {
    let session = LanguageModelSession(model: StubbedGeminiModel(fixture: try fixture("thinking-text")))
    let response = try await session.respond(to: "A bat and a ball…")
    #expect(response.content.contains("$0.05"))

    let reasoning = session.transcript.compactMap { entry -> Transcript.Reasoning? in
      if case .reasoning(let reasoning) = entry { reasoning } else { nil }
    }
    #expect(reasoning.count == 1)
    #expect(reasoning.first?.signature == Data("sig-1".utf8))
    let summary = reasoning.first?.segments.compactMap { segment -> String? in
      if case .text(let text) = segment { text.content } else { nil }
    }.joined()
    #expect(summary?.contains("Pinpointing the Core Issue") == true)

    let usage = session.usage
    #expect(usage.input.totalTokenCount == 38)
    #expect(usage.output.reasoningTokenCount == 621)
    #expect(usage.output.totalTokenCount == 125 + 621)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `parallel tool calls round trip with the thought replayed exactly`() async throws {
    let transport = MockTransport(responses: [
      (200, try fixture("parallel-tool-calls")),
      (200, try fixture("tool-followup")),
    ])
    let tool = ConvertTool()
    let session = LanguageModelSession(model: StubbedGeminiModel(transport: transport), tools: [tool])

    let response = try await session.respond(to: "How much are 80 USD in CHF and in EUR?")

    #expect(tool.calledCurrencies.sorted() == ["CHF", "EUR"])
    #expect(response.content.contains("70.40"))
    #expect(transport.requests.count == 2)

    let followup = try body(of: transport.requests.last)
    #expect(stepTypes(followup) == [
      "user_input", "thought", "function_call", "function_call", "function_result", "function_result",
    ])
    let input = try #require(followup["input"]?.arrayValue)
    // The thought goes back exactly as it was produced, signature included.
    #expect(input[1] == ["type": "thought", "signature": "sig-2"])
    #expect(input[2]["id"] == "call_8103927580697992308")
    #expect(input[2]["arguments"] == ["amount": 80, "currency": "CHF"])
    let callIDs = Set(input[2...3].compactMap { $0["id"]?.stringValue })
    let resultIDs = Set(input[4...5].compactMap { $0["call_id"]?.stringValue })
    #expect(callIDs == resultIDs)
    #expect(input[4]["name"] == "convertCurrency")
    #expect(input[4]["result"]?.stringValue?.contains("CHF") == true)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `a later turn replays the earlier turn's steps`() async throws {
    let transport = MockTransport(responses: [
      (200, textTurn(["First."], thoughtSignature: "sig-a")),
      (200, textTurn(["Second."])),
    ])
    let session = LanguageModelSession(
      model: StubbedGeminiModel(transport: transport),
      instructions: "Be brief."
    )
    _ = try await session.respond(to: "one")
    _ = try await session.respond(to: "two")

    let second = try body(of: transport.requests.last)
    #expect(second["system_instruction"] == "Be brief.")
    // The completed turn's thought isn't sent: the API bills it as input.
    #expect(stepTypes(second) == ["user_input", "model_output", "user_input"])
    let input = try #require(second["input"]?.arrayValue)
    #expect(stepTypes(second).count == input.count)
    #expect(input[1]["content"]?[0]?["text"] == "First.")
    #expect(second["store"] == false)
    #expect(second["stream"] == true)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `guided generation sends the schema in declared order and decodes`() async throws {
    let json = #"{"city":"Lisbon","days":[{"title":"Alfama","activities":["Castle","Fado"],"budget":80}]}"#
    let transport = MockTransport(body: textTurn([String(json.prefix(20)), String(json.dropFirst(20))]))
    let session = LanguageModelSession(model: StubbedGeminiModel(transport: transport))

    let response = try await session.respond(to: "Plan a trip", generating: Itinerary.self)
    #expect(response.content.city == "Lisbon")
    #expect(response.content.days.first?.activities == ["Castle", "Fado"])

    let sent = try #require(transport.lastRequest?.httpBody)
    let text = String(decoding: sent, as: UTF8.self)
    #expect(text.contains(#""response_format":{"type":"text","mime_type":"application/json","schema":"#))
    #expect(!text.contains("x-order"))
    // Properties go out in declaration order: title, activities, budget.
    let title = try #require(text.range(of: #""title":{"#))
    let activities = try #require(text.range(of: #""activities":{"#))
    let budget = try #require(text.range(of: #""budget":{"#))
    #expect(title.lowerBound < activities.lowerBound)
    #expect(activities.lowerBound < budget.lowerBound)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  static func outputs(_ texts: [String]) -> Data {
    var events: [JSONValue] = [Event.created()]
    for (index, text) in texts.enumerated() {
      events += [
        Event.start(index, ["type": "model_output"]),
        Event.delta(index, ["type": "text", "text": .string(text)]),
        Event.stop(index),
      ]
    }
    events.append(Event.completed())
    return sseBody(events)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `a structured response keeps the latest substantive output`() async throws {
    let json = #"{"city":"Lisbon","days":[{"title":"Alfama","activities":["Castle"],"budget":80}]}"#
    for texts in [["{}", "{}", json], [json, "{}"], ["{}", json, " "]] {
      let session = LanguageModelSession(model: StubbedGeminiModel(fixture: Self.outputs(texts)))
      let response = try await session.respond(to: "Plan a trip", generating: Itinerary.self)
      #expect(response.content.city == "Lisbon")
    }
    // Text responses keep every output step.
    let session = LanguageModelSession(model: StubbedGeminiModel(fixture: Self.outputs(["One. ", "Two."])))
    #expect(try await session.respond(to: "Count").content == "One. Two.")
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `an incomplete structured response throws`() async throws {
    let transport = MockTransport(body: textTurn([#"{"city":"Lis"#], status: "incomplete"))
    let session = LanguageModelSession(model: StubbedGeminiModel(transport: transport))
    await #expect(throws: GeminiError.incompleteResponse) {
      _ = try await session.respond(to: "Plan a trip", generating: Itinerary.self)
    }
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `the api key goes in the x-goog-api-key header`() async throws {
    let transport = MockTransport(body: textTurn(["ok"]))
    let session = LanguageModelSession(model: StubbedGeminiModel(transport: transport, auth: .apiKey("k-123")))
    _ = try await session.respond(to: "hi")
    let request = try #require(transport.lastRequest)
    #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "k-123")
    #expect(request.url?.absoluteString == "https://stub.invalid/v1beta/interactions")
    #expect(request.httpMethod == "POST")
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `proxied auth sends the proxy headers and no api key`() async throws {
    let transport = MockTransport(body: textTurn(["ok"]))
    let session = LanguageModelSession(
      model: StubbedGeminiModel(transport: transport, auth: .proxied(headers: ["X-App-Token": "abc"]))
    )
    _ = try await session.respond(to: "hi")
    let request = try #require(transport.lastRequest)
    #expect(request.value(forHTTPHeaderField: "X-App-Token") == "abc")
    #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == nil)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `an empty api key fails without a request`() async throws {
    let transport = MockTransport(body: textTurn(["ok"]))
    let session = LanguageModelSession(model: StubbedGeminiModel(transport: transport, auth: .apiKey("  ")))
    await #expect(throws: GeminiError.missingCredential) {
      _ = try await session.respond(to: "hi")
    }
    #expect(transport.requests.isEmpty)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `an invalid api key maps to invalidCredential`() async throws {
    let body = #"[{"error":{"code":400,"message":"API key not valid.","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID"}]}}]"#
    let session = LanguageModelSession(
      model: StubbedGeminiModel(transport: MockTransport(status: 400, body: Data(body.utf8)))
    )
    await #expect(throws: GeminiError.invalidCredential) {
      _ = try await session.respond(to: "hi")
    }
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `rate limits map to rateLimited`() async throws {
    let body = #"{"error":{"code":"rate_limit_exceeded","message":"Slow down."}}"#
    let session = LanguageModelSession(
      model: StubbedGeminiModel(transport: MockTransport(status: 429, body: Data(body.utf8)))
    )
    do {
      _ = try await session.respond(to: "hi")
      Issue.record("Expected an error")
    } catch let error as LanguageModelError {
      guard case .rateLimited = error else {
        Issue.record("Unexpected error \(error)")
        return
      }
    }
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `other api errors surface as GeminiAPIError`() async throws {
    let body = "event: error\ndata: {\"error\":{\"message\":\"Request contains an invalid argument.\",\"code\":\"invalid_request\"},\"event_type\":\"error\"}\n\n"
    let session = LanguageModelSession(
      model: StubbedGeminiModel(transport: MockTransport(status: 400, body: Data(body.utf8)))
    )
    await #expect(throws: GeminiAPIError(status: 400, code: "invalid_request", message: "Request contains an invalid argument.")) {
      _ = try await session.respond(to: "hi")
    }
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `an error event mid-stream surfaces`() async throws {
    let stream = sseBody([
      Event.created(),
      Event.start(0, ["type": "model_output"]),
      Event.delta(0, ["type": "text", "text": "Hel"]),
      ["event_type": "error", "error": ["code": "service_unavailable", "message": "Overloaded."]],
    ])
    let session = LanguageModelSession(model: StubbedGeminiModel(transport: MockTransport(body: stream)))
    do {
      _ = try await session.respond(to: "hi")
      Issue.record("Expected an error")
    } catch let error as LanguageModelError {
      guard case .rateLimited = error else {
        Issue.record("Unexpected error \(error)")
        return
      }
    }
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `built-in tool steps are recorded and replayed`() async throws {
    let first = sseBody([
      Event.created(),
      Event.start(0, ["id": "s1", "type": "google_search_call", "signature": ""]),
      Event.delta(0, ["type": "google_search_call", "signature": "gs-1", "arguments": ["queries": ["lisbon weather"]]]),
      Event.stop(0),
      Event.start(1, ["call_id": "s1", "type": "google_search_result", "signature": ""]),
      Event.delta(1, ["type": "google_search_result", "signature": "gr-1", "result": [["title": "Weather"]], "is_error": false]),
      Event.stop(1),
      Event.start(2, ["type": "model_output"]),
      Event.delta(2, ["type": "text", "text": "Sunny."]),
      Event.delta(2, ["type": "text_annotation_delta", "annotations": [["type": "url_citation", "url": "https://x.invalid"]]]),
      Event.stop(2),
      Event.completed(),
    ])
    let transport = MockTransport(responses: [(200, first), (200, textTurn(["Yes."]))])
    let session = LanguageModelSession(
      model: StubbedGeminiModel(transport: transport, builtInTools: [.googleSearch, .codeExecution])
    )
    let response = try await session.respond(to: "Weather in Lisbon?")
    #expect(response.content == "Sunny.")

    let activities = GeminiToolActivity.activities(in: session.transcript)
    #expect(activities.count == 1)
    #expect(activities.first?.kind == .googleSearch)
    #expect(activities.first?.queries == ["lisbon weather"])
    #expect(activities.first?.result == #"[{"title":"Weather"}]"#)

    _ = try await session.respond(to: "Sure?")
    let second = try body(of: transport.requests.last)
    #expect(second["tools"] == [["type": "code_execution"], ["type": "google_search"]])
    #expect(stepTypes(second) == ["user_input", "google_search_call", "google_search_result", "model_output", "user_input"])
    let input = try #require(second["input"]?.arrayValue)
    #expect(input[1]["signature"] == "gs-1")
    #expect(input[2]["signature"] == "gr-1")
    #expect(input[3]["content"]?[0]?["annotations"]?[0]?["url"] == "https://x.invalid")
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  static func builtInSearchTurn() -> Data {
    sseBody([
      Event.created(),
      Event.start(0, ["type": "thought"]),
      Event.delta(0, ["type": "thought_signature", "signature": "t-1"]),
      Event.stop(0),
      Event.start(1, ["id": "s1", "type": "google_search_call", "signature": ""]),
      Event.delta(1, ["type": "google_search_call", "signature": "gs-1", "arguments": ["queries": ["lispkit"]]]),
      Event.stop(1),
      Event.start(2, ["call_id": "s1", "type": "google_search_result", "signature": ""]),
      Event.delta(2, ["type": "google_search_result", "signature": "gr-1", "result": [["title": "LispKit"]], "is_error": false]),
      Event.stop(2),
      Event.start(3, ["type": "model_output"]),
      Event.delta(3, ["type": "text", "text": "LispKit is "]),
      Event.delta(3, ["type": "text", "text": "a Scheme."]),
      Event.stop(3),
      Event.completed(),
    ])
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test(.timeLimit(.minutes(1)))
  func `streaming a turn with built-in tool steps finishes`() async throws {
    let session = LanguageModelSession(
      model: StubbedGeminiModel(transport: MockTransport(body: Self.builtInSearchTurn()), builtInTools: [.googleSearch])
    )
    var last = ""
    for try await snapshot in session.streamResponse(to: "What is LispKit?") {
      last = snapshot.content
    }
    #expect(last == "LispKit is a Scheme.")
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test(.timeLimit(.minutes(1)))
  func `a session responds again after streaming`() async throws {
    let transport = MockTransport(responses: [(200, textTurn(["One", " two"])), (200, textTurn(["Three"]))])
    let session = LanguageModelSession(model: StubbedGeminiModel(transport: transport))
    for try await _ in session.streamResponse(to: "count") {}
    let response = try await session.respond(to: "more")
    #expect(response.content == "Three")
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `a paused turn is continued with its token`() async throws {
    let paused = sseBody([
      Event.created(),
      Event.start(0, ["type": "model_output"]),
      Event.delta(0, ["type": "text", "text": "Part one. "]),
      Event.stop(0),
      Event.completed(status: "requires_continuation", extra: ["continuation_token": "tok-1"]),
    ])
    let resumed = sseBody([
      Event.created(),
      Event.start(0, ["type": "model_output"]),
      Event.delta(0, ["type": "text", "text": "Part two."]),
      Event.stop(0),
      Event.completed(),
    ])
    let transport = MockTransport(responses: [(200, paused), (200, resumed)])
    let session = LanguageModelSession(model: StubbedGeminiModel(transport: transport))
    let response = try await session.respond(to: "Long answer, please.")
    #expect(response.content == "Part one. Part two.")
    #expect(transport.requests.count == 2)
    #expect(try body(of: transport.requests.last)["continuation_token"] == "tok-1")
  }
}
