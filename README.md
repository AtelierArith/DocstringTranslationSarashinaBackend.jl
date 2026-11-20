# DocstringTranslationSarashinaBackend.jl

Translate Julia docstrings into Japanese with the
[Sarashina translate API](https://docs.sarashina.ai/api-reference/translate)
(`sarashina3.2-translate`). Inspired by
[DocstringTranslation.jl](https://github.com/AtelierArith/DocstringTranslation.jl).
API requests are sent with [Sarashina.jl](https://github.com/AtelierArith/Sarashina.jl)
(not yet registered; it is resolved through `[sources]` in `Project.toml`, which needs Julia 1.13).

## Setup

1. Issue an API key at <https://chat.sarashina.ai/dashboard/api-keys>.
2. Set it as `SARASHINA_API_KEY`, e.g. in a `.env` file:

   ```sh
   SARASHINA_API_KEY=<your-key>
   ```

The Sarashina API only accepts requests from Japan.

## Usage

```julia-repl
julia> using DotEnv; DotEnv.load!()   # or export SARASHINA_API_KEY yourself

julia> using DocstringTranslationSarashinaBackend

julia> @switchlang! "ja"

help?> clamp
  clamp(x, lo, hi)

  条件lo <= x <= hiが真であればxを返し、条件x > hiが真であればhiを返し、
  条件x < loが真であればloを返します。引数は共通の型に型昇格されます。

  関連項目：clamp!、min、max。
  ...
```

`@switchlang!` overrides `Docs.parsedoc`, so every docstring is translated the
first time it is displayed. Translations are cached in this package's scratch
space (`<module>/<major.minor>/<sha256>/ja-<style>.md`), so each docstring is sent
to the API only once per writing style. Calling `@switchlang!` or `switchstyle!`
again takes effect on docstrings that were already displayed, and docstrings that
could not be translated (no API key, API error) are retried on the next lookup.

### Japanese style (beta)

```julia
using DocstringTranslationSarashinaBackend: switchstyle!
switchstyle!("plain")   # だ・である調
switchstyle!("polite")  # です・ます調
switchstyle!("auto")    # default
```

### Translating Markdown / text directly

```julia
using DocstringTranslationSarashinaBackend, Markdown

translate_text("Return the sum of two numbers."; target_lang = "ja")
translate_md(md"Return the sum of `x` and `y`. See [`sum`](@ref)."; target_lang = "ja")

# with an explicit translator
t = SarashinaTranslator(; api_key = "...", style = "polite")
translate_md(md"Compute the inverse."; translator = t, target_lang = "ja")
```

## How it works

The translate API is a plain-text translator (no system prompt), so the
Markdown structure is protected on the client side:

- The Markdown AST is walked and only inline text (paragraphs, headers, list
  items, admonition bodies, table cells, ...) is sent to the API.
- Inline code, math, `@ref` cross references, images, footnotes and URLs are
  replaced by placeholders `⟦n⟧` and restored verbatim afterwards.
- Code blocks (`jldoctest`, `math`, signatures, ...) and the `# Extended help`
  header are never sent.
- Paragraphs of one docstring are batched into a single request (≤ 4000
  characters; the API limit is 5000) because of the 30 requests/minute rate
  limit. HTTP 429 responses are retried after `Retry-After`; 5xx responses are
  retried with exponential backoff (both handled by Sarashina.jl). Failed
  requests raise `Sarashina.SarashinaError`.
- If a translated paragraph cannot be mapped back safely (e.g. a placeholder was
  dropped), the original paragraph is kept.

Supported languages are those of the API: `"ja"` and `"en"` (source is `"en"`).

## Tests

```sh
julia --project -e 'using Pkg; Pkg.test()'
```

Tests load `.env` with DotEnv.jl. When `SARASHINA_API_KEY` is available, live API
tests are run as well (set `SARASHINA_LIVE_TEST=false` to skip them).
