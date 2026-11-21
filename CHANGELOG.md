# Changelog

## 0.1.1 (2026-11-21)

- All requests with the same timeout share one `URLSession`. Before, every executor created its own session, and so did every model list call; the sessions were never invalidated, and each kept its own idle connections alive, which expire with log messages like `nw_read_request_report [C13] Receive failed with error "Operation timed out"`.

## 0.1.0 (2026-11-21)

First release.

- `GeminiLanguageModel`: Gemini as a Foundation Models language model, backed by the stateless Interactions API.
  - Generation: text, streaming, guided generation (nested schemas, declared property order), tool calling, reasoning with thought summaries.
  - Input: images, plus PDF, audio and video attachments.
  - Usage reporting.
- Model turns are recorded on their transcript entries and replayed exactly, including thought signatures and built-in tool steps.
- `GeminiModel`:
  - constants for the Gemini 4 and Gemini 3.x models, with the thinking levels each accepts;
  - `GeminiModel.available(auth:)` lists the API's catalog.
- Built-in tools: Google Search, URL context, code execution. `GeminiToolActivity` reads their calls and results back out of a transcript.
- Error mapping to `LanguageModelError`, `GeminiError`, and `GeminiAPIError`.
- Structured requests leave out built-in tools; with a schema, a model can keep calling them without ever answering.
- Streams that send no events for three times the request timeout fail with a timeout instead of hanging.
- The package builds for macOS 14 / iOS 17; its API is available on the OS 27 releases.
