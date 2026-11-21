// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// An event of a streamed interaction.
///
/// An interaction streams as `interaction.created`, then for each step of the
/// model's turn a `step.start`, any number of `step.delta`, and a
/// `step.stop`, and finally `interaction.completed` with the status and the
/// usage. An `error` event ends the stream with an error.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
package enum StreamEvent: Sendable, Equatable {
  case interactionCreated(interaction: JSONValue)
  case statusUpdate(status: String)
  case stepStart(index: Int, step: JSONValue)
  case stepDelta(index: Int, delta: JSONValue)
  case stepStop(index: Int)
  case interactionCompleted(interaction: JSONValue)
  case unknown(type: String, payload: JSONValue)

  /// The event in a frame's payload. An `error` event throws its error.
  package init(frame: SSEFrame) throws {
    let payload = try JSONValue.parse(frame.data)
    let type = payload["event_type"]?.stringValue ?? frame.event ?? ""
    switch type {
    case "interaction.created":
      self = .interactionCreated(interaction: payload["interaction"] ?? [:])
    case "interaction.status_update":
      self = .statusUpdate(status: payload["status"]?.stringValue ?? "")
    case "step.start":
      self = .stepStart(index: payload["index"]?.intValue ?? 0, step: payload["step"] ?? [:])
    case "step.delta":
      self = .stepDelta(index: payload["index"]?.intValue ?? 0, delta: payload["delta"] ?? [:])
    case "step.stop":
      self = .stepStop(index: payload["index"]?.intValue ?? 0)
    case "interaction.completed":
      self = .interactionCompleted(interaction: payload["interaction"] ?? [:])
    case "error":
      throw APIError(status: nil, error: payload["error"] ?? payload)
    default:
      self = .unknown(type: type, payload: payload)
    }
  }
}

/// Token usage of an interaction.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
package struct Usage: Sendable, Equatable {
  package var inputTokens = 0
  package var cachedTokens = 0
  package var outputTokens = 0
  package var thoughtTokens = 0
  package var toolUseTokens = 0
  package var totalTokens = 0

  package init(
    inputTokens: Int = 0,
    cachedTokens: Int = 0,
    outputTokens: Int = 0,
    thoughtTokens: Int = 0,
    toolUseTokens: Int = 0,
    totalTokens: Int = 0
  ) {
    self.inputTokens = inputTokens
    self.cachedTokens = cachedTokens
    self.outputTokens = outputTokens
    self.thoughtTokens = thoughtTokens
    self.toolUseTokens = toolUseTokens
    self.totalTokens = totalTokens
  }

  package init(_ json: JSONValue) {
    self.init(
      inputTokens: json["total_input_tokens"]?.intValue ?? 0,
      cachedTokens: json["total_cached_tokens"]?.intValue ?? 0,
      outputTokens: json["total_output_tokens"]?.intValue ?? 0,
      thoughtTokens: json["total_thought_tokens"]?.intValue ?? 0,
      toolUseTokens: json["total_tool_use_tokens"]?.intValue ?? 0,
      totalTokens: json["total_tokens"]?.intValue ?? 0
    )
  }

  package static func + (a: Usage, b: Usage) -> Usage {
    Usage(
      inputTokens: a.inputTokens + b.inputTokens,
      cachedTokens: a.cachedTokens + b.cachedTokens,
      outputTokens: a.outputTokens + b.outputTokens,
      thoughtTokens: a.thoughtTokens + b.thoughtTokens,
      toolUseTokens: a.toolUseTokens + b.toolUseTokens,
      totalTokens: a.totalTokens + b.totalTokens
    )
  }
}
