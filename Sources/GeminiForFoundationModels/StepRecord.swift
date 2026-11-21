// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import GeminiAPI

/// Steps of a model turn as the API produced them, kept in the metadata of
/// the transcript entry that presents them.
///
/// Requests are stateless, so every request sends the conversation back. The
/// API wants the model's steps of the current turn back exactly as it sent
/// them: a `thought` with its signature, built-in tool calls and results with
/// theirs. A request without them is rejected. The framework's entries can't
/// hold all of that, so each entry the bridge writes carries the steps it
/// stands for: a reasoning entry its `thought` step, each tool call its
/// `function_call` step, the response entry everything else. Every step is
/// tagged with its position in the turn, so the turn replays in the order it
/// was produced whatever order the entries ended up in.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
struct StepRecord: Sendable, Equatable {
  /// Reserved metadata key on entries the bridge writes. The value is opaque.
  static let metadataKey = "gemini.steps"

  private enum Stored {
    static let turn = "turn"
    static let steps = "steps"
    static let model = "model"
    static let position = "at"
    static let step = "step"
  }

  struct Step: Sendable, Equatable {
    /// Index among the turn's steps, counted across continuations.
    let position: Int
    /// The step object as the API produced it.
    let json: JSONValue

    var type: String { json["type"]?.stringValue ?? "" }

    /// The step's item in the stored form.
    var stored: String {
      JSONValue.object([Stored.position: .number(Double(position)), Stored.step: json]).jsonText
    }
  }

  /// Identifies the turn the positions count within, so entries of different
  /// turns that a transcript leaves side by side stay apart.
  var turn = ""
  var steps: [Step] = []
  /// The model that produced the turn. Only the response entry records it.
  var model: String?

  var isEmpty: Bool { steps.isEmpty }

  /// The entry-metadata value for a record of `turn` whose steps' stored
  /// items are `stored`, in order: JSON text, so what comes back out is what
  /// went in however the transcript is persisted.
  static func metadata(
    turn: String,
    stored: [String],
    model: String? = nil
  ) -> [String: any ConvertibleToGeneratedContent] {
    let modelField = model.map { ",\"\(Stored.model)\":\(JSONValue.string($0).jsonText)" } ?? ""
    return [
      metadataKey:
        "{\"\(Stored.steps)\":[\(stored.joined(separator: ","))],\"\(Stored.turn)\":\(JSONValue.string(turn).jsonText)\(modelField)}"
    ]
  }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
extension StepRecord {
  /// The record an entry carries; empty when it carries none or something
  /// unreadable.
  init(metadata: [String: GeneratedContent]) {
    self.init()
    guard case .string(let text)? = metadata[Self.metadataKey]?.kind,
      let stored = JSONValue.parsed(text),
      let turn = stored[Stored.turn]?.stringValue,
      let items = stored[Stored.steps]?.arrayValue
    else { return }
    self.turn = turn
    self.model = stored[Stored.model]?.stringValue
    steps = items.compactMap { item in
      guard let position = item[Stored.position]?.intValue, let json = item[Stored.step] else {
        return nil
      }
      return Step(position: position, json: json)
    }
  }

  /// The steps recorded on a model entry; for a tool-calls entry, on each of
  /// its calls.
  init(of entry: Transcript.Entry) {
    switch entry {
    case .response(let response):
      self.init(metadata: response.metadata)
    case .reasoning(let reasoning):
      self.init(metadata: reasoning.metadata)
    case .toolCalls(let calls):
      self.init()
      for call in calls {
        let record = StepRecord(metadata: call.metadata)
        if turn.isEmpty { turn = record.turn }
        steps += record.steps
      }
    default:
      self.init()
    }
  }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
extension JSONValue {
  /// The framework value as JSON, structurally, with properties in their
  /// order. A kind this package doesn't know reads as `null`.
  init(_ content: GeneratedContent) {
    switch content.kind {
    case .null:
      self = .null
    case .bool(let value):
      self = .bool(value)
    case .number(let value):
      self = .number(value)
    case .string(let value):
      self = .string(value)
    case .array(let values):
      self = .array(values.map(JSONValue.init))
    case .structure(let properties, let orderedKeys):
      var object = JSONObject()
      for key in orderedKeys {
        if let value = properties[key] { object[key] = JSONValue(value) }
      }
      for (key, value) in properties.sorted(by: { $0.key < $1.key }) where object[key] == nil {
        object[key] = JSONValue(value)
      }
      self = .object(object)
    @unknown default:
      self = .null
    }
  }
}
