// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import GeminiAPI

/// Pure translation: framework request → Interactions API request body.
///
/// Requests are stateless (`store: false`): every request carries the whole
/// conversation as steps. Model turns replay the steps recorded on their
/// entries (see ``StepRecord``); entries without a record are rebuilt from
/// what the framework holds.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
enum RequestBuilder {
  struct Built {
    var body: JSONValue
    /// True when a schema was sent as `response_format`: the response is
    /// JSON text conforming to it.
    var isStructured: Bool
  }

  static func build(
    from request: LanguageModelExecutorGenerationRequest,
    model: GeminiModel,
    thinkingLevel fixedLevel: GeminiModel.ThinkingLevel? = nil,
    thoughtSummaries: Bool = true,
    builtInTools: Set<GeminiBuiltInTool> = []
  ) throws -> Built {
    var system: String?

    // The framework records one model turn as several consecutive entries
    // (reasoning, response, tool calls); they are replayed together.
    var pieces: [Piece] = []
    var turn: [Transcript.Entry] = []
    func closeTurn() {
      if !turn.isEmpty { pieces.append(.turn(turn)) }
      turn = []
    }
    for entry in request.transcript {
      switch entry {
      case .response, .reasoning, .toolCalls:
        turn.append(entry)
      case .instructions(let instructions):
        closeTurn()
        let text = text(of: instructions.segments)
        if !text.isEmpty {
          system = (system.map { $0 + "\n\n" } ?? "") + text
        }
      case .prompt(let prompt):
        closeTurn()
        let content = try contentBlocks(from: prompt.segments)
        if !content.isEmpty {
          pieces.append(.user(["type": "user_input", "content": .array(content)]))
        }
      case .toolOutput(let output):
        closeTurn()
        pieces.append(
          .toolResult(
            id: output.id,
            [
              "type": "function_result",
              "call_id": .string(output.id),
              "name": .string(output.toolName),
              "result": try toolResult(from: output.segments),
            ]
          )
        )
      default:
        break
      }
    }
    closeTurn()

    let pairing = ToolPairing(pieces)
    var input: [JSONValue] = []
    for piece in pieces {
      switch piece {
      case .user(let step):
        input.append(step)
      case .toolResult(let id, let step):
        if pairing.accepts(resultOf: id) { input.append(step) }
      case .turn(let entries):
        input += steps(of: entries, pairing: pairing)
      }
    }

    var body: JSONObject = ["model": .string(model.id)]
    if let system { body["system_instruction"] = .string(system) }
    body["input"] = .array(input)

    let functions = request.enabledToolDefinitions.map(functionDefinition)
    let tools =
      functions
      + builtInTools.sorted { $0.rawValue < $1.rawValue }.map { ["type": .string($0.rawValue)] }
    if !tools.isEmpty { body["tools"] = .array(tools) }

    let config = generationConfig(
      request: request,
      model: model,
      fixedLevel: fixedLevel,
      thoughtSummaries: thoughtSummaries,
      hasTools: !tools.isEmpty
    )
    if !config.isEmpty { body["generation_config"] = .object(config) }

    if let schema = request.schema {
      // A schema is a contract, not a hint: without constrained decoding
      // the response may not decode at all.
      guard model.capabilities.structuredOutput else {
        throw LanguageModelError.unsupportedGenerationGuide(
          .init(
            schemaName: nil,
            debugDescription: "\(model.id) does not support structured output."
          )
        )
      }
      body["response_format"] = [
        "type": "text",
        "mime_type": "application/json",
        "schema": jsonSchema(from: schema),
      ]
    }
    body["store"] = false
    return Built(body: .object(body), isStructured: request.schema != nil)
  }

  // MARK: - Generation config

  private static func generationConfig(
    request: LanguageModelExecutorGenerationRequest,
    model: GeminiModel,
    fixedLevel: GeminiModel.ThinkingLevel?,
    thoughtSummaries: Bool,
    hasTools: Bool
  ) -> JSONObject {
    var config = JSONObject()
    let options = request.generationOptions
    if !model.capabilities.thinkingLevels.isEmpty {
      if let level = fixedLevel ?? requestedLevel(request.contextOptions, model: model) {
        config["thinking_level"] = .string(level.rawValue)
      }
      config["thinking_summaries"] = .string(thoughtSummaries ? "auto" : "none")
    }
    if hasTools, let mode = options.toolCallingMode {
      switch mode.kind {
      case .required: config["tool_choice"] = "any"
      case .disallowed: config["tool_choice"] = "none"
      case .allowed: break
      @unknown default: break
      }
    }
    if let maximum = options.maximumResponseTokens {
      config["max_output_tokens"] = .number(Double(maximum))
    }
    // Sampling is a hint. Newer models ignore `temperature` and `top_p`, so
    // they are only sent to models that honor them; the API rejects `top_k`.
    if model.capabilities.samplingParams, let temperature = options.temperature {
      config["temperature"] = .number(temperature)
    }
    switch options.samplingMode?.kind {
    case .greedy:
      if model.capabilities.samplingParams { config["temperature"] = 0 }
    case .randomTopK(_, let seed):
      // The API rejects `top_k`.
      if let seed { config["seed"] = .number(Double(seed)) }
    case .randomProbabilityThreshold(let threshold, let seed):
      if model.capabilities.samplingParams { config["top_p"] = .number(threshold) }
      if let seed { config["seed"] = .number(Double(seed)) }
    default:
      break
    }
    return config
  }

  /// The framework's reasoning hint as a level the model accepts: dropped
  /// when there is none, clamped to the closest level otherwise.
  static func requestedLevel(
    _ options: ContextOptions,
    model: GeminiModel
  ) -> GeminiModel.ThinkingLevel? {
    let requested: GeminiModel.ThinkingLevel? =
      switch options.reasoningLevel {
      case .none: nil
      case .light: .low
      case .moderate: .medium
      case .deep: .high
      // Escape hatch: a custom level naming a Gemini level ("minimal",
      // "xhigh") maps directly; anything else is dropped.
      case .custom(let level): GeminiModel.ThinkingLevel(rawValue: level)
      @unknown default: nil
      }
    return requested.flatMap { model.closestThinkingLevel(to: $0) }
  }

  // MARK: - Schema → JSON Schema

  /// `GenerationSchema` is `Codable` and encodes as JSON Schema with
  /// framework-specific keys. Keys the API doesn't document are dropped, and
  /// the framework's `x-order` puts the properties in their declared order:
  /// the model generates properties in schema order.
  static func jsonSchema(from schema: GenerationSchema) -> JSONValue {
    guard let value = JSONValue.encoded(schema) else {
      return ["type": "object"]
    }
    return sanitize(value)
  }

  private static let allowedSchemaKeys: Set<String> = [
    "type", "properties", "required", "items", "prefixItems", "enum", "const",
    "anyOf", "oneOf", "allOf", "$ref", "$defs", "definitions", "description", "title",
    "format", "additionalProperties", "minimum", "maximum", "minItems", "maxItems",
    "pattern",
  ]

  /// Keys whose values map arbitrary names to schemas.
  private static let mapValuedKeys: Set<String> = ["properties", "$defs", "definitions"]

  private static func sanitize(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let object):
      var out = JSONObject()
      for (key, member) in object where allowedSchemaKeys.contains(key) {
        if mapValuedKeys.contains(key), case .object(var nested) = member {
          if key == "properties", let order = object["x-order"]?.arrayValue {
            nested.reorder(order.compactMap(\.stringValue))
          }
          out[key] = .object(nested.mapValues(sanitize))
        } else {
          out[key] = sanitize(member)
        }
      }
      return .object(out)
    case .array(let array):
      return .array(array.map(sanitize))
    default:
      return value
    }
  }

  // MARK: - Model turns

  private enum Piece {
    case user(JSONValue)
    case toolResult(id: String, JSONValue)
    case turn([Transcript.Entry])
  }

  /// The steps of one model turn: the recorded steps of its entries in the
  /// order the API produced them, with any entry that has no record rebuilt
  /// from what the framework holds.
  ///
  /// Recorded steps sort by their position; entries recorded in a different
  /// turn come after everything before them; rebuilt steps follow whatever
  /// preceded them; text cut off mid-step was the last thing its turn
  /// produced.
  private static func steps(of entries: [Transcript.Entry], pairing: ToolPairing) -> [JSONValue] {
    typealias Ordered = (order: (group: Int, rank: Double), step: JSONValue)
    var ordered: [Ordered] = []
    var group = 0
    var turn: String?
    var latest = -1.0

    func add(_ record: StepRecord, orRebuild rebuild: () -> [JSONValue]) {
      guard !record.isEmpty else {
        ordered += rebuild().map { ((group, latest + 0.5), $0) }
        return
      }
      if let turn, turn != record.turn { (group, latest) = (group + 1, -1) }
      turn = record.turn
      for step in record.steps {
        if step.type != "function_call" || pairing.accepts(call: step.json["id"]?.stringValue ?? "") {
          ordered.append(((group, Double(step.position)), step.json))
        }
        latest = max(latest, Double(step.position))
      }
    }

    for entry in entries {
      switch entry {
      case .response(let response):
        let record = StepRecord(metadata: response.metadata)
        add(record) {
          let text = text(of: response.segments, separator: "")
          guard text.contains(where: { !$0.isWhitespace }) else { return [] }
          return [modelOutput(text)]
        }
        if !record.isEmpty {
          ordered += unfinishedText(of: response, beyond: record).map { ((group, .infinity), $0) }
        }
      case .reasoning(let reasoning):
        // A thought is only worth anything to the API with the signature it
        // was produced with, and only the record has it in its original
        // form. Thoughts of other models are dropped.
        add(StepRecord(metadata: reasoning.metadata)) { [] }
      case .toolCalls(let calls):
        for call in calls {
          add(StepRecord(metadata: call.metadata)) {
            guard pairing.accepts(call: call.id) else { return [] }
            return [
              [
                "type": "function_call",
                "id": .string(call.id),
                "name": .string(call.toolName),
                "arguments": toolArguments(call.arguments),
              ]
            ]
          }
        }
      default:
        break
      }
    }
    // `sorted` is stable, so steps sharing an order keep entry order.
    return ordered.sorted { $0.order < $1.order }.map(\.step)
  }

  private static func modelOutput(_ text: String) -> JSONValue {
    ["type": "model_output", "content": [["type": "text", "text": .string(text)]]]
  }

  /// The answer text that streamed after the response's last completed
  /// `model_output` step; there is some only when generation was stopped
  /// mid-answer. Each step streams into a text segment of its own, so it is
  /// whatever the prose segments (those not holding a built-in tool call's
  /// place) hold past the recorded ones.
  private static func unfinishedText(
    of response: Transcript.Response,
    beyond record: StepRecord
  ) -> [JSONValue] {
    var recorded = 0
    var placeholders: Set<String> = []
    for step in record.steps {
      if step.type == "model_output" {
        recorded += 1
      } else if let id = step.json["id"]?.stringValue {
        placeholders.insert(id)
      }
    }
    let pending = response.segments
      .compactMap { segment -> String? in
        guard case .text(let text) = segment, !placeholders.contains(text.id) else { return nil }
        return text.content
      }
      .dropFirst(recorded)
      .joined()
    return pending.contains { !$0.isWhitespace } ? [modelOutput(pending)] : []
  }

  /// Which function calls and results the API will accept back: a call needs
  /// its result in the transcript, and a result its call. Anything unpaired
  /// (a turn stopped before the tool ran, a call the app trimmed from
  /// history) replays as nothing rather than failing every later request.
  private struct ToolPairing {
    private var calls: Set<String> = []
    private var answered: Set<String> = []

    init(_ pieces: [Piece]) {
      for piece in pieces {
        switch piece {
        case .turn(let entries):
          for case .toolCalls(let toolCalls) in entries {
            calls.formUnion(toolCalls.map(\.id))
          }
        case .toolResult(let id, _):
          answered.insert(id)
        case .user:
          break
        }
      }
    }

    func accepts(call id: String) -> Bool { answered.contains(id) }
    func accepts(resultOf id: String) -> Bool { calls.contains(id) }
  }

  // MARK: - Content

  private static func text(of segments: [Transcript.Segment], separator: String = "\n") -> String {
    segments.compactMap {
      switch $0 {
      case .text(let text): text.content
      case .structure(let structure): structure.content.jsonString
      case .attachment: nil
      @unknown default: nil
      }
    }
    .joined(separator: separator)
  }

  static func contentBlocks(from segments: [Transcript.Segment]) throws -> [JSONValue] {
    try segments.flatMap { segment -> [JSONValue] in
      switch segment {
      case .text(let text) where !text.content.isEmpty:
        [["type": "text", "text": .string(text.content)]]
      case .text:
        []
      case .structure(let structure):
        [["type": "text", "text": .string(structure.content.jsonString)]]
      case .attachment(let attachment):
        switch attachment.content {
        case .image(let image):
          [try GeminiMedia.imageBlock(image.cgImage, orientation: image.orientation)]
        case .data(let data):
          [try GeminiMedia.dataBlock(data.content, type: data.contentType)]
        @unknown default:
          []
        }
      @unknown default:
        []
      }
    }
  }

  /// A tool's output as a `function_result` result: a string when it is
  /// text only, content blocks when it carries attachments.
  private static func toolResult(from segments: [Transcript.Segment]) throws -> JSONValue {
    let blocks = try contentBlocks(from: segments)
    let texts = blocks.compactMap { block -> String? in
      block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
    }
    return texts.count == blocks.count ? .string(texts.joined(separator: "\n")) : .array(blocks)
  }

  private static func toolArguments(_ arguments: GeneratedContent) -> JSONValue {
    let value = JSONValue(arguments)
    return if case .object = value { value } else { [:] }
  }

  private static func functionDefinition(_ definition: Transcript.ToolDefinition) -> JSONValue {
    [
      "type": "function",
      "name": .string(definition.name),
      "description": .string(definition.description),
      "parameters": jsonSchema(from: definition.parameters),
    ]
  }
}
