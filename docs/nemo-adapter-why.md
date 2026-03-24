# Why the OpenAI Adapter Exists (and Why We Still Need It)

This doc explains the three problems that forced us to build an adapter sidecar between OpenClaw and NeMo Guardrails, tracks which versions fixed what, and documents why the adapter is still necessary as of NeMo 0.20.0.

## The setup

```
OpenClaw  →  Adapter  →  NeMo Guardrails  →  Llama Stack  →  OpenAI API
(agent)      (bridge)    (safety rails)       (gateway)       (gpt-4o-mini)
```

OpenClaw is a Node.js agent. NeMo Guardrails is a Python safety proxy. They speak slightly different dialects of the OpenAI protocol. The adapter bridges the gaps.

## Problem 1: Response format mismatch

**What happens:** OpenClaw sends a request to `/v1/chat/completions`. NeMo processes it, runs the safety rails, and returns a response. But the response shape is wrong.

OpenClaw expects (standard OpenAI format):
```json
{
  "choices": [{"message": {"role": "assistant", "content": "Hello!"}}],
  "id": "chatcmpl-abc123",
  "model": "gpt-4o-mini"
}
```

NeMo 0.18.0 returned (its own format):
```json
{
  "messages": [{"role": "assistant", "content": "Hello!"}]
}
```

OpenClaw parses `response.choices[0].message.content`. When there's no `choices` key, it gets `undefined`. The user sees an empty message with the model tag but no content.

**What the adapter does:** Receives NeMo's `{"messages":[...]}` response, rewraps it into `{"choices":[...]}` format.

**Status:** Fixed in NeMo 0.20.0. NeMo now returns proper OpenAI format. The adapter's format conversion code is no longer exercised, but we haven't removed it yet.

## Problem 2: Multi-part content crash

**What happens:** OpenClaw wraps every user message with metadata (sender label, channel, timestamp):

```json
{
  "role": "user",
  "content": [
    {
      "type": "text",
      "text": "Sender (untrusted metadata):\n{\"label\": \"openclaw-control-ui\"}\n\n[Tue 2026-03-24 07:23 UTC] hello"
    }
  ]
}
```

This is valid OpenAI format (the list-of-blocks format, added for GPT-4 Vision). Most OpenAI-compatible servers handle it. NeMo 0.18.0 didn't.

The crash happens *after* NeMo successfully processes the message. NeMo runs the safety check, generates a response, and then tries to build a conversation history log. The function `get_colang_history()` in `nemoguardrails/actions/llm/utils.py` line 442 does:

```python
split_history = history.rsplit(utterance_to_replace, 1)
```

`history` is built from the conversation's `content` fields. When `content` is a string, `.rsplit()` works. When `content` is a list (the OpenAI multi-part format), Python throws:

```
TypeError: must be str or None, not list
```

The irony: the safety check worked correctly. The response was generated correctly. The crash is in bookkeeping code that runs *after* the real work is done, but it corrupts the response on its way back to the client.

On the first message, this doesn't crash because there's no prior history to process. On the second message, the history includes the first message's list-format content, and that's when `.rsplit()` fails.

**What the adapter does:** Before forwarding to NeMo, converts all `content` fields from list to string:

```python
for msg in req_json.get("messages", []):
    c = msg.get("content")
    if isinstance(c, list):
        parts = [p.get("text", "") if isinstance(p, dict) else p for p in c]
        msg["content"] = "\n".join(parts)
```

**Status:** Fixed in NeMo 0.15.0+. NeMo now handles list content without crashing. However, the adapter's normalization is still useful because it strips the OpenClaw metadata (`Sender (untrusted metadata)`, `openclaw-control-ui`, timestamps) before it reaches the LLM. Without normalization, the metadata pollutes the prompt and confuses NeMo's intent classification.

## Problem 3: No streaming support

**What happens:** OpenClaw defaults to streaming responses (`"stream": true` in the request). It expects Server-Sent Events (SSE) chunks back:

```
data: {"choices":[{"delta":{"role":"assistant","content":"Hello"}}]}

data: {"choices":[{"delta":{"content":" how can"}}]}

data: {"choices":[{"delta":{"content":" I help?"}}]}

data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

data: [DONE]
```

This is how ChatGPT, Claude, and every modern LLM API delivers responses token-by-token. OpenClaw opens a connection, expects `Content-Type: text/event-stream`, and reads chunks incrementally.

NeMo 0.18.0 ignored `stream: true` entirely. It returned a single JSON blob with `Content-Type: application/json`. OpenClaw opened the SSE reader, received JSON instead of SSE, and either showed nothing or errored.

**What the adapter does:** Strips `stream: true` from the request before forwarding to NeMo (so NeMo processes it as a non-streaming request). When NeMo returns the full response, the adapter converts it to SSE format: one chunk with the full content, a finish chunk, and `[DONE]`. The user sees the response appear all at once (not token-by-token) but it works.

**Status in NeMo 0.20.0:** Partially implemented. NeMo now has a `rails.output.streaming.enabled` config flag. When set to `false` (default), streaming requests return a clear error:

```
stream_async() cannot be used when output rails are configured but
rails.output.streaming.enabled is False
```

When set to `true`, NeMo attempts to stream, but crashes:

```python
# nemoguardrails/streaming.py line 206
for stop_chunk in self.stop:
                  ^^^^^^^^^
TypeError: 'NoneType' object is not iterable
```

`self.stop` is supposed to contain stop sequences for the LLM (tokens that signal "stop generating"). When NeMo gets its LLM responses through Llama Stack, the stop sequences aren't in the response metadata, so `self.stop` is `None`. NeMo's streaming handler assumes they're always present and tries to iterate over them.

This is a NeMo bug specific to proxied/non-standard LLM endpoints. If NeMo talked directly to OpenAI, `self.stop` would be populated from the response. Going through Llama Stack, the metadata gets lost.

**What the adapter still does:** Same as before. Strips `stream`, gets full response, converts to SSE. This works reliably regardless of NeMo's streaming support status.

## Version history

| Version | Image | Date | #1 Format | #2 List content | #3 Streaming |
|---------|-------|------|-----------|----------------|-------------|
| 0.18.0 | Stale RHOAI image (Jan 2026) | Pre-refresh | Broken | Broken | Broken |
| 0.15.0 | First nightly refresh | Mar 22, 2026 | Broken | **Fixed** | Broken |
| 0.20.0 | Latest nightly | Mar 24, 2026 | **Fixed** | **Fixed** | New crash (`self.stop=None`) |

## What the adapter does today (0.20.0)

With two of three problems fixed in NeMo, the adapter's role has shrunk:

| Function | Still needed? | Why |
|----------|--------------|-----|
| Response format conversion (NeMo → OpenAI) | No (0.20.0 returns `choices`) | Kept as safety net |
| Content list → string normalization | Yes | Strips OpenClaw metadata from prompt, prevents intent confusion |
| Strip `stream: true` flag | Yes | NeMo streaming crashes on `self.stop=None` |
| Convert response to SSE | Yes | OpenClaw requires SSE for response display |
| Ensure `model` field present | Yes | NeMo 0.20.0 returns 422 without it |

## What needs to happen to remove the adapter

1. **NeMo fixes `self.stop=None` crash** in the streaming handler. One-line fix: `for stop_chunk in (self.stop or []):`
2. **NeMo (or Llama Stack) passes stop sequences** through the proxy chain, or NeMo doesn't rely on them being present
3. **OpenClaw or NeMo strips agent metadata** from message content, or NeMo's intent classification ignores it

After those three, the adapter becomes unnecessary. OpenClaw talks directly to NeMo, NeMo streams back, done.

## The adapter code

80 lines of Python, stdlib only (`http.server`, `json`, `urllib`). No dependencies to install. It runs as a separate Deployment + Service (`openclaw-guardrails-adapter` / `openclaw-guardrails-proxy`), not as a sidecar inside the NeMo pod (the TrustyAI CRD doesn't support sidecars).

Source: `manifests/guardrails-adapter.yaml`
