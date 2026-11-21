// swift-tools-version: 6.2
//
// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
  name: "GeminiForFoundationModels",
  // The package builds for older deployment targets so that apps supporting
  // them can depend on it, but every declaration is annotated with
  // @available(... 27.0 ...): the API is only usable on the OS 27 releases,
  // where Foundation Models supports server-side language models.
  platforms: [
    .iOS(.v17), .macOS(.v14), .visionOS("27.0"), .watchOS("27.0"),
  ],
  products: [
    .library(name: "GeminiForFoundationModels", targets: ["GeminiForFoundationModels"])
  ],
  targets: [
    // Internal client for the Gemini Interactions API. No FoundationModels
    // dependency.
    .target(name: "GeminiAPI"),

    // FoundationModels ↔ Interactions API bridge.
    .target(
      name: "GeminiForFoundationModels",
      dependencies: ["GeminiAPI"]
    ),

    // Runnable usage example (`swift run GeminiExample`). Not a product.
    .executableTarget(
      name: "GeminiExample",
      dependencies: ["GeminiForFoundationModels"],
      path: "Examples/GeminiExample"
    ),

    .testTarget(
      name: "GeminiAPITests",
      dependencies: ["GeminiAPI"]
    ),
    .testTarget(
      name: "GeminiForFoundationModelsTests",
      dependencies: ["GeminiForFoundationModels", "GeminiAPI"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
