// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// An error reported by the Gemini API.
///
/// The API reports errors in two shapes. The Interactions API uses
/// `{"error": {"code": "<snake_case>", "message": ...}}`, sent as JSON or as
/// an SSE `error` event. Google's front end uses the RPC shape
/// `[{"error": {"code": <http status>, "status": "<RPC_STATUS>", "message":
/// ..., "details": [...]}}]`, e.g. for an invalid API key. Both are read
/// here.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
package struct APIError: Error, Sendable, Equatable {
  package enum Kind: Sendable, Equatable {
    case invalidRequest
    case authentication
    case paymentRequired
    case permission
    case notFound
    case rateLimit
    case overloaded
    case timeout
    case server
    /// The request or the response was blocked (safety, recitation, …).
    case blocked
    case other
  }

  /// HTTP status, when the error came with one.
  package var status: Int?
  /// The API's error code in snake case, e.g. `invalid_request` or
  /// `resource_exhausted`.
  package var code: String
  package var message: String
  /// `reason` of an attached `google.rpc.ErrorInfo`, e.g. `API_KEY_INVALID`.
  package var reason: String?
  /// `retryDelay` of an attached `google.rpc.RetryInfo`.
  package var retryDelay: TimeInterval?

  package init(
    status: Int?,
    code: String,
    message: String,
    reason: String? = nil,
    retryDelay: TimeInterval? = nil
  ) {
    self.status = status
    self.code = code
    self.message = message
    self.reason = reason
    self.retryDelay = retryDelay
  }

  package var kind: Kind {
    if reason == "API_KEY_INVALID" || reason == "API_KEY_EXPIRED" { return .authentication }
    switch code {
    case "invalid_request", "invalid_argument", "failed_precondition", "parameter_unknown",
      "out_of_range":
      return .invalidRequest
    case "authentication", "unauthenticated":
      return .authentication
    case "payment_required":
      return .paymentRequired
    case "permission_denied":
      return .permission
    case "not_found", "model_not_found":
      return .notFound
    case "rate_limit_exceeded", "quota_exceeded", "too_many_requests":
      return .rateLimit
    case "resource_exhausted":
      // Google reports depleted prepaid credits as RESOURCE_EXHAUSTED with
      // HTTP 402: retrying won't help.
      return status == 402 ? .paymentRequired : .rateLimit
    case "service_unavailable", "unavailable", "overloaded":
      return .overloaded
    case "deadline_exceeded", "timeout":
      return .timeout
    case "api_error", "internal", "unknown":
      return .server
    case "safety", "recitation", "language", "prohibited_content", "spii", "blocklist",
      "image_safety", "image_prohibited_content", "image_recitation", "image_other",
      "content_blocked":
      return .blocked
    default:
      break
    }
    switch status {
    case 400: return .invalidRequest
    case 401: return .authentication
    case 402: return .paymentRequired
    case 403: return .permission
    case 404: return .notFound
    case 408, 504: return .timeout
    case 429: return .rateLimit
    case 503: return .overloaded
    case let status? where status >= 500: return .server
    default: return .other
    }
  }

  /// The error in an error object (`{"code": ..., "message": ...}` with
  /// optional `status` and `details`).
  package init(status: Int?, error: JSONValue) {
    let message = error["message"]?.stringValue ?? "Unknown error"
    var httpStatus = status
    var code: String
    if let text = error["code"]?.stringValue {
      code = text
    } else if let rpcStatus = error["status"]?.stringValue {
      code = rpcStatus.lowercased()
    } else {
      code = "unknown"
    }
    if let number = error["code"]?.intValue {
      httpStatus = httpStatus ?? number
      if error["status"] == nil { code = Self.code(forStatus: number) }
    }
    var reason: String?
    var retryDelay: TimeInterval?
    for detail in error["details"]?.arrayValue ?? [] {
      let type = detail["@type"]?.stringValue ?? ""
      if type.hasSuffix("google.rpc.ErrorInfo") {
        reason = detail["reason"]?.stringValue
      } else if type.hasSuffix("google.rpc.RetryInfo"),
        let delay = detail["retryDelay"]?.stringValue
      {
        retryDelay = TimeInterval(delay.hasSuffix("s") ? String(delay.dropLast()) : delay)
      }
    }
    self.init(
      status: httpStatus,
      code: code,
      message: message,
      reason: reason,
      retryDelay: retryDelay
    )
  }

  /// The error in a response body: JSON in either shape, or SSE frames one
  /// of which is an `error` event. A body that can't be read yields an
  /// error describing the HTTP status.
  package init(status: Int, body: Data) {
    let text = String(decoding: body, as: UTF8.self)
    if let json = JSONValue.parsed(text), let error = Self.errorObject(in: json) {
      self.init(status: status, error: error)
      return
    }
    for frame in SSEParser.frames(in: text) {
      if let json = JSONValue.parsed(frame.data), let error = Self.errorObject(in: json) {
        self.init(status: status, error: error)
        return
      }
    }
    let snippet = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)
    self.init(
      status: status,
      code: Self.code(forStatus: status),
      message: snippet.isEmpty
        ? HTTPURLResponse.localizedString(forStatusCode: status) : String(snippet)
    )
  }

  private static func errorObject(in json: JSONValue) -> JSONValue? {
    if let error = json["error"], case .object = error { return error }
    if let first = json[0] { return errorObject(in: first) }
    return nil
  }

  private static func code(forStatus status: Int) -> String {
    switch status {
    case 400: "invalid_request"
    case 401: "authentication"
    case 402: "payment_required"
    case 403: "permission_denied"
    case 404: "not_found"
    case 408: "timeout"
    case 429: "too_many_requests"
    case 500: "api_error"
    case 503: "service_unavailable"
    case 504: "deadline_exceeded"
    default: "http_\(status)"
    }
  }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
extension APIError: LocalizedError {
  package var errorDescription: String? {
    "\(message) (\(code))"
  }
}
