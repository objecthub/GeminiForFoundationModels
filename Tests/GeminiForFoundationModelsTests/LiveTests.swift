// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import FoundationModels
import Testing

@testable import GeminiForFoundationModels

/// Tests against the real API. They run only when `GEMINI_API_KEY` is set;
/// `GEMINI_TEST_MODEL` picks the model (default `gemini-3.8-flash`).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GEMINI_API_KEY"]?.isEmpty == false))
struct LiveTests {
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  private func model(builtInTools: Set<GeminiBuiltInTool> = []) throws -> GeminiLanguageModel {
    let env = ProcessInfo.processInfo.environment
    let id = env["GEMINI_TEST_MODEL"] ?? "gemini-3.8-flash"
    let name =
      GeminiModel.named(id)
      ?? GeminiModel(id: id, capabilities: .init(thinkingLevels: [.low, .medium, .high]))
    return try GeminiLanguageModel(
      name: name,
      auth: .apiKey(env["GEMINI_API_KEY"] ?? ""),
      builtInTools: builtInTools
    )
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `responds and remembers the conversation`() async throws {
    let session = LanguageModelSession(model: try model(), instructions: "Answer in one short sentence.")
    let first = try await session.respond(to: "My favorite city is Kyoto. What country is it in?")
    #expect(first.content.localizedCaseInsensitiveContains("Japan"))
    let second = try await session.respond(to: "Which city did I name?")
    #expect(second.content.localizedCaseInsensitiveContains("Kyoto"))
    #expect(session.usage.input.totalTokenCount > 0)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `streams snapshots`() async throws {
    let session = LanguageModelSession(model: try model())
    var count = 0
    var last = ""
    for try await snapshot in session.streamResponse(to: "Describe the sea in four sentences.") {
      #expect(snapshot.content.hasPrefix(String(last.prefix(snapshot.content.count))))
      last = snapshot.content
      count += 1
    }
    #expect(count >= 2)
    #expect(last.count > 40)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `calls tools and continues with their results`() async throws {
    let tool = ConvertTool()
    let session = LanguageModelSession(
      model: try model(),
      tools: [tool],
      instructions: "Use the convertCurrency tool to convert amounts."
    )
    let first = try await session.respond(to: "How much are 80 US dollars in Swiss francs and in euros?")
    #expect(Set(tool.calledCurrencies).isSuperset(of: ["CHF", "EUR"]))
    #expect(first.content.contains("70.4"))
    // The next turn replays the tool loop, thoughts included.
    let second = try await session.respond(to: "And in Japanese yen?")
    #expect(tool.calledCurrencies.contains("JPY"))
    #expect(second.content.contains("12") && second.content.contains("160"))
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `generates nested structured content`() async throws {
    let session = LanguageModelSession(model: try model(), instructions: "You are a concise travel assistant.")
    for city in ["Lisbon", "Kyoto", "Lima"] {
      let response = try await session.respond(to: "Plan a short trip to \(city).", generating: Itinerary.self)
      #expect(response.content.city.contains(city))
      #expect(!response.content.days.isEmpty)
      #expect(response.content.days.allSatisfy { !$0.title.isEmpty && !$0.activities.isEmpty })
    }
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `generates structured content after built-in tool use`() async throws {
    // Structured requests leave the built-in tools out; the earlier turn's
    // code execution steps are still replayed.
    let session = LanguageModelSession(model: try model(builtInTools: [.codeExecution]))
    _ = try await session.respond(to: "Use code execution to compute 2 to the power of 20.")
    #expect(!GeminiToolActivity.activities(in: session.transcript).isEmpty)
    for city in ["Lisbon", "Porto"] {
      let response = try await session.respond(to: "Plan a short trip to \(city).", generating: Itinerary.self)
      #expect(response.content.city.contains(city))
      #expect(!response.content.days.isEmpty)
    }
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `reasons with summaries across turns`() async throws {
    let session = LanguageModelSession(model: try model())
    let options = ContextOptions(reasoningLevel: .deep)
    _ = try await session.respond(
      to: "A bat and a ball cost $1.10. The bat costs $1.00 more than the ball. What does the ball cost?",
      contextOptions: options
    )
    let reasoning = session.transcript.filter { if case .reasoning = $0 { true } else { false } }
    #expect(!reasoning.isEmpty)
    let second = try await session.respond(to: "And the bat?", contextOptions: options)
    #expect(second.content.contains("1.05"))
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `sees images`() async throws {
    let context = CGContext(
      data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let session = LanguageModelSession(model: try model())
    let response = try await session.respond(
      to: Prompt {
        "What color is this image? Answer with one word."
        Attachment(context.makeImage()!)
      }
    )
    #expect(response.content.localizedCaseInsensitiveContains("blue"))
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `runs code server-side and replays it`() async throws {
    let session = LanguageModelSession(model: try model(builtInTools: [.codeExecution]))
    let response = try await session.respond(to: "Use code execution to compute the sum of the first 50 primes.")
    #expect(response.content.contains("5117") || response.content.contains("5,117"))
    let activities = GeminiToolActivity.activities(in: session.transcript)
    #expect(activities.contains { $0.kind == .codeExecution && $0.code != nil })
    let followup = try await session.respond(to: "What was the 50th prime?")
    #expect(followup.content.contains("229"))
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `lists the model catalog`() async throws {
    let env = ProcessInfo.processInfo.environment
    let models = try await GeminiModel.available(auth: .apiKey(env["GEMINI_API_KEY"] ?? ""))
    #expect(models.contains { $0.id == "gemini-3.8-flash" })
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `an invalid key is reported as such`() async throws {
    let model = try GeminiLanguageModel(name: .gemini3_8Flash, auth: .apiKey("AIza-invalid-test-key"))
    let session = LanguageModelSession(model: model)
    await #expect(throws: GeminiError.invalidCredential) {
      _ = try await session.respond(to: "hi")
    }
  }
}
