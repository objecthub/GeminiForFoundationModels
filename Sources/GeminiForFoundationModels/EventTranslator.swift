// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import GeminiAPI

/// Translates the event stream of one turn into channel events, recording
/// each completed step on the entry that presents it (see ``StepRecord``).
///
/// A turn produces at most one response entry and one tool-calls entry; their
/// IDs are fixed at init so every event of the turn targets the same entries.
/// Each `thought` step becomes a reasoning entry of its own. A turn can span
/// several streams when the API asks for a continuation: feed each stream to
/// the same translator.
///
/// A structured response is one JSON document, but a model using built-in
/// tools can produce several `model_output` steps, some of them empty
/// objects. For a structured request, the output steps therefore share one
/// segment holding the latest substantive output.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
struct EventTranslator: Sendable {
  let responseEntryID: String
  let toolCallsEntryID: String

  /// The turn's completed steps so far, as the API produced them.
  private(set) var steps: [JSONValue] = []
  /// The interaction's status, once it completed: `completed`,
  /// `requires_action` (tool calls), `incomplete`, `failed`, or
  /// `requires_continuation`.
  private(set) var status: String?
  /// The token to resume an interaction whose status is
  /// `requires_continuation`.
  private(set) var continuationToken: String?
  /// The errors of a failed interaction.
  private(set) var errors: [JSONValue] = []

  private var assembler = StepAssembler()
  private let turn = UUID().uuidString
  /// The stored form of the steps the response entry has recorded so far;
  /// metadata updates replace wholesale, so all of it is sent each time.
  private var responseStored: [String] = []
  private var model: String?
  private var settledUsage = Usage()

  /// Whether the request is structured (see above).
  private let structured: Bool
  /// The segment shared by the output steps of a structured response.
  private let structuredSegmentID = UUID().uuidString
  /// The text of the shared segment as sent so far, and the latest
  /// substantive output.
  private var structuredText = ""
  private var structuredAnswer = ""

  init(
    responseEntryID: String = UUID().uuidString,
    toolCallsEntryID: String = UUID().uuidString,
    structured: Bool = false
  ) {
    self.responseEntryID = responseEntryID
    self.toolCallsEntryID = toolCallsEntryID
    self.structured = structured
  }

  /// Where a step's pieces go; `step.delta` only carries an index, so this is
  /// remembered from `step.start`.
  private enum Target {
    /// One text segment per `model_output` step.
    case text(segmentID: String)
    /// One reasoning entry per `thought` step.
    case thinking(entryID: String)
    case functionCall(id: String, name: String)
    /// A built-in tool call: an empty text segment with the call's ID holds
    /// its place among the prose; the step itself is only recorded.
    case builtInCall(id: String)
    /// Built-in tool results and anything unrecognized: nothing streams to
    /// the framework, the step is only recorded.
    case recordOnly
  }

  /// Placeholder token count for streamed deltas. The API reports usage only
  /// when the interaction completes, and a count of 0 suppresses partial
  /// snapshots. Authoritative totals arrive with `interaction.completed`.
  static let deltaTokenCount = 1

  /// Relays channel writes so the first-write callback is handled in one
  /// place.
  private final class ChannelSink {
    private let channel: LanguageModelExecutorGenerationChannel
    private var pendingFirstWrite: (@Sendable () -> Void)?

    init(_ channel: LanguageModelExecutorGenerationChannel, onFirstWrite: (@Sendable () -> Void)?) {
      self.channel = channel
      self.pendingFirstWrite = onFirstWrite
    }

    func send(_ event: LanguageModelExecutorGenerationChannel.Event) async {
      pendingFirstWrite?()
      pendingFirstWrite = nil
      await channel.send(event)
    }
  }

  /// Translates one stream.
  ///
  /// - Parameter onFirstChannelWrite: Invoked once, right before the first
  ///   write to the channel.
  mutating func translate(
    _ events: AsyncThrowingStream<StreamEvent, Error>,
    into channel: LanguageModelExecutorGenerationChannel,
    onFirstChannelWrite: (@Sendable () -> Void)? = nil
  ) async throws {
    let channel = ChannelSink(channel, onFirstWrite: onFirstChannelWrite)
    var targets: [Int: Target] = [:]
    status = nil
    continuationToken = nil

    for try await event in events {
      try Task.checkCancellation()
      let completed = try assembler.consume(event)

      switch event {
      case .interactionCreated(let interaction):
        model = interaction["model"]?.stringValue ?? model

      case .stepStart(let index, let step):
        var target = Self.target(for: step)
        if structured, case .text = target {
          target = .text(segmentID: structuredSegmentID)
          await replaceStructured(with: "", via: channel)
        }
        targets[index] = target
        await open(step, target: target, via: channel)

      case .stepDelta(let index, let delta):
        await send(delta, to: targets[index], via: channel)
        if structured, case .text? = targets[index], let text = delta["text"]?.stringValue,
          delta["type"]?.stringValue == "text"
        {
          structuredText += text
        }

      case .stepStop(let index):
        let target = targets.removeValue(forKey: index)
        if structured, case .text? = target {
          if Self.isSubstantive(structuredText) {
            structuredAnswer = structuredText
          } else if !structuredAnswer.isEmpty {
            // An empty output after a real one doesn't replace it.
            await replaceStructured(with: structuredAnswer, via: channel)
          }
        }
        if let completed { await record(completed, for: target, via: channel) }

      case .interactionCompleted(let interaction):
        status = interaction["status"]?.stringValue
        continuationToken = interaction["continuation_token"]?.stringValue
        errors = interaction["errors"]?.arrayValue ?? []
        if let model = interaction["model"]?.stringValue { self.model = model }
        let usage = settledUsage + Usage(interaction["usage"] ?? [:])
        settledUsage = usage
        await channel.send(
          .response(
            entryID: responseEntryID,
            action: .updateUsage(
              input: .init(totalTokenCount: usage.inputTokens, cachedTokenCount: usage.cachedTokens),
              output: .init(
                totalTokenCount: usage.outputTokens + usage.thoughtTokens,
                reasoningTokenCount: usage.thoughtTokens
              )
            )
          )
        )

      case .statusUpdate(let update):
        if update == "requires_continuation" { status = update }

      case .unknown:
        break
      }
    }
  }

  // MARK: - Private

  /// Whether a structured output is more than whitespace or an empty JSON
  /// object or array.
  static func isSubstantive(_ text: String) -> Bool {
    let compact = text.filter { !$0.isWhitespace }
    return !compact.isEmpty && compact != "{}" && compact != "[]"
  }

  /// Sets the shared segment of a structured response to `text`.
  private mutating func replaceStructured(
    with text: String,
    via channel: ChannelSink
  ) async {
    guard structuredText != text else { return }
    structuredText = text
    await channel.send(
      .response(
        entryID: responseEntryID,
        action: .replaceTextSegment(text, segmentID: structuredSegmentID, tokenCount: Self.deltaTokenCount)
      )
    )
  }

  private static func target(for step: JSONValue) -> Target {
    let type = step["type"]?.stringValue ?? ""
    switch type {
    case "model_output":
      return .text(segmentID: UUID().uuidString)
    case "thought":
      return .thinking(entryID: UUID().uuidString)
    case "function_call":
      return .functionCall(id: step["id"]?.stringValue ?? "", name: step["name"]?.stringValue ?? "")
    default:
      if type.hasSuffix("_call"), let id = step["id"]?.stringValue {
        return .builtInCall(id: id)
      }
      return .recordOnly
    }
  }

  /// Sends what a step carries when it starts.
  private func open(_ step: JSONValue, target: Target, via channel: ChannelSink) async {
    switch target {
    case .text:
      for block in step["content"]?.arrayValue ?? [] {
        await send(["type": "text", "text": block["text"] ?? ""], to: target, via: channel)
      }
    case .thinking:
      for block in step["summary"]?.arrayValue ?? [] {
        await send(["type": "thought_summary", "content": block], to: target, via: channel)
      }
    case .functionCall(let id, let name):
      // Opens the call even if no argument deltas follow.
      var opening = ""
      if let arguments = step["arguments"], let object = arguments.objectValue, !object.isEmpty {
        opening = arguments.jsonText
      }
      await channel.send(
        .toolCalls(
          entryID: toolCallsEntryID,
          action: .toolCall(
            id: id,
            name: name,
            action: .appendArguments(opening, tokenCount: opening.isEmpty ? 0 : Self.deltaTokenCount)
          )
        )
      )
    case .builtInCall, .recordOnly:
      break
    }
  }

  private func send(_ delta: JSONValue, to target: Target?, via channel: ChannelSink) async {
    switch (delta["type"]?.stringValue, target) {
    case ("text", .text(let segmentID)):
      guard let text = delta["text"]?.stringValue, !text.isEmpty else { return }
      await channel.send(
        .response(
          entryID: responseEntryID,
          action: .appendText(text, segmentID: segmentID, tokenCount: Self.deltaTokenCount)
        )
      )
    case ("thought_summary", .thinking(let entryID)):
      guard let text = delta["content"]?["text"]?.stringValue, !text.isEmpty else { return }
      await channel.send(
        .reasoning(entryID: entryID, action: .appendText(text, tokenCount: Self.deltaTokenCount))
      )
    case ("arguments_delta", .functionCall(let id, let name)):
      guard let chunk = delta["arguments"]?.stringValue, !chunk.isEmpty else { return }
      await channel.send(
        .toolCalls(
          entryID: toolCallsEntryID,
          action: .toolCall(
            id: id,
            name: name,
            action: .appendArguments(chunk, tokenCount: Self.deltaTokenCount)
          )
        )
      )
    // Signatures, citations, and built-in tool data reach the framework
    // through the step's record once it completes.
    default:
      break
    }
  }

  /// Files a completed step: into ``steps``, and onto the entry it belongs to.
  private mutating func record(_ json: JSONValue, for target: Target?, via channel: ChannelSink) async {
    let step = StepRecord.Step(position: steps.count, json: json)
    steps.append(json)

    switch target {
    case .thinking(let entryID):
      // The entry's signature is the framework's slot for the step's
      // verification data.
      if let signature = json["signature"]?.stringValue, !signature.isEmpty {
        await channel.send(
          .reasoning(entryID: entryID, action: .updateSignature(Data(signature.utf8), tokenCount: 0))
        )
      }
      await channel.send(
        .reasoning(
          entryID: entryID,
          action: .updateMetadata(StepRecord.metadata(turn: turn, stored: [step.stored]))
        )
      )

    case .functionCall(let id, let name):
      await channel.send(
        .toolCalls(
          entryID: toolCallsEntryID,
          action: .toolCall(
            id: id,
            name: name,
            action: .updateMetadata(StepRecord.metadata(turn: turn, stored: [step.stored]))
          )
        )
      )

    case .text, .builtInCall, .recordOnly, nil:
      responseStored.append(step.stored)
      await channel.send(
        .response(
          entryID: responseEntryID,
          action: .updateMetadata(
            StepRecord.metadata(turn: turn, stored: responseStored, model: model)
          )
        )
      )
      // The placeholder goes in once its step is on the record, so the
      // snapshot it triggers can already resolve it.
      if case .builtInCall(let id) = target {
        await channel.send(
          .response(
            entryID: responseEntryID,
            action: .appendText("", segmentID: id, tokenCount: Self.deltaTokenCount)
          )
        )
      }
    }
  }
}
