# siri-shim

A modular, maintainable shim that exposes Apple's **on-device foundation model**
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
swift run siri-shim
```

The server listens on `http://127.0.0.1:11535` by default and prints on startup
whether the on-device model is available.

### Configuration (environment variables)

| Variable             | Default        | Purpose                                   |
| -------------------- | -------------- | ----------------------------------------- |
| `SIRI_SHIM_HOST`     | `127.0.0.1`    | Bind address                              |
| `SIRI_SHIM_PORT`     | `11535`        | Bind port                                 |
| `SIRI_SHIM_MODEL_ID` | `apple-on-device` | Model id advertised and accepted       |

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
siri-shim (executable)   composition root: config + server + routes
├── ShimCore             domain types, LLMProvider protocol, config (no deps)
├── FoundationProvider   wraps Apple's FoundationModels framework
└── OpenAICompat         OpenAI DTOs + Hummingbird route handlers
```

`LLMProvider` is the seam: the routing layer never touches Apple APIs directly, so
an Ollama-native endpoint family or a mock backend can be added without disturbing
the core.

## Known simplifications (v1)

- **Stateless conversations.** Each request rebuilds a fresh `LanguageModelSession`;
  prior turns are replayed as a flattened prompt rather than kept in a live session.
- **Token usage is not yet reported** (counts return 0).
- **No tool/function calling** or embeddings endpoints yet.

## Roadmap

- [ ] Ollama-native endpoints (`/api/chat`, `/api/generate`, `/api/tags`)
- [ ] Real token accounting
- [ ] Tool / function calling passthrough
- [ ] Optional API-key auth for non-localhost binds

## License

TBD.
