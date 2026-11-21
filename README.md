# GeminiForFoundationModels

Google's Gemini models as language models for Apple's
[Foundation Models](https://developer.apple.com/documentation/foundationmodels)
framework. A `LanguageModelSession` backed by Gemini works like one backed by
the on-device model:
- text and streamed responses;
- guided generation with `@Generable` types or dynamic schemas;
- tool calling;
- reasoning;
- images and PDFs;
- transcripts.

```swift
import FoundationModels
import GeminiForFoundationModels

let model = try GeminiLanguageModel(name: .gemini3_8Flash, auth: .apiKey(key))
let session = LanguageModelSession(model: model, instructions: "You are a concise travel assistant.")

let answer = try await session.respond(to: "What should I see in Kyoto?")

for try await snapshot in session.streamResponse(to: "Describe an evening in Gion.") {
  print(snapshot.content)
}

@Generable struct Itinerary {
  var city: String
  var days: [Day]
  @Generable struct Day { var title: String; var activities: [String] }
}
let plan = try await session.respond(to: "Plan two days in Lisbon.", generating: Itinerary.self)
```

## Requirements

- **The API is available on macOS 27, iOS 27, visionOS 27 and watchOS 27 or later.** These are the releases where Foundation Models supports server-side language models.
- **The package builds for macOS 14 and iOS 17.** An app with an older deployment target can depend on it and gate its use with `if #available(macOS 27, iOS 27, *)`.
- **Swift 6.2.**
- **A Gemini API key** from [Google AI Studio](https://aistudio.google.com/apikey).

## Installation

```swift
.package(url: "https://github.com/objecthub/GeminiForFoundationModels.git", from: "0.1.1")
```

Then add the `GeminiForFoundationModels` product to your target.

## How it works

The bridge talks to the **Interactions API** (`POST /v1beta/interactions` on `generativelanguage.googleapis.com`). It streams every response.

**Stateless requests.** Requests are sent with `store: false`, so nothing is kept on Google's side. Each request carries the whole conversation from the session's transcript.

**Replaying steps.** Gemini requires the model's own steps of an ongoing turn to be sent back exactly as produced, or it rejects the request. That covers thoughts with their signatures, and built-in tool calls and their results. The bridge therefore records the raw steps in the metadata of the transcript entries it writes:
- a reasoning entry holds its `thought` step;
- each tool call holds its `function_call` step;
- the response entry holds the output and built-in tool steps.

The steps are replayed from there. Persist a session with the transcript's `Codable` form and nothing is lost.

**Mapping of framework features:**

| Foundation Models | Gemini |
|---|---|
| Instructions | `system_instruction` |
| Prompt text, images, PDF / audio / video attachments | `user_input` content blocks |
| `Tool`s | `function` tools; calls and results as `function_call` / `function_result` steps |
| `GenerationOptions.toolCallingMode` | `tool_choice` (`any`, `none`) |
| `GenerationOptions.maximumResponseTokens` | `max_output_tokens` |
| Sampling seed | `seed` |
| `temperature`, top-p | sent only to models that honor them (`Capabilities.samplingParams`); the API rejects top-k |
| Guided generation | `response_format` with the schema; properties go out in declaration order |
| `ContextOptions.reasoningLevel` | `thinking_level`: light → low, moderate → medium, deep → high, `.custom("minimal"/"xhigh")`; clamped to the levels the model accepts |
| Reasoning entries | `thought` steps with summaries (`thoughtSummaries: true`) and signatures |
| Usage | input, cached, output, and thought tokens |

## Models

Constants for the current models carry the thinking levels each one accepts:

| Constant | Model |
|---|---|
| `.gemini4Hydrogen`, `.gemini4Neon` | low … xhigh |
| `.gemini4Argon`, `.gemini4Carbon` | low … high |
| `.gemini3_8Flash`, `.gemini3_7Flash`, `.gemini3_1ProPreview` | low … high |
| `.gemini3_6Flash`, `.gemini3_5Flash`, `.gemini3_5FlashLite`, `.gemini3_1FlashLite`, `.gemini3FlashPreview` | minimal … high |

Gemini 2.5 models are not served by the Interactions API.

For any other model ID, describe the model yourself:

```swift
let model = GeminiModel(id: "gemini-flash-latest",
                        capabilities: .init(thinkingLevels: [.low, .medium, .high]))
```

`GeminiModel.available(auth:)` lists the models of the API's catalog.

## Options

```swift
try GeminiLanguageModel(
  name: .gemini4Neon,
  auth: .apiKey(key),          // or .proxied(headers:) with a custom baseURL
  thinkingLevel: .xhigh,       // fixed level; overrides the reasoning hint
  thoughtSummaries: true,      // reasoning entries with thought summaries
  builtInTools: [.googleSearch, .urlContext, .codeExecution],
  baseURL: GeminiLanguageModel.defaultBaseURL,
  timeout: 120
)
```

- **A fixed thinking level** must be one the model accepts. Otherwise the initializer throws `GeminiError.unsupportedThinkingLevel`.
- **Built-in tools** run on Google's side. Read their calls and results back with `GeminiToolActivity.activities(in: session.transcript)`. Each activity gives its search queries, URLs, or code and output.
- **Built-in tools and guided generation don't mix.** Requests with a schema leave the built-in tools out. Combined with a schema, a model can keep calling a built-in tool without ever producing the structured output. Earlier built-in tool steps in the conversation are still sent.
- **Proxying.** `.proxied(headers:)` with a custom `baseURL` routes requests through your own relay, which adds the API key. Credentials are only sent to the configured origin; a redirect elsewhere fails the request.

## Errors

| Situation | Error |
|---|---|
| Rate limits, quota, overload | `LanguageModelError.rateLimited` (with the API's retry delay) |
| Safety and other blocks | `LanguageModelError.guardrailViolation` |
| Prompt too long | `LanguageModelError.contextSizeExceeded` |
| Timeouts | `LanguageModelError.timeout` |
| Invalid / missing key | `GeminiError.invalidCredential` / `.missingCredential` |
| A structured response cut off at the token limit | `GeminiError.incompleteResponse` |
| Anything else (unknown model, depleted credits, invalid request, …) | `GeminiAPIError` with the API's status, code, and message |

## Example and tests

```bash
GEMINI_API_KEY=<key> swift run GeminiExample --search "What happened in Lisbon this week?"
```

`swift test` runs the offline suites. With `GEMINI_API_KEY` set, the live suite also runs against the API; `GEMINI_TEST_MODEL` picks its model.

## Credits

The architecture follows Anthropic's
[ClaudeForFoundationModels](https://github.com/anthropics/ClaudeForFoundationModels):
recording a turn on its transcript entries, and the executor, request builder and event translator split. Some files are adapted from it (see `NOTICE`).

## License

Apache License 2.0. See `LICENSE`.
