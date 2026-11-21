// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A Gemini model and what it accepts. Capabilities decide which request
/// fields the bridge sends: a thinking level the model doesn't offer is a
/// hard 400.
///
/// Use a constant for a compiled-in model, or the initializer with the
/// model's capabilities for any other ID. ``GeminiModel/available(auth:baseURL:timeout:)``
/// lists the models the API offers.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct GeminiModel: Sendable, Hashable {
  public let id: String
  public let capabilities: Capabilities

  public init(id: String, capabilities: Capabilities) {
    self.id = id
    self.capabilities = capabilities
  }

  /// How much the model thinks before it answers (`thinking_level`).
  public enum ThinkingLevel: String, Sendable, Hashable, CaseIterable, Comparable {
    case minimal, low, medium, high, xhigh

    public static func < (a: ThinkingLevel, b: ThinkingLevel) -> Bool {
      allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
  }

  public struct Capabilities: Sendable, Hashable {
    /// The `thinking_level` values the model accepts. Empty means the model
    /// doesn't take a thinking level.
    public var thinkingLevels: Set<ThinkingLevel>
    /// Whether the model honors `temperature` and `top_p`. Newer models
    /// (Gemini 3.6 and later) ignore them, and may reject them in the future.
    public var samplingParams: Bool
    /// Constrained decoding with a JSON schema (`response_format`).
    public var structuredOutput: Bool
    /// Image content.
    public var imageInput: Bool
    /// PDF content.
    public var documentInput: Bool
    /// Audio content.
    public var audioInput: Bool
    /// Video content.
    public var videoInput: Bool

    public init(
      thinkingLevels: Set<ThinkingLevel> = [],
      samplingParams: Bool = false,
      structuredOutput: Bool = true,
      imageInput: Bool = true,
      documentInput: Bool = true,
      audioInput: Bool = true,
      videoInput: Bool = true
    ) {
      self.thinkingLevels = thinkingLevels
      self.samplingParams = samplingParams
      self.structuredOutput = structuredOutput
      self.imageInput = imageInput
      self.documentInput = documentInput
      self.audioInput = audioInput
      self.videoInput = videoInput
    }
  }

  // The thinking levels were measured against the API (November 2026): a
  // level that isn't listed is rejected with a 400. Every model takes text,
  // images, PDFs, audio, and video, and constrained JSON output. Gemini 2.5
  // models aren't served by the Interactions API.

  public static let gemini4Hydrogen = GeminiModel(
    id: "gemini-4-hydrogen",
    capabilities: .init(thinkingLevels: [.low, .medium, .high, .xhigh])
  )
  public static let gemini4Neon = GeminiModel(
    id: "gemini-4-neon",
    capabilities: .init(thinkingLevels: [.low, .medium, .high, .xhigh])
  )
  public static let gemini4Argon = GeminiModel(
    id: "gemini-4-argon",
    capabilities: .init(thinkingLevels: [.low, .medium, .high])
  )
  public static let gemini4Carbon = GeminiModel(
    id: "gemini-4-carbon",
    capabilities: .init(thinkingLevels: [.low, .medium, .high])
  )
  public static let gemini3_8Flash = GeminiModel(
    id: "gemini-3.8-flash",
    capabilities: .init(thinkingLevels: [.low, .medium, .high])
  )
  public static let gemini3_7Flash = GeminiModel(
    id: "gemini-3.7-flash",
    capabilities: .init(thinkingLevels: [.low, .medium, .high])
  )
  public static let gemini3_6Flash = GeminiModel(
    id: "gemini-3.6-flash",
    capabilities: .init(thinkingLevels: [.minimal, .low, .medium, .high])
  )
  public static let gemini3_5Flash = GeminiModel(
    id: "gemini-3.5-flash",
    capabilities: .init(thinkingLevels: [.minimal, .low, .medium, .high], samplingParams: true)
  )
  public static let gemini3_5FlashLite = GeminiModel(
    id: "gemini-3.5-flash-lite",
    capabilities: .init(thinkingLevels: [.minimal, .low, .medium, .high], samplingParams: true)
  )
  public static let gemini3_1ProPreview = GeminiModel(
    id: "gemini-3.1-pro-preview",
    capabilities: .init(thinkingLevels: [.low, .medium, .high], samplingParams: true)
  )
  public static let gemini3_1FlashLite = GeminiModel(
    id: "gemini-3.1-flash-lite",
    capabilities: .init(thinkingLevels: [.minimal, .low, .medium, .high], samplingParams: true)
  )
  public static let gemini3FlashPreview = GeminiModel(
    id: "gemini-3-flash-preview",
    capabilities: .init(thinkingLevels: [.minimal, .low, .medium, .high], samplingParams: true)
  )

  /// The compiled-in models, newest first.
  public static let knownModels: [GeminiModel] = [
    .gemini4Hydrogen, .gemini4Neon, .gemini4Argon, .gemini4Carbon,
    .gemini3_8Flash, .gemini3_7Flash, .gemini3_6Flash, .gemini3_5Flash, .gemini3_5FlashLite,
    .gemini3_1ProPreview, .gemini3_1FlashLite, .gemini3FlashPreview,
  ]

  /// The compiled-in model with the given ID.
  public static func named(_ id: String) -> GeminiModel? {
    knownModels.first { $0.id == id }
  }

  /// The level in ``Capabilities/thinkingLevels`` closest to `level`; a tie
  /// goes to the lower level. `nil` when the model takes no thinking level.
  public func closestThinkingLevel(to level: ThinkingLevel) -> ThinkingLevel? {
    let all = ThinkingLevel.allCases
    let target = all.firstIndex(of: level)!
    return all.indices
      .filter { capabilities.thinkingLevels.contains(all[$0]) }
      .min { (abs($0 - target), $0) < (abs($1 - target), $1) }
      .map { all[$0] }
  }
}
