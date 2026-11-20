"Maximum number of characters (Unicode code points) accepted by one translate request."
const MAX_TEXT_LENGTH = 5000

"""
    AbstractTranslator

Supertype of translation backends. A subtype `T` must implement

    translate_text(t::T, text::AbstractString; source_lang, target_lang)::String
"""
abstract type AbstractTranslator end

"""
    SarashinaTranslator(; api_key=nothing, base_url=Sarashina.DEFAULT_BASE_URL,
                          style="auto", max_retries=5, readtimeout=120)

Translator backed by the Sarashina translate API (`sarashina3.2-translate`),
called through [Sarashina.jl](https://github.com/AtelierArith/Sarashina.jl).
Failed requests raise `Sarashina.SarashinaError`.

- `api_key`: API key. When `nothing`, `ENV["SARASHINA_API_KEY"]` is read at request time.
- `style`: Japanese writing style, one of `"auto"`, `"plain"` (だ・である調) or
  `"polite"` (です・ます調). Only used when the target language is `"ja"`.
- `max_retries`: retries on HTTP 429 (honoring `Retry-After`) and 5xx responses.
- `readtimeout`: seconds without incoming data before a request fails.
"""
struct SarashinaTranslator <: AbstractTranslator
    api_key::Union{Nothing,String}
    base_url::String
    style::String
    max_retries::Int
    readtimeout::Int
    function SarashinaTranslator(api_key, base_url, style, max_retries, readtimeout)
        style in SUPPORTED_STYLES ||
            throw(ArgumentError("style must be one of $(SUPPORTED_STYLES), got $(repr(style))"))
        max_retries >= 0 || throw(ArgumentError("max_retries must be non-negative"))
        new(api_key, base_url, style, max_retries, readtimeout)
    end
end

function SarashinaTranslator(;
    api_key::Union{Nothing,AbstractString} = nothing,
    base_url::AbstractString = Sarashina.DEFAULT_BASE_URL,
    style::AbstractString = "auto",
    max_retries::Integer = 5,
    readtimeout::Integer = 120,
)
    key = api_key === nothing ? nothing : String(api_key)
    SarashinaTranslator(key, String(base_url), String(style), Int(max_retries), Int(readtimeout))
end

function apikey(t::SarashinaTranslator)
    t.api_key !== nothing && return t.api_key
    haskey(ENV, "SARASHINA_API_KEY") && return ENV["SARASHINA_API_KEY"]
    throw(ArgumentError("No API key: set ENV[\"SARASHINA_API_KEY\"] or pass `api_key` to SarashinaTranslator."))
end

const DEFAULT_TRANSLATOR = Ref{AbstractTranslator}(SarashinaTranslator())

"""
    default_translator()

Return the translator used by `@switchlang!` and `translate_md`.
"""
default_translator() = DEFAULT_TRANSLATOR[]

"""
    switchtranslator!(t::AbstractTranslator)

Replace the default translator, e.g. `switchtranslator!(SarashinaTranslator(style="polite"))`.
"""
switchtranslator!(t::AbstractTranslator) = (DEFAULT_TRANSLATOR[] = t)

"""
    translationkey(translator, target_lang) -> String

Identifier of a translation variant, used as the cache key. Translations that
differ in writing style must have different keys.
"""
translationkey(::AbstractTranslator, target_lang::AbstractString) = String(target_lang)
translationkey(t::SarashinaTranslator, target_lang::AbstractString) =
    target_lang == "ja" ? "$(target_lang)-$(t.style)" : String(target_lang)

"""
    canrequest(translator) -> Bool

Whether `translator` is ready to send requests (e.g. an API key is available).
"""
canrequest(::AbstractTranslator) = true
canrequest(t::SarashinaTranslator) = t.api_key !== nothing || haskey(ENV, "SARASHINA_API_KEY")

function validate_langs(source_lang::AbstractString, target_lang::AbstractString)
    source_lang in SUPPORTED_LANGS ||
        throw(ArgumentError("source_lang must be one of $(SUPPORTED_LANGS), got $(repr(source_lang))"))
    target_lang in SUPPORTED_LANGS ||
        throw(ArgumentError("target_lang must be one of $(SUPPORTED_LANGS), got $(repr(target_lang))"))
    nothing
end

"""
    translate_text([translator,] text; source_lang="en", target_lang=DEFAULT_LANG[]) -> String

Translate plain text. Text longer than $(MAX_TEXT_LENGTH) characters is split into
several requests. When `source_lang == target_lang`, `text` is returned unchanged.
"""
translate_text(text::AbstractString; kwargs...) = translate_text(default_translator(), text; kwargs...)

function translate_text(
    t::SarashinaTranslator,
    text::AbstractString;
    source_lang::AbstractString = SOURCE_LANG[],
    target_lang::AbstractString = DEFAULT_LANG[],
)
    validate_langs(source_lang, target_lang)
    source_lang == target_lang && return String(text)
    isempty(strip(text)) && return String(text)
    chunks = split_text(text, MAX_TEXT_LENGTH)
    join((request_translation(t, c, source_lang, target_lang) for c in chunks), "")
end

"""
    split_text(text, limit) -> Vector{String}

Split `text` into chunks of at most `limit` characters, preferring to cut at
blank lines, then newlines, then sentence ends, then spaces.
"""
function split_text(text::AbstractString, limit::Integer)
    chunks = String[]
    rest = String(text)
    while length(rest) > limit
        head = first(rest, limit)
        cut = nothing
        for pat in (r"\n\s*\n", r"\n", r"[.!?。！？]\s", r"\s")
            ms = collect(eachmatch(pat, head))
            if !isempty(ms)
                m = last(ms)
                cut = prevind(head, m.offset + ncodeunits(m.match))
                break
            end
        end
        cut = something(cut, lastindex(head))
        push!(chunks, rest[1:cut])
        rest = rest[nextind(rest, cut):end]
    end
    isempty(rest) || push!(chunks, rest)
    chunks
end

"""
    client(t::SarashinaTranslator) -> Sarashina.Client

Build the API client for `t`. The API key is resolved at request time, so that a
translator can be created before `ENV["SARASHINA_API_KEY"]` is set.
"""
client(t::SarashinaTranslator) = Sarashina.Client(;
    api_key = apikey(t),
    base_url = t.base_url,
    max_retries = t.max_retries,
    read_idle_timeout = t.readtimeout,
)

function request_translation(t::SarashinaTranslator, text::AbstractString, source_lang, target_lang)
    # `style` only applies when translating into Japanese.
    style = target_lang == "ja" ? t.style : nothing
    Sarashina.translate(client(t), text; source_lang, target_lang, style)
end
