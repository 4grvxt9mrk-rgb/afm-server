# afm-server

**A**pple **F**oundation **M**odels server: a modular, maintainable shim that exposes Apple's **on-device foundation model**
(the local Apple Intelligence LLM, via the `FoundationModels` framework) over an
**OpenAI-compatible HTTP API** — so third-party tools like AnythingLLM, opencode,
or anything that speaks the OpenAI API can talk to the local model on Apple hardware.

> **Terminology note.** Apple does not publish a public API for *Siri's* internal
> pipeline. The sanctioned way to run Apple's local text model in a third-party
> process is the `FoundationModels` framework (macOS 26+/iOS 26+), which is the
> on-device Apple Intelligence model. That is what this shim bridges.

## Requirements

- macOS 26 or later (developed on macOS 27 / Xcode 27 / Swift 6.4, Apple Silicon)
- Apple Intelligence enabled, with the on-device model downloaded
- Swift toolchain (bundled with Xcode)

## Build & run

```bash
swift build
swift run afm-server
```

The server listens on `http://127.0.0.1:11535` by default and prints on startup
whether the on-device model is available.

### Configuration (environment variables)

| Variable        | Default           | Purpose                            |
| --------------- | ----------------- | ---------------------------------- |
| `AFM_HOST`      | `127.0.0.1`       | Bind address (`0.0.0.0` for Docker/LAN clients) |
| `AFM_PORT`      | `11535`           | Bind port                          |
| `AFM_MODEL_ID`  | `apple-on-device` | Model id advertised and accepted   |

## API

OpenAI-compatible endpoints (v1):

- `GET  /health` — liveness check
- `GET  /v1/models` — lists the advertised model
- `POST /v1/chat/completions` — chat completions, streaming (SSE) and non-streaming

### Example

```bash
curl http://127.0.0.1:11535/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "apple-on-device",
    "messages": [{"role": "user", "content": "Say hello in one sentence."}]
  }'
```

Streaming: add `"stream": true` to receive `text/event-stream` deltas terminated
by `data: [DONE]`.

### Pointing a client at the shim

Set the client's OpenAI base URL to `http://127.0.0.1:11535/v1` and use model id
`apple-on-device` (most clients ignore the API key; any non-empty string works).

## Architecture

```
afm-server (executable)  composition root: config + server + routes
├── ShimCore             domain types, LLMProvider protocol, config (no deps)
├── FoundationProvider   wraps Apple's FoundationModels framework
└── OpenAICompat         OpenAI DTOs + Hummingbird route handlers
```

`LLMProvider` is the seam: the routing layer never touches Apple APIs directly, so
an Ollama-native endpoint family or a mock backend can be added without disturbing
the core.

## Tool / function calling

The shim supports OpenAI-style tool calling, which is what clients like
AnythingLLM's **model router** / agent mode rely on to make routing decisions.

Send `tools` (and optionally `tool_choice`) on `/v1/chat/completions`. The shim
translates each tool's `parameters` JSON Schema into a `FoundationModels`
[guided-generation](https://developer.apple.com/documentation/foundationmodels)
schema, constrains the on-device model to a single "which tool + what arguments"
decision, and returns it as `tool_calls` with `finish_reason: "tool_calls"` —
the client then executes the tool and sends the result back as a `role:"tool"`
message, exactly as with the OpenAI API.

- `tool_choice: "auto"` (default) — the model may call a tool or answer directly.
- `tool_choice: "required"` — the model must call some tool.
- `tool_choice: {"type":"function","function":{"name":"…"}}` — force one tool.
- `tool_choice: "none"` — plain text generation (tools ignored).

Because the decision uses constrained decoding, tool-calling requests are always
computed non-streaming; if the client asked for `stream: true`, the result is
still delivered as a single SSE `tool_calls` chunk.

## Known simplifications (v1)

- **Stateless conversations.** Each request rebuilds a fresh `LanguageModelSession`;
  prior turns are replayed as a flattened prompt rather than kept in a live session.
- **Token usage is not yet reported** (counts return 0).
- **One tool call per turn.** The decision schema selects a single tool; parallel
  tool calls in one response aren't emitted yet.
- **Non-text content parts are dropped** (e.g. image_url); the on-device model is
  text-only.
- **No embeddings endpoint** yet.

## Roadmap

- [ ] Ollama-native endpoints (`/api/chat`, `/api/generate`, `/api/tags`)
- [ ] Real token accounting
- [ ] Parallel / multiple tool calls per turn
- [ ] Optional API-key auth for non-localhost binds

## License

TBD.
