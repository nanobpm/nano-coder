---
title: "Providers and models"
description: "Pick a model, configure providers, local servers and GitHub Copilot, and tune temperature, thinking, vision and retries."
order: 4
section: "Using nano-coder"
---

# Providers and models

A model is named `provider/model`. nano-coder ships presets for common providers and accepts any OpenAI- or Anthropic-compatible endpoint.

## Providers

A model is written as `provider/model`. The first path segment picks the provider if it
names one; otherwise the whole string is a model on `default_provider`. So
`openrouter/anthropic/claude-sonnet-4.5` sends `anthropic/claude-sonnet-4.5` to OpenRouter.

Built-in presets:

| Provider | Kind | Base URL | API key env |
|---|---|---|---|
| `openai` | openai | `https://api.openai.com/v1` | `OPENAI_API_KEY` |
| `anthropic` | anthropic | `https://api.anthropic.com/v1` | `ANTHROPIC_API_KEY` |
| `openrouter` | openai | `https://openrouter.ai/api/v1` | `OPENROUTER_API_KEY` |
| `fireworks` | openai | `https://api.fireworks.ai/inference/v1` | `FIREWORKS_API_KEY` |
| `groq` | openai | `https://api.groq.com/openai/v1` | `GROQ_API_KEY` |
| `together` | openai | `https://api.together.xyz/v1` | `TOGETHER_API_KEY` |
| `deepseek` | openai | `https://api.deepseek.com/v1` | `DEEPSEEK_API_KEY` |
| `kimi` | openai | `https://api.moonshot.ai/v1` | `MOONSHOT_API_KEY` |
| `mistral` | openai | `https://api.mistral.ai/v1` | `MISTRAL_API_KEY` |
| `gemini` | openai | `https://generativelanguage.googleapis.com/v1beta/openai` | `GEMINI_API_KEY` |
| `qwen` | openai | Model Studio (default: Standard, Singapore — all plans/regions below) | `DASHSCOPE_API_KEY` / `BAILIAN_*_PLAN_API_KEY` |
| `ollama` | openai | `http://localhost:11434/v1` | — |
| `llamacpp` | openai | `http://localhost:8080/v1` | — |
| `github-copilot` | github-copilot | from session token | `GITHUB_COPILOT_OAUTH_TOKEN` or `--login` (unofficial, see below) |
| `mock` | mock | — | — |

`kind = "openai"` means OpenAI Chat Completions, which also covers vLLM, LM Studio,
llama.cpp, DwarfStar ds4 and similar servers. `kind = "anthropic"` is the Anthropic
Messages API.

A `[providers.<name>]` table can add a new endpoint or override any field of a preset:

```toml
[providers.ollama]                      # point the preset at another host
base_url = "http://merlin.local:11434/v1"
default_model = "qwen3:8b"              # used by `--model ollama`

[providers.ds4]                         # a custom OpenAI-compatible endpoint
kind = "openai"
base_url = "http://localhost:8100/v1"
extra_body = { think = false }          # merged into every request body

[providers.openai]
drop_params = ["temperature"]           # for models that reject temperature

[providers.openrouter]
headers = { "HTTP-Referer" = "https://example.com", "X-Title" = "nano-coder" }
extra_body = { provider = { sort = "throughput" } }

[providers.work]
kind = "anthropic"
base_url = "https://llm-gateway.example.com/anthropic/v1"
api_key_env = "WORK_GATEWAY_KEY"        # or api_key = "..." (prefer the env var)
# api_key_command = "op read op://vault/gateway/key"   # used when the env var is unset
timeout_secs = 300                      # idle timeout: max silence between streamed bytes (default 120)
max_retries = 3
```

`qwen` is Qwen Cloud (Alibaba Cloud Model Studio), e.g. `--model qwen/qwen3.8-max`.
Model Studio serves the same models through three plans, each with its own hostnames and
API-key variable. All of them speak OpenAI Chat Completions, so each is just a `base_url`
+ `api_key_env`:

| Plan | Region | Base URL | API key env |
|---|---|---|---|
| Standard API key | Singapore (International) | `https://dashscope-intl.aliyuncs.com/compatible-mode/v1` | `DASHSCOPE_API_KEY` |
| Standard API key | China (Beijing) | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `DASHSCOPE_API_KEY` |
| Standard API key | US (Virginia) | `https://dashscope-us.aliyuncs.com/compatible-mode/v1` | `DASHSCOPE_API_KEY` |
| Standard API key | China (Hong Kong) | `https://cn-hongkong.dashscope.aliyuncs.com/compatible-mode/v1` | `DASHSCOPE_API_KEY` |
| Token Plan | Singapore (International) | `https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1` | `BAILIAN_TOKEN_PLAN_API_KEY` |
| Token Plan | China (Beijing) | `https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1` | `BAILIAN_TOKEN_PLAN_API_KEY` |
| Coding Plan | Singapore (International) | `https://coding-intl.dashscope.aliyuncs.com/v1` | `BAILIAN_CODING_PLAN_API_KEY` |
| Coding Plan | China (Beijing) | `https://coding.dashscope.aliyuncs.com/v1` | `BAILIAN_CODING_PLAN_API_KEY` |

The `qwen` preset defaults to **Standard API key, Singapore** (the first row). In
`/settings` → *Add or edit a provider* → `qwen` these eight endpoints are offered as a
*Qwen / Model Studio endpoint* picker (plus a custom URL), so you can switch plan and
region without retyping a URL. Picking a plan also points the provider at that plan's
API-key variable — the preset's `DASHSCOPE_API_KEY` becomes `BAILIAN_TOKEN_PLAN_API_KEY`
for Token Plan, and `BAILIAN_CODING_PLAN_API_KEY` for Coding Plan. Set the variable (or a
key command / literal key) at the key prompt that follows. API keys are also bound to a
*region*, so a key issued for another region still needs the matching endpoint row.

To configure an endpoint in the config file directly, override `base_url` and
`api_key_env` (append `/compatible-mode/v1` to a workspace domain, e.g.
`https://<WorkspaceId>.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1`):

```toml
[providers.qwen]                        # Token Plan, China
base_url = "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
api_key_env = "BAILIAN_TOKEN_PLAN_API_KEY"
```

`kimi` is the Kimi API from platform.kimi.ai, e.g. `--model kimi/kimi-k3` or
`kimi/kimi-k2.7-code`. The preset drops `temperature` (K3 fixes it) and sets
`replay_reasoning = true`, which sends each assistant message's `reasoning_content` back
as thinking models like K3 require. Set `extra_body = { reasoning_effort = "low" }` to
make K3 think less.

### Temperature

`temperature` is a number, or `"default"` to send none so the model uses its own default.
It can be set for all models, for one provider, or for one model; the most specific
setting wins:

```toml
temperature = 0.7                       # all models

[providers.groq]
temperature = "default"                 # every groq model uses its own default

[providers.anthropic.models."claude-sonnet-4-5"]
temperature = 0.3                       # this model only
```

Some models accept no temperature, and for them the model default is the only option:
GitHub Copilot's reasoning models (GPT-5 and later, Grok, …) and any provider with
`drop_params = ["temperature"]` (such as the `kimi` preset). A number set for such a
provider or model is ignored with a warning at startup and when you switch to it; the
top-level `temperature` just doesn't apply to them. Anthropic accepts 0 to 1, so a higher
value is sent as 1, with a warning. `/context` shows the temperature in use and where it
comes from, and `/settings` edits it for the current model, its provider, or all models.

### Thinking

`thinking` sets how much the model reasons before it answers: `"default"` sends nothing
(the model decides), `"off"` turns thinking off, and a level such as `"low"`, `"medium"`,
`"high"`, `"xhigh"` or `"max"` asks for that much. Like `temperature`, it can be set for all
models, one provider or one model, and `/thinking LEVEL` overrides them for the session:

```toml
thinking = "medium"                     # all models that support it

[providers.anthropic.models."claude-opus-4-7"]
thinking = "xhigh"                      # this model only
```

A model only gets levels it supports. They come from, in order: `thinking_levels` on the
model or provider; what the endpoint reports for the model; and a built-in table
of Claude (3.7 Sonnet and later) and OpenAI reasoning models (GPT-5 and later, o1/o3/o4).
Endpoints that report levels:

- **GitHub Copilot:** `/models` lists each model's levels, read with the same request as its
  context window.
- **Ollama:** a model with the `thinking` capability (`/api/show`) gets `off`, `low`,
  `medium` and `high`. Ollama refuses a level for a model without it, so none is sent then.
- **llama.cpp:** the loaded model's chat template (`/props`) decides. A template with an
  `enable_thinking` switch (Qwen 3 and the like) gets `off` and `on`, and any named level
  turns thinking on; a template that takes `reasoning_effort` (gpt-oss) gets `low`, `medium`
  and `high`.
- **Splash:** `/v1/models` gives a thinking model (`reasoning.thinks`) its
  `reasoning.efforts`, plus `off`, sent as `reasoning_effort`.

Ollama, llama.cpp and Splash are recognized however the provider is named, the same way as for the
context window. For other models, list the levels yourself:

```toml
[providers.together.models."deepseek-r1"]
thinking_levels = ["low", "medium", "high"]   # add "off" if thinking can be turned off
```

A level the model lacks is moved to the nearest one it has (the highest below it, else the
lowest), and a model with no known levels is sent nothing. A setting for the provider, the
model or the session warns when it is adjusted or ignored; the top-level `thinking` doesn't
warn, since it applies to every model.

How the level is sent depends on the API: `reasoning_effort` (Chat Completions, Ollama
included; Ollama ignores its native `think` flag on `/v1`), `chat_template_kwargs` for
llama.cpp (`enable_thinking`, or `reasoning_effort` for templates that take a level; it
ignores the top-level `reasoning_effort`),
`reasoning.effort` (Responses), and for Anthropic Messages adaptive thinking with
`output_config.effort`, or on Claude 3.7 to 4.5 a fixed `budget_tokens` (1024 for minimal, then
2048, 8192, 16384, 32768, 65536 up to max). The budget has to stay below `max_tokens`, so raise
`max_tokens` to use a large one. Anthropic takes no custom temperature while thinking, so
none is sent then. A matching key in the provider's `extra_body` (`reasoning_effort`, `reasoning`,
`think`, `chat_template_kwargs`, `thinking`, `output_config`) is sent instead, with a warning; the
configured level is then reported as overridden (not as sent), since the override's value is what
reaches the wire. The status bar shows
`think LEVEL` while a level is sent, `/context` shows it with where it comes from,
`/settings` sets it for the current model, its provider or all models (picking from the
levels the model supports), and the session log records it for each reply.

### Vision

`read_file` returns images (PNG, JPEG, GIF and WebP, recognised by magic bytes) to
models that can view them: the result is a short text part (`image/png, 1600×900, 131 KB`)
plus an image attachment the model sees directly. Images over the provider's limits are
downscaled first (longest side 1568 px, under the model's byte cap), and re-encoded to
JPEG/PNG when the model doesn't accept the source type. Other binary files still return
the "looks like a binary file" error, which notes whether the current model supports
images.

Whether a model can see images comes from, in order: a `vision = true|false` override
(global, `[providers.<name>]`, or `[providers.<name>.models."<model>"]`, like `thinking`);
what the endpoint reports (GitHub Copilot `/models` `capabilities.supports.vision` and its
`limits.vision`, Ollama `/api/show`'s `vision` capability, llama.cpp `/props`
`modalities.vision`); and a built-in assumption for current Anthropic and OpenAI model
families. A model that can't see images gets the text error with a hint to switch models
or set `vision = true`:

```toml
vision = true                            # all models

[providers.ollama.models."my-clip-model"]
vision = true                            # this model only
```

A request carries only the newest few images the model allows (GitHub Copilot's
`max_prompt_images`, default 1); older ones become `[image omitted: path (sent earlier)]`.
Each image counts toward the context estimate at a fixed cost from its size, so the status
bar and auto-compaction stay honest, and compaction replaces images with the same
placeholder. Images are stored once per session under `<session>.attachments/` (named by
content hash), so session logs stay small and `--resume` still works; a missing file on
resume is sent as a text placeholder.

Other per-provider fields: `replay_reasoning`, `max_tokens_param` (`max_tokens`, or `max_completion_tokens`
which is the `openai` default), `retry_initial_backoff_ms`, `retry_max_backoff_ms` and
`retryable_statuses`.

The old top-level `api_key` / `base_url` still work. They apply to `default_provider`,
which becomes `openai` if it was `mock`.

List a provider's models with `--list-models <provider>` (OpenAI-compatible endpoints,
and `github-copilot`).

### Local servers on another machine (macOS)

macOS Local Network privacy can block nano-coder from reaching a model server on your
LAN (e.g. `http://192.168.0.141:8888/v1` or `http://merlin.local:11434/v1`). Requests fail
with `tcp connect error … No route to host (os error 65)`, while `curl` to the same URL
works. `localhost` is not affected.

- Allow it in **System Settings → Privacy & Security → Local Network**. The prompt and the
  entry go to the app that launched nano-coder (your terminal, or the editor running it over
  ACP). A locally built binary is unsigned, so macOS may treat each rebuild as a new app and
  ask again.
- Or forward a local port, which needs no permission:
  `ssh -N -L 18888:localhost:8888 user@192.168.0.141` (or `socat
  TCP-LISTEN:18888,bind=127.0.0.1,fork TCP:192.168.0.141:8888`), then set
  `base_url = "http://127.0.0.1:18888/v1"`.

### GitHub Copilot (unofficial)

The `github-copilot` provider uses a GitHub Copilot subscription by authenticating **as the
VS Code Copilot Chat extension**: a device-flow login with VS Code's OAuth client ID, an
exchange for a short-lived Copilot session token, and model calls with VS Code's editor
headers. Each model is routed to the upstream API Copilot serves it through — Chat
Completions by default, the OpenAI Responses endpoint for `gpt-*`/`grok-*`/`oswe*`/`mai-*`
models (e.g. `gpt-6-astra`, which Copilot serves *only* via Responses), and the Anthropic
Messages endpoint for Claude 4.x/5.x. This is the approach several open-source agents
(e.g. pi) take, but it is **not a GitHub-sanctioned integration**. It may breach GitHub's
terms or your organisation's Copilot policy, it can break without notice, and misuse could
get an account flagged. It is never used unless you select it.

```bash
nano-coder --login github-copilot          # interactive; saves the OAuth token (0600)
nano-coder --list-models github-copilot
nano-coder --model github-copilot/gpt-4.1
```

Headless workers can't do the device flow; set `GITHUB_COPILOT_OAUTH_TOKEN` to a token from a
previous login instead (credentials live in `<data dir>/nano-coder/github-copilot.json`).
Tool follow-ups are sent with `X-Initiator: agent`, so a turn is billed like one VS Code
request. `GITHUB_COPILOT_DOMAIN` selects a GHE.com host.

The sanctioned route is the [Copilot SDK](https://github.com/github/copilot-sdk), which
drives the Copilot CLI's own agent loop rather than exposing the model.

### Retries

Retry behaviour comes from unreal-agent's retry logic (MIT). Connection errors and
HTTP 408/409/425/429/5xx/529 are retried with exponential backoff (1s doubling to
30s, minus up to 20% jitter, 5 retries). `Retry-After` headers are honoured, and so is
"try again in Xs" in rate-limit messages. Overloads (`overloaded_error`,
`server_is_overloaded`, 529) back off from 10s up to 60s. Errors that can never succeed
on retry fail immediately: authentication and permission errors, invalid requests,
`context_length_exceeded`, quota and billing errors, and policy errors.
