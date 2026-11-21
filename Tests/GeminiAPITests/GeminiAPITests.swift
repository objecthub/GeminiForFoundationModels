// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization
import Testing

@testable import GeminiAPI

@Suite struct JSONValueTests {
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `objects are written in insertion order`() {
    let value: JSONValue = ["zeta": 1, "alpha": [true, nil, "x"], "mid": ["b": 2.5, "a": -3]]
    #expect(value.jsonText == #"{"zeta":1,"alpha":[true,null,"x"],"mid":{"b":2.5,"a":-3}}"#)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `strings are escaped`() {
    let value: JSONValue = .string("a\"b\\c\nd\te\u{01}/é")
    #expect(value.jsonText == #""a\"b\\c\nd\te\u0001/é""#)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `numbers are written compactly`() {
    #expect(JSONValue.number(80).jsonText == "80")
    #expect(JSONValue.number(-0.25).jsonText == "-0.25")
    #expect(JSONValue.number(1e300).jsonText == "1e+300")
    #expect(JSONValue.number(.infinity).jsonText == "null")
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `parsing round trips and distinguishes booleans from numbers`() throws {
    let text = #"{"b":true,"a":[1,0,2.5,"s",null],"c":{"d":false}}"#
    let value = try JSONValue.parse(text)
    #expect(value["b"] == true)
    #expect(value["a"] == [1, 0, 2.5, "s", nil])
    #expect(value["c"]?["d"] == false)
    #expect(try JSONValue.parse(value.jsonText) == value)
    #expect(JSONValue.parsed("{oops") == nil)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `equality ignores member order but reorder changes the text`() {
    var object: JSONObject = ["a": 1, "b": 2, "c": 3]
    let other: JSONObject = ["c": 3, "b": 2, "a": 1]
    #expect(object == other)
    object.reorder(["c", "x", "a"])
    #expect(object.keys == ["c", "a", "b"])
    object["a"] = nil
    #expect(JSONValue.object(object).jsonText == #"{"c":3,"b":2}"#)
  }
}

@Suite struct SSEParserTests {
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  private func frames(_ text: String) async throws -> [SSEFrame] {
    let bytes = AsyncThrowingStream<UInt8, Error> { continuation in
      for byte in Data(text.utf8) { continuation.yield(byte) }
      continuation.finish()
    }
    var frames: [SSEFrame] = []
    for try await frame in SSEParser.frames(from: bytes) { frames.append(frame) }
    return frames
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `frames split on blank lines with any line ending`() async throws {
    let parsed = try await frames("event: a\r\ndata: 1\r\n\r\nevent: b\rdata: 2\rdata: 3\r\r: comment\ndata:4")
    #expect(parsed == [
      SSEFrame(event: "a", data: "1"),
      SSEFrame(event: "b", data: "2\n3"),
      SSEFrame(event: nil, data: "4"),
    ])
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `a complete body is split too`() {
    #expect(SSEParser.frames(in: "event: error\ndata: {}\n\n") == [SSEFrame(event: "error", data: "{}")])
  }
}

@Suite struct APIErrorTests {
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `interactions errors are read`() {
    let error = APIError(status: 404, body: Data(#"{"error":{"message":"Model 'x' not found.","code":"not_found"}}"#.utf8))
    #expect(error.code == "not_found")
    #expect(error.message == "Model 'x' not found.")
    #expect(error.kind == .notFound)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `rpc errors are read with their details`() {
    let body = #"[{"error":{"code":400,"message":"API key not valid.","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID"},{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"12.5s"}]}}]"#
    let error = APIError(status: 400, body: Data(body.utf8))
    #expect(error.code == "invalid_argument")
    #expect(error.reason == "API_KEY_INVALID")
    #expect(error.retryDelay == 12.5)
    #expect(error.kind == .authentication)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `depleted credits are not a rate limit`() {
    let body = #"[{"error":{"code":402,"message":"Your prepayment credits are depleted.","status":"RESOURCE_EXHAUSTED"}}]"#
    #expect(APIError(status: 402, body: Data(body.utf8)).kind == .paymentRequired)
    let quota = #"{"error":{"code":429,"message":"Quota.","status":"RESOURCE_EXHAUSTED"}}"#
    #expect(APIError(status: 429, body: Data(quota.utf8)).kind == .rateLimit)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `errors sent as sse frames are read`() {
    let body = "event: error\ndata: {\"error\":{\"message\":\"Bad.\",\"code\":\"invalid_request\"},\"event_type\":\"error\"}\n\n"
    let error = APIError(status: 400, body: Data(body.utf8))
    #expect(error.code == "invalid_request")
    #expect(error.message == "Bad.")
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `unreadable bodies fall back to the status`() {
    let error = APIError(status: 503, body: Data("<html>busy</html>".utf8))
    #expect(error.code == "service_unavailable")
    #expect(error.kind == .overloaded)
    #expect(error.message == "<html>busy</html>")
  }
}

@Suite struct StepAssemblerTests {
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `deltas assemble into complete steps`() throws {
    var assembler = StepAssembler()
    let events: [StreamEvent] = [
      .stepStart(index: 0, step: ["type": "thought"]),
      .stepDelta(index: 0, delta: ["type": "thought_summary", "content": ["type": "text", "text": "Hmm"]]),
      .stepDelta(index: 0, delta: ["type": "thought_signature", "signature": "sig"]),
      .stepStart(index: 1, step: ["id": "c1", "type": "function_call", "name": "f", "arguments": [:]]),
      .stepDelta(index: 1, delta: ["type": "arguments_delta", "arguments": #"{"a":"#]),
      .stepDelta(index: 1, delta: ["type": "arguments_delta", "arguments": "1}"]),
      .stepStart(index: 2, step: ["type": "model_output"]),
      .stepDelta(index: 2, delta: ["type": "text", "text": "Hel"]),
      .stepDelta(index: 2, delta: ["type": "text", "text": "lo"]),
      .stepDelta(index: 2, delta: ["type": "text_annotation_delta", "annotations": [["url": "u"]]]),
      .stepStart(index: 3, step: ["id": "s", "type": "google_search_call", "signature": ""]),
      .stepDelta(index: 3, delta: ["type": "google_search_call", "signature": "g", "arguments": ["queries": ["q"]]]),
    ]
    for event in events { #expect(try assembler.consume(event) == nil) }
    #expect(try assembler.consume(.stepStop(index: 0)) == ["type": "thought", "summary": [["type": "text", "text": "Hmm"]], "signature": "sig"])
    #expect(try assembler.consume(.stepStop(index: 1)) == ["id": "c1", "type": "function_call", "name": "f", "arguments": ["a": 1]])
    #expect(try assembler.consume(.stepStop(index: 2)) == ["type": "model_output", "content": [["type": "text", "text": "Hello", "annotations": [["url": "u"]]]]])
    #expect(try assembler.consume(.stepStop(index: 3)) == ["id": "s", "type": "google_search_call", "signature": "g", "arguments": ["queries": ["q"]]])
    #expect(try assembler.consume(.stepStop(index: 9)) == nil)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `malformed arguments throw`() throws {
    var assembler = StepAssembler()
    _ = try assembler.consume(.stepStart(index: 0, step: ["type": "function_call", "id": "c", "name": "f"]))
    _ = try assembler.consume(.stepDelta(index: 0, delta: ["type": "arguments_delta", "arguments": "{nope"]))
    #expect(throws: APIError.self) { try assembler.consume(.stepStop(index: 0)) }
  }
}

@Suite struct GeminiClientTests {
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  private final class Transport: HTTPTransport {
    let status: Int
    let body: Data
    let recorded = Mutex<[URLRequest]>([])

    init(status: Int = 200, body: String) {
      self.status = status
      self.body = Data(body.utf8)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
      recorded.withLock { $0.append(request) }
      return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func bytes(for request: URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, URLResponse) {
      let (data, response) = try await self.data(for: request)
      return (AsyncThrowingStream { c in
        for byte in data { c.yield(byte) }
        c.finish()
      }, response)
    }
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  private func client(_ transport: Transport) -> GeminiClient {
    GeminiClient(
      configuration: .init(baseURL: URL(string: "https://example.invalid")!, headers: ["x-goog-api-key": "k"]),
      transport: transport
    )
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `streams events until done`() async throws {
    let transport = Transport(body: """
      event: interaction.created
      data: {"interaction":{"model":"m"},"event_type":"interaction.created"}

      event: step.stop
      data: {"index":0,"event_type":"step.stop"}

      event: done
      data: [DONE]

      event: step.stop
      data: {"index":1,"event_type":"step.stop"}


      """)
    var events: [StreamEvent] = []
    for try await event in client(transport).stream(["model": "m", "input": "hi"]) { events.append(event) }
    #expect(events == [.interactionCreated(interaction: ["model": "m"]), .stepStop(index: 0)])
    let request = try #require(transport.recorded.withLock { $0.first })
    #expect(request.url?.absoluteString == "https://example.invalid/v1beta/interactions")
    #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "k")
    #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self) == #"{"model":"m","input":"hi","stream":true}"#)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `http errors throw api errors`() async throws {
    let transport = Transport(status: 404, body: #"{"error":{"message":"Nope.","code":"not_found"}}"#)
    await #expect(throws: APIError(status: 404, code: "not_found", message: "Nope.")) {
      for try await _ in client(transport).stream(["model": "m"]) {}
    }
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `error events throw api errors`() async throws {
    let transport = Transport(body: "event: error\ndata: {\"error\":{\"message\":\"Boom.\",\"code\":\"api_error\"},\"event_type\":\"error\"}\n\n")
    await #expect(throws: APIError(status: nil, code: "api_error", message: "Boom.")) {
      for try await _ in client(transport).stream(["model": "m"]) {}
    }
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  private final class StalledTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
      fatalError("unused")
    }

    func bytes(for request: URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, URLResponse) {
      let first = Data("event: interaction.created\ndata: {\"interaction\":{},\"event_type\":\"interaction.created\"}\n\n: keep-alive\n".utf8)
      // Sends one event and keep-alive comments, but never finishes.
      let stream = AsyncThrowingStream<UInt8, Error> { continuation in
        for byte in first { continuation.yield(byte) }
        let task = Task {
          while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
            for byte in Data(": ping\n".utf8) { continuation.yield(byte) }
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
      return (stream, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test(.timeLimit(.minutes(1)))
  func `a stalled stream times out`() async throws {
    let client = GeminiClient(
      configuration: .init(baseURL: URL(string: "https://example.invalid")!, idleTimeout: 0.3),
      transport: StalledTransport()
    )
    var events = 0
    await #expect(throws: URLError(.timedOut)) {
      for try await _ in client.stream(["model": "m"]) { events += 1 }
    }
    #expect(events == 1)
  }
}
