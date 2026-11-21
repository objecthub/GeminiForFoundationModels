// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Assembles the steps of a streamed turn from their `step.start` and
/// `step.delta` events.
///
/// A stateless conversation has to send the model's steps back exactly as
/// they were produced: a `thought` with its signature, a built-in tool call
/// and its result with theirs. The assembled step is that form.
///
/// - `text` deltas append to the last text block of `content`;
/// - `text_annotation_delta` deltas add citations to that block;
/// - `thought_summary` deltas append a content block to `summary`;
/// - `thought_signature` deltas set `signature`;
/// - `arguments_delta` deltas are JSON text, collected and parsed into
///   `arguments` when the step stops;
/// - any other delta (built-in tool steps send one whose `type` is the step's
///   own) merges its fields into the step.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
package struct StepAssembler: Sendable {
  private var steps: [Int: JSONObject] = [:]
  private var arguments: [Int: String] = [:]

  package init() {}

  /// Feeds one event. Returns the completed step when the event stops one.
  package mutating func consume(_ event: StreamEvent) throws -> JSONValue? {
    switch event {
    case .stepStart(let index, let step):
      steps[index] = step.objectValue ?? [:]
      arguments[index] = nil
      return nil
    case .stepDelta(let index, let delta):
      apply(delta, to: index)
      return nil
    case .stepStop(let index):
      guard var step = steps.removeValue(forKey: index) else { return nil }
      if let text = arguments.removeValue(forKey: index), !text.isEmpty {
        guard let parsed = JSONValue.parsed(text) else {
          throw APIError(
            status: nil,
            code: "malformed_function_call",
            message: "The arguments of a function call are not valid JSON: \(text.prefix(200))"
          )
        }
        step["arguments"] = parsed
      }
      return .object(step)
    default:
      return nil
    }
  }

  /// The step at `index` as assembled so far.
  package func step(at index: Int) -> JSONValue? {
    steps[index].map(JSONValue.object)
  }

  private mutating func apply(_ delta: JSONValue, to index: Int) {
    var step = steps[index] ?? [:]
    defer { steps[index] = step }
    switch delta["type"]?.stringValue {
    case "text":
      let text = delta["text"]?.stringValue ?? ""
      var content = step["content"]?.arrayValue ?? []
      if case .object(var last)? = content.last, last["type"]?.stringValue == "text" {
        last["text"] = .string((last["text"]?.stringValue ?? "") + text)
        content[content.count - 1] = .object(last)
      } else {
        content.append(["type": "text", "text": .string(text)])
      }
      step["content"] = .array(content)
    case "text_annotation_delta":
      var content = step["content"]?.arrayValue ?? []
      if content.isEmpty { content.append(["type": "text", "text": ""]) }
      if case .object(var last)? = content.last {
        let added = delta["annotations"]?.arrayValue ?? []
        last["annotations"] = .array((last["annotations"]?.arrayValue ?? []) + added)
        content[content.count - 1] = .object(last)
      }
      step["content"] = .array(content)
    case "thought_summary":
      if let block = delta["content"] {
        step["summary"] = .array((step["summary"]?.arrayValue ?? []) + [block])
      }
    case "thought_signature":
      if let signature = delta["signature"] { step["signature"] = signature }
    case "arguments_delta":
      arguments[index, default: ""] += delta["arguments"]?.stringValue ?? ""
    default:
      for (key, value) in delta.objectValue ?? [:] where key != "type" {
        step[key] = value
      }
    }
  }
}
