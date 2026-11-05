const SARASHINA_TRANSLATE_ENDPOINT = "https://api.sarashina.ai/v1/translate"
"Maximum number of characters (Unicode code points) accepted by one translate request."
const MAX_TEXT_LENGTH = 5000

"""
    AbstractTranslator

Supertype of translation backends. A subtype `T` must implement

    translate_text(t::T, text::AbstractString; source_lang, target_lang)::String
"""
abstract type AbstractTranslator end

"""
    SarashinaAPIError(status, message)

Error returned by the Sarashina API (non-2xx HTTP status).
"""
struct SarashinaAPIError <: Exception
    status::Int
    message::String
end

function Base.showerror(io::IO, e::SarashinaAPIError)
    print(io, "SarashinaAPIError: HTTP ", e.status, ": ", e.message)
    if e.status == 401
        print(io, "\nCheck that ENV[\"SARASHINA_API_KEY\"] holds a valid API key ",
            "(issue one at https://chat.sarashina.ai/dashboard/api-keys).")
    elseif e.status == 403
        print(io, "\nThe Sarashina API rejects access from outside Japan.")
    end
end

"""
    SarashinaTranslator(; api_key=nothing, endpoint=SARASHINA_TRANSLATE_ENDPOINT,
                          style="auto", max_retries=5, readtimeout=120)

Translator backed by the Sarashina translate API (`sarashina3.2-translate`).

- `api_key`: API key. When `nothing`, `ENV["SARASHINA_API_KEY"]` is read at request time.
- `style`: Japanese writing style, one of `"auto"`, `"plain"` (だ・である調) or
  `"polite"` (です・ます調). Only used when the target language is `"ja"`.
- `max_retries`: retries on HTTP 429 (honoring `Retry-After`) and 5xx responses.
"""
struct SarashinaTranslator <: AbstractTranslator
    api_key::Union{Nothing,String}
    endpoint::String
    style::String
    max_retries::Int
    readtimeout::Int
    function SarashinaTranslator(api_key, endpoint, style, max_retries, readtimeout)
        style in SUPPORTED_STYLES ||
            throw(ArgumentError("style must be one of $(SUPPORTED_STYLES), got $(repr(style))"))
        max_retries >= 0 || throw(ArgumentError("max_retries must be non-negative"))
        new(api_key, endpoint, style, max_retries, readtimeout)
    end
end

function SarashinaTranslator(;
    api_key::Union{Nothing,AbstractString} = nothing,
    endpoint::AbstractString = get(ENV, "SARASHINA_TRANSLATE_ENDPOINT", SARASHINA_TRANSLATE_ENDPOINT),
    style::AbstractString = "auto",
    max_retries::Integer = 5,
    readtimeout::Integer = 120,
)
    key = api_key === nothing ? nothing : String(api_key)
    SarashinaTranslator(key, String(endpoint), String(style), Int(max_retries), Int(readtimeout))
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

function request_body(t::SarashinaTranslator, text, source_lang, target_lang)
    body = Dict{String,Any}("text" => text, "source_lang" => source_lang, "target_lang" => target_lang)
    # `style` only applies when translating into Japanese.
    target_lang == "ja" && (body["style"] = t.style)
    JSON.json(body)
end

function error_message(body::AbstractString)
    try
        d = JSON.parse(body)
        return string(get(d, "message", body))
    catch
        return String(body)
    end
end

function retry_after_seconds(resp)
    v = HTTP.header(resp, "Retry-After", "")
    s = tryparse(Int, strip(v))
    s === nothing ? 60 : clamp(s, 1, 120)
end

function request_translation(t::SarashinaTranslator, text::AbstractString, source_lang, target_lang)
    headers = ["Authorization" => "Bearer $(apikey(t))", "Content-Type" => "application/json"]
    body = request_body(t, text, source_lang, target_lang)
    attempt = 0
    while true
        resp = HTTP.post(t.endpoint, headers, body; status_exception = false, read_idle_timeout = t.readtimeout)
        status = Int(resp.status)
        if 200 <= status < 300
            return string(JSON.parse(String(resp.body))["translated_text"])
        end
        msg = error_message(String(resp.body))
        retryable = status == 429 || status in (500, 502, 503, 504)
        if retryable && attempt < t.max_retries
            wait = status == 429 ? retry_after_seconds(resp) : min(2.0^attempt, 30.0)
            @debug "Sarashina API returned $(status); retrying in $(wait) s" msg
            sleep(wait)
            attempt += 1
            continue
        end
        throw(SarashinaAPIError(status, msg))
    end
end
