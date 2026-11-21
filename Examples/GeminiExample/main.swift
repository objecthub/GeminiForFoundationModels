// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import GeminiForFoundationModels

// Streams one chat turn against Gemini through `LanguageModelSession`, then
// shows a tool call and guided generation, with token usage at the end.
//
//     GEMINI_API_KEY=<key> swift run GeminiExample "What should I see in Kyoto?"
//
// Pass `--search` to let Gemini ground its answer with Google Search, and
// `--model <id>` to pick a model (default: gemini-3.8-flash).

if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
  await Example.run()
} else {
  print("This example requires macOS 27 or iOS 27.")
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
enum Example {
  static func run() async {
    guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty else {
      fail("Set GEMINI_API_KEY to run this example.")
    }
    var arguments = Array(CommandLine.arguments.dropFirst())
    let search = arguments.contains("--search")
    arguments.removeAll { $0 == "--search" }
    var modelID = "gemini-3.8-flash"
    if let index = arguments.firstIndex(of: "--model"), index + 1 < arguments.count {
      modelID = arguments[index + 1]
      arguments.removeSubrange(index...(index + 1))
    }
    let prompt = arguments.isEmpty ? "Plan a 4-day trip to Buenos Aires." : arguments.joined(separator: " ")

    do {
      let model = try GeminiLanguageModel(
        name: GeminiModel.named(modelID)
          ?? GeminiModel(id: modelID, capabilities: .init(thinkingLevels: [.low, .medium, .high])),
        auth: .apiKey(key),
        builtInTools: search ? [.googleSearch] : []
      )
      let session = LanguageModelSession(
        model: model,
        tools: [ConvertCurrency()],
        instructions: "You are a concise travel assistant. Use convertCurrency to convert money."
      )

      // Snapshots are cumulative; print only what's new since the last one.
      var printed = ""
      for try await snapshot in session.streamResponse(to: prompt) {
        print(snapshot.content.dropFirst(printed.count), terminator: "")
        fflush(stdout)
        printed = snapshot.content
      }
      print("\n")

      let answer = try await session.respond(to: "How much are 80 US dollars in euros?")
      print(answer.content, "\n")

      let plan = try await session.respond(to: "Give me a two-day plan for Lisbon.", generating: Itinerary.self)
      print("Itinerary for \(plan.content.city)")
      for day in plan.content.days {
        print("  \(day.title) ($\(day.budget)): \(day.activities.joined(separator: ", "))")
      }

      for activity in GeminiToolActivity.activities(in: session.transcript) {
        print("[\(activity.kind)] \(activity.queries.joined(separator: "; "))")
      }
      let usage = session.usage
      print(
        "— \(usage.input.totalTokenCount) tokens in (\(usage.input.cachedTokenCount) cached),"
          + " \(usage.output.totalTokenCount) out (\(usage.output.reasoningTokenCount) thinking)"
      )
    } catch {
      fail(error.localizedDescription)
    }
  }

  static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
  }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
struct ConvertCurrency: Tool {
  let name = "convertCurrency"
  let description = "Converts an amount of US dollars into another currency."

  @Generable
  struct Arguments {
    @Guide(description: "Amount in US dollars")
    var amount: Double
    @Guide(description: "Target currency", .anyOf(["EUR", "JPY", "CHF"]))
    var currency: String
  }

  func call(arguments: Arguments) async throws -> String {
    let rates = ["EUR": 0.92, "JPY": 152.0, "CHF": 0.88]
    return String(format: "%.2f %@", arguments.amount * (rates[arguments.currency] ?? 1), arguments.currency)
  }
}

@Generable
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
struct Itinerary {
  var city: String
  @Guide(.count(2...3))
  var days: [Day]

  @Generable
  struct Day {
    var title: String
    var activities: [String]
    @Guide(description: "Budget in US dollars", .range(20...500))
    var budget: Int
  }
}
