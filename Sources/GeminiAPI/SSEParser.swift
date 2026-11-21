// Copyright 2026 Matthias Zenger
// Adapted from ClaudeForFoundationModels, Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One `text/event-stream` frame: the `event:` name (if any) and the joined
/// `data:` lines.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
package struct SSEFrame: Sendable, Equatable {
  package var event: String?
  package var data: String

  package init(event: String?, data: String) {
    self.event = event
    self.data = data
  }
}

/// Splits a `text/event-stream` byte stream into frames.
///
/// Lines are split here rather than with `AsyncSequence.lines`, which
/// swallows the blank separator: a frame must be emitted the moment its blank
/// line arrives, not when the next frame starts, or every event would be
/// delivered one frame late.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
package enum SSEParser {
  package static func frames(
    from bytes: AsyncThrowingStream<UInt8, Error>
  ) -> AsyncThrowingStream<SSEFrame, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var splitter = Splitter()
          var line: [UInt8] = []
          var previousByteWasCR = false
          // Lines end with LF, CRLF, or CR. A lone LF directly after a CR is
          // the tail of a CRLF, not a new (blank) line.
          for try await byte in bytes {
            switch byte {
            case UInt8(ascii: "\n") where previousByteWasCR:
              previousByteWasCR = false
            case UInt8(ascii: "\n"), UInt8(ascii: "\r"):
              previousByteWasCR = byte == UInt8(ascii: "\r")
              if let frame = splitter.consume(String(decoding: line, as: UTF8.self)) {
                continuation.yield(frame)
              }
              line.removeAll(keepingCapacity: true)
            default:
              previousByteWasCR = false
              line.append(byte)
            }
          }
          if !line.isEmpty, let frame = splitter.consume(String(decoding: line, as: UTF8.self)) {
            continuation.yield(frame)
          }
          if let frame = splitter.flush() { continuation.yield(frame) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// The frames of a complete body, e.g. an error response sent as SSE.
  package static func frames(in text: String) -> [SSEFrame] {
    var splitter = Splitter()
    var frames: [SSEFrame] = []
    text.enumerateLines { line, _ in
      if let frame = splitter.consume(line) { frames.append(frame) }
    }
    if let frame = splitter.flush() { frames.append(frame) }
    return frames
  }

  /// Accumulates the lines of one frame.
  private struct Splitter {
    var event: String?
    var data: [String] = []

    mutating func consume(_ line: String) -> SSEFrame? {
      if line.isEmpty {
        return flush()
      } else if line.hasPrefix("data:") {
        data.append(Self.value(line.dropFirst(5)))
      } else if line.hasPrefix("event:") {
        event = Self.value(line.dropFirst(6))
      }
      // `id:` / `retry:` / `:` comments carry nothing the client needs.
      return nil
    }

    mutating func flush() -> SSEFrame? {
      defer { (event, data) = (nil, []) }
      guard !data.isEmpty else { return nil }
      return SSEFrame(event: event, data: data.joined(separator: "\n"))
    }

    /// A field value: everything after the colon, less one leading space.
    private static func value(_ rest: Substring) -> String {
      String(rest.hasPrefix(" ") ? rest.dropFirst() : rest)
    }
  }
}
