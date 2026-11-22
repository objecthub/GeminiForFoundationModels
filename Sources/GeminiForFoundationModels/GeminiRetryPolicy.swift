// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GeminiAPI

/// How often a request is sent again after a temporary failure.
///
/// A request is only retried while nothing of its response has reached the
/// session, never after cancellation, and only for failures that a second
/// attempt can fix: rate limits and exhausted quotas (`RESOURCE_EXHAUSTED`),
/// overloaded or failing servers (408, 500, 503, 504), failed interactions,
/// and lost connections, including a stream that stalled. Depleted prepaid
/// credits (402), invalid requests, invalid credentials, and blocked content
/// fail immediately.
///
/// The wait before a retry is the one the server asks for (`RetryInfo`), or
/// else an exponential backoff with jitter (about 0.5 s, 1 s, 2 s, …). If the
/// server asks for longer than ``maxDelay``, the request fails right away with
/// the server's reset time, so the app decides whether to wait.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct GeminiRetryPolicy: Sendable, Hashable {
  /// How often a request is sent again at most.
  public var maxRetries: Int
  /// The longest wait before a retry, in seconds.
  public var maxDelay: TimeInterval

  public init(maxRetries: Int = 2, maxDelay: TimeInterval = 20) {
    self.maxRetries = max(0, maxRetries)
    self.maxDelay = maxDelay
  }

  /// Two retries, waiting at most 20 seconds each.
  public static let `default` = GeminiRetryPolicy()
  /// No retries.
  public static let disabled = GeminiRetryPolicy(maxRetries: 0)

  /// The wait before retry `retry` (counting from 1) when the server asks
  /// for none; `jitter` is a factor around 1.
  static func backoff(_ retry: Int, jitter: Double) -> TimeInterval {
    0.5 * pow(2, Double(max(0, retry - 1))) * jitter
  }

  /// Whether a second attempt can fix `error`.
  static func isTemporary(_ error: any Error) -> Bool {
    if let api = error as? APIError {
      switch api.kind {
      case .rateLimit, .overloaded, .server, .timeout: return true
      default: return false
      }
    }
    if let url = error as? URLError {
      switch url.code {
      case .networkConnectionLost, .timedOut, .cannotConnectToHost: return true
      default: return false
      }
    }
    return false
  }
}
