// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import GeminiAPI

/// Maps API failures onto the framework's typed errors so apps can
/// pattern-match on well-known cases.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
enum ErrorMapper {
  static func map(_ error: any Error) -> any Error {
    if let api = error as? APIError {
      return map(api)
    }
    if let url = error as? URLError, url.code == .timedOut {
      return LanguageModelError.timeout(.init(debugDescription: url.localizedDescription))
    }
    if let media = error as? GeminiMedia.Error {
      return LanguageModelError.unsupportedTranscriptContent(
        .init(
          unsupportedContent: [],
          debugDescription: media.errorDescription ?? "Attachment could not be prepared for upload."
        )
      )
    }
    if let transport = error as? HTTPTransportError {
      return GeminiAPIError(
        status: nil,
        code: "redirect_refused",
        message: transport.errorDescription ?? "Refused a redirect."
      )
    }
    return error
  }

  static func map(_ error: APIError) -> any Error {
    let detail = error.message
    switch error.kind {
    case .rateLimit, .overloaded:
      return LanguageModelError.rateLimited(
        .init(
          resetDate: error.retryDelay.map { Date(timeIntervalSinceNow: $0) },
          debugDescription: detail
        )
      )
    case .timeout:
      return LanguageModelError.timeout(.init(debugDescription: detail))
    case .blocked:
      return LanguageModelError.guardrailViolation(.init(debugDescription: detail))
    case .authentication:
      return GeminiError.invalidCredential
    case .invalidRequest where isContextOverflow(error.message):
      // The API reports neither the window nor the prompt's token count.
      return LanguageModelError.contextSizeExceeded(
        .init(contextSize: 0, tokenCount: 0, debugDescription: detail)
      )
    case .invalidRequest, .paymentRequired, .permission, .notFound, .server, .other:
      // No honest framework-error equivalent: surface the API error itself.
      return GeminiAPIError(status: error.status, code: error.code, message: error.message)
    }
  }

  private static func isContextOverflow(_ message: String) -> Bool {
    let message = message.lowercased()
    return message.contains("token")
      && (message.contains("exceed") || message.contains("too long") || message.contains("maximum"))
      && !message.contains("output")
  }
}
