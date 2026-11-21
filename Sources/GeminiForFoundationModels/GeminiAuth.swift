// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How requests authenticate.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public enum GeminiAuth: Sendable, Hashable {
  /// A Gemini API key, sent in the `x-goog-api-key` header. Fine for
  /// prototyping and tools; an app shipped to users should not embed a key.
  case apiKey(String)
  /// No key: the headers are sent as they are to a developer-run relay at a
  /// custom base URL, which adds the credential server-side.
  case proxied(headers: [String: String] = [:])

  /// The headers this mode sends. Throws ``GeminiError/missingCredential``
  /// for an empty API key.
  func headers() throws -> [String: String] {
    switch self {
    case .apiKey(let key):
      let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty else { throw GeminiError.missingCredential }
      return ["x-goog-api-key": key]
    case .proxied(let headers):
      return headers
    }
  }
}

/// A tool that runs on Google's infrastructure. Its calls and results are
/// recorded in the transcript (see ``GeminiToolActivity``); unlike the
/// framework's `tools:`, the app doesn't execute it.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public enum GeminiBuiltInTool: String, Sendable, Hashable, CaseIterable {
  /// Grounding with Google Search.
  case googleSearch = "google_search"
  /// Reading the pages at URLs given in the prompt.
  case urlContext = "url_context"
  /// Running Python code in a sandbox.
  case codeExecution = "code_execution"
}

/// Errors of the bridge that have no counterpart in `LanguageModelError`.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public enum GeminiError: Error, Sendable, Equatable {
  /// No API key was configured.
  case missingCredential
  /// The API rejected the API key.
  case invalidCredential
  /// The fixed thinking level isn't one the model accepts.
  case unsupportedThinkingLevel(model: String, level: GeminiModel.ThinkingLevel)
  /// The response stopped before it was complete (`incomplete`), e.g. at
  /// the output token limit, so a structured response can't be decoded.
  case incompleteResponse
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
extension GeminiError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .missingCredential:
      "No Gemini API key was provided."
    case .invalidCredential:
      "The Gemini API key is not valid."
    case .unsupportedThinkingLevel(let model, let level):
      "\(model) does not accept the thinking level '\(level.rawValue)'."
    case .incompleteResponse:
      "The response is incomplete; the output token limit may have been reached."
    }
  }
}

/// An error the Gemini API reported, for which the framework's
/// `LanguageModelError` has no equivalent.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct GeminiAPIError: Error, Sendable, Equatable {
  /// HTTP status, when the error came with one.
  public let status: Int?
  /// The API's error code, e.g. `invalid_request`, `not_found`, or
  /// `payment_required`.
  public let code: String
  public let message: String

  public init(status: Int?, code: String, message: String) {
    self.status = status
    self.code = code
    self.message = message
  }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
extension GeminiAPIError: LocalizedError {
  public var errorDescription: String? {
    "\(message) (\(code))"
  }
}
