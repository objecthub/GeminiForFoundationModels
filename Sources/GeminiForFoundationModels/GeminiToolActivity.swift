// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import GeminiAPI

/// A built-in tool's call and result, read back out of a transcript.
///
/// Built-in tools (see ``GeminiBuiltInTool``) run on Google's side. Their
/// steps are recorded on the response entry of the turn, and an empty text
/// segment whose ID is the call's ID holds the call's place among the
/// response's prose.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct GeminiToolActivity: Sendable, Hashable {
  public enum Kind: Sendable, Hashable {
    case googleSearch
    case urlContext
    case codeExecution
    /// Another built-in tool, by the type of its call step without the
    /// `_call` suffix.
    case other(String)
  }

  public let kind: Kind
  /// The call's ID; also the ID of its placeholder segment.
  public let id: String
  /// The call's arguments as JSON text, e.g. `{"queries":[...]}`,
  /// `{"urls":[...]}`, or `{"language":"python","code":"..."}`.
  public let arguments: String
  /// The result as JSON text, or `nil` when no result was recorded.
  public let result: String?
  /// Whether the tool reported an error.
  public let isError: Bool

  /// The search queries of a Google Search call.
  public var queries: [String] {
    argument("queries")?.arrayValue?.compactMap(\.stringValue) ?? []
  }

  /// The URLs of a URL context call.
  public var urls: [String] {
    argument("urls")?.arrayValue?.compactMap(\.stringValue) ?? []
  }

  /// The code of a code execution call.
  public var code: String? {
    argument("code")?.stringValue
  }

  /// The output of a code execution, when the result is text.
  public var output: String? {
    result.flatMap { JSONValue.parsed($0)?.stringValue }
  }

  private func argument(_ name: String) -> JSONValue? {
    JSONValue.parsed(arguments)?[name]
  }

  /// The built-in tool activities of a response entry, in the order the
  /// model made the calls.
  public static func activities(in response: Transcript.Response) -> [GeminiToolActivity] {
    let steps = StepRecord(metadata: response.metadata).steps.sorted { $0.position < $1.position }
    var results: [String: JSONValue] = [:]
    for step in steps where step.type.hasSuffix("_result") && step.type != "function_result" {
      if let id = step.json["call_id"]?.stringValue { results[id] = step.json }
    }
    return steps.compactMap { step in
      let type = step.type
      guard type.hasSuffix("_call"), type != "function_call",
        let id = step.json["id"]?.stringValue
      else { return nil }
      let name = String(type.dropLast(5))
      let kind: Kind =
        switch name {
        case "google_search": .googleSearch
        case "url_context": .urlContext
        case "code_execution": .codeExecution
        default: .other(name)
        }
      let result = results[id]
      return GeminiToolActivity(
        kind: kind,
        id: id,
        arguments: (step.json["arguments"] ?? [:]).jsonText,
        result: result?["result"]?.jsonText,
        isError: result?["is_error"]?.boolValue ?? false
      )
    }
  }

  /// The built-in tool activities of every response entry of `transcript`.
  public static func activities(in transcript: Transcript) -> [GeminiToolActivity] {
    transcript.flatMap { entry -> [GeminiToolActivity] in
      if case .response(let response) = entry { activities(in: response) } else { [] }
    }
  }
}
