// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization

/// Thin HTTP client for the Gemini API: streamed `POST /v1beta/interactions`
/// and the model catalog.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
package struct GeminiClient: Sendable {
  package struct Configuration: Sendable, Hashable {
    package var baseURL: URL
    /// The API version path segment.
    package var apiVersion: String
    /// Headers sent with every request: the credential (`x-goog-api-key`) or
    /// a proxy's headers.
    package var headers: [String: String]
    /// A stream that delivers no event for this long fails with
    /// `URLError(.timedOut)`. `URLSession`'s request timeout doesn't catch a
    /// stream that the server holds open with keep-alive traffic. `nil`
    /// disables the check.
    package var idleTimeout: TimeInterval?

    package init(
      baseURL: URL,
      apiVersion: String = "v1beta",
      headers: [String: String] = [:],
      idleTimeout: TimeInterval? = nil
    ) {
      self.baseURL = baseURL
      self.apiVersion = apiVersion
      self.headers = headers
      self.idleTimeout = idleTimeout
    }
  }

  package let configuration: Configuration
  private let transport: any HTTPTransport

  package init(configuration: Configuration, transport: any HTTPTransport) {
    self.configuration = configuration
    self.transport = transport
  }

  package init(configuration: Configuration, session: URLSession = .shared) {
    self.init(configuration: configuration, transport: URLSessionTransport(session: session))
  }

  // MARK: - Interactions

  /// Streams an interaction. `body` is the request body; `stream` is set to
  /// `true`. HTTP error statuses and SSE `error` events both surface by
  /// throwing ``APIError`` from the stream.
  package func stream(_ body: JSONValue) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let activity = Activity()
      let task = Task {
        do {
          var object = body.objectValue ?? [:]
          object["stream"] = true
          let request = urlRequest(
            path: "interactions",
            method: "POST",
            body: .object(object),
            accept: "text/event-stream"
          )
          let (bytes, response) = try await transport.bytes(for: request)
          if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw APIError(status: http.statusCode, body: data)
          }
          for try await frame in SSEParser.frames(from: bytes) {
            try Task.checkCancellation()
            activity.touch()
            if frame.data == "[DONE]" { break }
            continuation.yield(try StreamEvent(frame: frame))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      let watchdog = configuration.idleTimeout.map { limit in
        Task {
          let limit = Duration.milliseconds(Int64(limit * 1000))
          while !Task.isCancelled {
            try? await Task.sleep(for: min(limit / 4, .seconds(5)))
            if activity.idle > limit {
              // Finish first: the cancelled reader would end the stream
              // without an error.
              continuation.finish(throwing: URLError(.timedOut))
              task.cancel()
              return
            }
          }
        }
      }
      continuation.onTermination = { _ in
        task.cancel()
        watchdog?.cancel()
      }
    }
  }

  /// When a stream last delivered something.
  private final class Activity: Sendable {
    private let last = Mutex(ContinuousClock.now)

    func touch() {
      last.withLock { $0 = .now }
    }

    var idle: Duration {
      ContinuousClock.now - last.withLock { $0 }
    }
  }

  // MARK: - Models

  /// All models of the catalog (`GET /models`), following pagination.
  package func models() async throws -> [JSONValue] {
    var models: [JSONValue] = []
    var token: String?
    repeat {
      var query = [URLQueryItem(name: "pageSize", value: "1000")]
      if let token { query.append(URLQueryItem(name: "pageToken", value: token)) }
      let page = try await get("models", query: query)
      models += page["models"]?.arrayValue ?? []
      token = page["nextPageToken"]?.stringValue
    } while token?.isEmpty == false
    return models
  }

  /// One model of the catalog (`GET /models/{id}`).
  package func model(id: String) async throws -> JSONValue {
    try await get("models/\(id)")
  }

  // MARK: - Private

  private func get(_ path: String, query: [URLQueryItem] = []) async throws -> JSONValue {
    var request = urlRequest(path: path, method: "GET", body: nil, accept: "application/json")
    if !query.isEmpty, let url = request.url {
      request.url = url.appending(queryItems: query)
    }
    let (data, response) = try await transport.data(for: request)
    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
      throw APIError(status: http.statusCode, body: data)
    }
    return try JSONValue.parse(data)
  }

  package func urlRequest(
    path: String,
    method: String,
    body: JSONValue?,
    accept: String
  ) -> URLRequest {
    let url = configuration.baseURL
      .appending(path: configuration.apiVersion)
      .appending(path: path)
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue(accept, forHTTPHeaderField: "Accept")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = body.jsonData
    }
    for (name, value) in configuration.headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
    return request
  }
}
