// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import FoundationModels
import GeminiAPI
import Testing

@testable import GeminiForFoundationModels

@Suite struct RequestBuilderTests {
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  private func request(
    _ entries: [Transcript.Entry],
    tools: [Transcript.ToolDefinition] = [],
    schema: GenerationSchema? = nil,
    options: GenerationOptions = GenerationOptions(),
    context: ContextOptions = ContextOptions()
  ) -> LanguageModelExecutorGenerationRequest {
    LanguageModelExecutorGenerationRequest(
      id: UUID(),
      transcript: Transcript(entries: entries),
      enabledTools: tools,
      schema: schema,
      generationOptions: options,
      contextOptions: context,
      metadata: [:]
    )
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  private func prompt(_ text: String) -> Transcript.Entry {
    .prompt(Transcript.Prompt(segments: [.text(.init(content: text))]))
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `instructions and prompts become system instruction and user input`() throws {
    let built = try RequestBuilder.build(
      from: request([
        .instructions(.init(segments: [.text(.init(content: "Be brief."))], toolDefinitions: [])),
        prompt("Hello"),
      ]),
      model: .gemini3_8Flash
    )
    let body = built.body
    #expect(body["model"] == "gemini-3.8-flash")
    #expect(body["system_instruction"] == "Be brief.")
    #expect(body["input"] == [["type": "user_input", "content": [["type": "text", "text": "Hello"]]]])
    #expect(body["store"] == false)
    #expect(body["generation_config"] == ["thinking_summaries": "auto"])
    #expect(!built.isStructured)
    // Members go out in a stable order.
    #expect(body.jsonText.hasPrefix(#"{"model":"gemini-3.8-flash","system_instruction":"Be brief.","input":"#))
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `reasoning hints map to the closest thinking level`() throws {
    func level(_ hint: ContextOptions.ReasoningLevel?, _ model: GeminiModel, fixed: GeminiModel.ThinkingLevel? = nil) throws -> JSONValue? {
      try RequestBuilder.build(
        from: request([prompt("x")], context: ContextOptions(reasoningLevel: hint)),
        model: model,
        thinkingLevel: fixed
      ).body["generation_config"]?["thinking_level"]
    }
    #expect(try level(.light, .gemini3_8Flash) == "low")
    #expect(try level(.moderate, .gemini3_8Flash) == "medium")
    #expect(try level(.deep, .gemini4Neon) == "high")
    #expect(try level(.custom("xhigh"), .gemini4Neon) == "xhigh")
    // A level the model lacks is clamped to the closest one it has.
    #expect(try level(.custom("xhigh"), .gemini3_8Flash) == "high")
    #expect(try level(.custom("minimal"), .gemini3_8Flash) == "low")
    #expect(try level(.custom("bogus"), .gemini3_8Flash) == nil)
    #expect(try level(nil, .gemini3_8Flash) == nil)
    // A fixed level wins over the hint.
    #expect(try level(.light, .gemini4Neon, fixed: .xhigh) == "xhigh")
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `generation options map to the generation config`() throws {
    let options = GenerationOptions(
      samplingMode: .random(probabilityThreshold: 0.8, seed: 42),
      temperature: 0.4,
      maximumResponseTokens: 300,
      toolCallingMode: .required
    )
    let tool = Transcript.ToolDefinition(tool: ConvertTool())
    let config = try RequestBuilder.build(
      from: request([prompt("x")], tools: [tool], options: options),
      model: .gemini3_1FlashLite,
      thoughtSummaries: false
    ).body["generation_config"]
    #expect(config == [
      "thinking_summaries": "none", "tool_choice": "any", "max_output_tokens": 300,
      "temperature": 0.4, "top_p": 0.8, "seed": 42,
    ])

    // Newer models ignore sampling; only the seed goes out.
    let newer = try RequestBuilder.build(
      from: request([prompt("x")], options: options),
      model: .gemini3_8Flash
    ).body["generation_config"]
    #expect(newer?["temperature"] == nil)
    #expect(newer?["top_p"] == nil)
    #expect(newer?["seed"] == 42)
    // Without tools there is no tool choice.
    #expect(newer?["tool_choice"] == nil)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `tools become function declarations with declared property order`() throws {
    let tool = Transcript.ToolDefinition(tool: ConvertTool())
    let body = try RequestBuilder.build(
      from: request([prompt("x")], tools: [tool]),
      model: .gemini3_8Flash,
      builtInTools: [.urlContext, .googleSearch]
    ).body
    let tools = try #require(body["tools"]?.arrayValue)
    #expect(tools.count == 3)
    #expect(tools[0]["type"] == "function")
    #expect(tools[0]["name"] == "convertCurrency")
    #expect(tools[0]["parameters"]?["properties"]?.objectValue?.keys == ["amount", "currency"])
    #expect(tools[0]["parameters"]?["x-order"] == nil)
    #expect(tools[1] == ["type": "google_search"])
    #expect(tools[2] == ["type": "url_context"])
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `nested schemas keep their definitions and order`() throws {
    let schema = Itinerary.generationSchema
    let json = RequestBuilder.jsonSchema(from: schema)
    #expect(json["properties"]?.objectValue?.keys == ["city", "days"])
    let text = json.jsonText
    #expect(!text.contains("x-order"))
    #expect(text.contains(#""$ref":"#))
    let day = try #require(json["$defs"]?.objectValue?.values.first)
    #expect(day["properties"]?.objectValue?.keys == ["title", "activities", "budget"])
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `unpaired calls and results are dropped`() throws {
    let call = Transcript.ToolCall(id: "c1", toolName: "convertCurrency", arguments: GeneratedContent(properties: ["amount": 1, "currency": "EUR"]))
    let orphanCall = Transcript.ToolCall(id: "c2", toolName: "convertCurrency", arguments: GeneratedContent(properties: [:]))
    let body = try RequestBuilder.build(
      from: request([
        prompt("x"),
        .toolCalls(.init([call, orphanCall])),
        .toolOutput(.init(id: "c1", toolName: "convertCurrency", segments: [.text(.init(content: "0.92 EUR"))])),
        .toolOutput(.init(id: "c9", toolName: "convertCurrency", segments: [.text(.init(content: "?"))])),
        .response(.init(segments: [.text(.init(content: "Done."))])),
        prompt("y"),
      ]),
      model: .gemini3_8Flash
    ).body
    #expect(stepTypes(body) == ["user_input", "function_call", "function_result", "model_output", "user_input"])
    let input = try #require(body["input"]?.arrayValue)
    #expect(input[1] == ["type": "function_call", "id": "c1", "name": "convertCurrency", "arguments": ["amount": 1, "currency": "EUR"]])
    #expect(input[2] == ["type": "function_result", "call_id": "c1", "name": "convertCurrency", "result": "0.92 EUR"])
    #expect(input[3] == ["type": "model_output", "content": [["type": "text", "text": "Done."]]])
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `recorded steps replay in their original order`() throws {
    let thought: JSONValue = ["type": "thought", "signature": "s"]
    let output: JSONValue = ["type": "model_output", "content": [["type": "text", "text": "Hi"]]]
    let reasoning = Transcript.Reasoning(
      metadata: StepRecord.metadata(turn: "t", stored: [StepRecord.Step(position: 0, json: thought).stored]),
      segments: [],
      signature: Data("s".utf8)
    )
    let response = Transcript.Response(
      metadata: StepRecord.metadata(turn: "t", stored: [StepRecord.Step(position: 1, json: output).stored]),
      segments: [.text(.init(content: "Hi"))]
    )
    // The entries are out of order; the positions put them back.
    let body = try RequestBuilder.build(
      from: request([prompt("x"), .response(response), .reasoning(reasoning), prompt("y")]),
      model: .gemini3_8Flash
    ).body
    #expect(body["input"]?[1] == thought)
    #expect(body["input"]?[2] == output)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `reasoning without a record is dropped`() throws {
    let body = try RequestBuilder.build(
      from: request([
        prompt("x"),
        .reasoning(.init(segments: [.text(.init(content: "hmm"))], signature: Data([1, 2, 3]))),
        .response(.init(segments: [.text(.init(content: "Hi"))])),
        prompt("y"),
      ]),
      model: .gemini3_8Flash
    ).body
    #expect(stepTypes(body) == ["user_input", "model_output", "user_input"])
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `text cut off mid-step is replayed after the recorded steps`() throws {
    let output: JSONValue = ["type": "model_output", "content": [["type": "text", "text": "One."]]]
    let response = Transcript.Response(
      metadata: StepRecord.metadata(turn: "t", stored: [StepRecord.Step(position: 0, json: output).stored]),
      segments: [.text(.init(content: "One.")), .text(.init(content: " Two, cut"))]
    )
    let body = try RequestBuilder.build(
      from: request([prompt("x"), .response(response), prompt("y")]),
      model: .gemini3_8Flash
    ).body
    #expect(stepTypes(body) == ["user_input", "model_output", "model_output", "user_input"])
    #expect(body["input"]?[2]?["content"]?[0]?["text"] == " Two, cut")
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `images and pdfs become content blocks`() throws {
    let context = CGContext(
      data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    let image = context.makeImage()!
    var segments: [Transcript.Segment] = [
      .text(.init(content: "What is this?")),
      .attachment(.init(content: .image(.init(image)))),
    ]
    let pdf = Data("%PDF-1.4".utf8)
    if #available(iOS 27.2, macOS 27.2, visionOS 27.2, watchOS 27.2, *) {
      segments.append(.attachment(.init(content: .data(.init(contentType: .pdf, content: pdf)))))
    }
    let body = try RequestBuilder.build(
      from: request([.prompt(Transcript.Prompt(segments: segments))]),
      model: .gemini3_8Flash
    ).body
    let content = try #require(body["input"]?[0]?["content"]?.arrayValue)
    #expect(content.count == segments.count)
    #expect(content[1]["type"] == "image")
    #expect(content[1]["mime_type"] == "image/jpeg")
    if content.count > 2 {
      #expect(content[2] == ["type": "document", "data": .string(pdf.base64EncodedString()), "mime_type": "application/pdf"])
    }
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `a model without structured output rejects a schema`() throws {
    let plain = GeminiModel(id: "plain", capabilities: .init(structuredOutput: false))
    #expect(throws: LanguageModelError.self) {
      try RequestBuilder.build(from: request([prompt("x")], schema: Itinerary.generationSchema), model: plain)
    }
  }
}

@Suite struct GeminiModelTests {
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `an unsupported fixed thinking level throws instead of trapping`() {
    #expect(throws: GeminiError.unsupportedThinkingLevel(model: "gemini-3.8-flash", level: .xhigh)) {
      try GeminiLanguageModel(name: .gemini3_8Flash, auth: .apiKey("k"), thinkingLevel: .xhigh)
    }
    #expect(throws: Never.self) {
      try GeminiLanguageModel(name: .gemini4Neon, auth: .apiKey("k"), thinkingLevel: .xhigh)
    }
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `capabilities follow the model`() throws {
    let model = try GeminiLanguageModel(name: .gemini3_8Flash, auth: .apiKey("k"))
    for capability in [LanguageModelCapabilities.Capability.toolCalling, .vision, .reasoning, .guidedGeneration] {
      #expect(model.capabilities.contains(capability))
    }
    let plain = try GeminiLanguageModel(
      name: GeminiModel(id: "plain", capabilities: .init(structuredOutput: false, imageInput: false)),
      auth: .apiKey("k")
    )
    #expect(!plain.capabilities.contains(.vision))
    #expect(!plain.capabilities.contains(.reasoning))
    #expect(!plain.capabilities.contains(.guidedGeneration))
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `data attachments the model takes`() async throws {
    let model = try GeminiLanguageModel(name: .gemini3_8Flash, auth: .apiKey("k"))
    #expect(try await model.supportsDataAttachmentType(.pdf))
    #expect(try await model.supportsDataAttachmentType(.mp3))
    #expect(try await model.supportsDataAttachmentType(.mpeg4Movie))
    #expect(try await !model.supportsDataAttachmentType(.zip))
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `known models are unique and named`() {
    let ids = GeminiModel.knownModels.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(GeminiModel.named("gemini-4-neon") == .gemini4Neon)
    #expect(GeminiModel.named("gemini-0") == nil)
    #expect(GeminiModel.gemini3_6Flash.closestThinkingLevel(to: .xhigh) == .high)
    #expect(GeminiModel(id: "x", capabilities: .init()).closestThinkingLevel(to: .low) == nil)
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @Test func `the model catalog is listed across pages`() async throws {
    let page1 = #"{"models":[{"name":"models/gemini-3.8-flash","displayName":"Gemini 3.8 Flash","inputTokenLimit":1048576,"outputTokenLimit":65536,"thinking":true,"supportedGenerationMethods":["generateContent"]}],"nextPageToken":"p2"}"#
    let page2 = #"{"models":[{"name":"models/gemini-4-neon","displayName":"Gemini 4 Neon"}]}"#
    let transport = MockTransport(responses: [(200, Data(page1.utf8)), (200, Data(page2.utf8))])
    let models = try await GeminiModel.available(
      auth: .apiKey("k"),
      baseURL: URL(string: "https://stub.invalid")!,
      transport: transport
    )
    #expect(models.map(\.id) == ["gemini-3.8-flash", "gemini-4-neon"])
    #expect(models[0].inputTokenLimit == 1_048_576)
    #expect(models[0].thinking)
    #expect(!models[1].thinking)
    #expect(transport.requests.last?.url?.query()?.contains("pageToken=p2") == true)
    #expect(transport.requests.first?.httpMethod == "GET")
  }
}
