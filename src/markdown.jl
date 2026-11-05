# Translation of `Markdown.MD` documents.
#
# The Sarashina translate API is a plain-text translator: it takes no system
# prompt, so we cannot ask it to "keep the Markdown formatting". Instead we
# walk the Markdown AST ourselves and only send *inline text* to the API:
#
# 1. Every inline container (paragraph, header, table cell, ...) becomes a
#    `TranslationUnit`. Inline elements that must not change (code, math,
#    `@ref` links, images, footnote references, ...) are replaced with
#    placeholders `⟦n⟧`.
# 2. Units are joined with blank lines and sent in batches to stay well under
#    the request size and rate limits (30 requests/minute).
# 3. Each translated unit is parsed back as Markdown, its placeholders are
#    restored to the original inline objects, and the result is written back
#    into the AST. Block structure (code blocks, admonitions, lists, ...) is
#    never seen by the API, so it cannot be broken.
#
# If anything looks wrong for a unit (missing placeholder, unexpected block
# structure), the original text of that unit is kept.

"Maximum number of characters per batched request (the API limit is $(MAX_TEXT_LENGTH))."
const BATCH_TEXT_LENGTH = 4000

const PLACEHOLDER_REGEX = r"⟦(\d+)⟧"
placeholder(i::Integer) = "⟦$(i)⟧"

"Headers that must not be translated because they have a special meaning in Julia."
const UNTRANSLATED_HEADERS = ("extended help",)

struct TranslationUnit
    inlines::Vector{Any}   # the container in the AST; mutated in place
    text::String           # source text with placeholders
    protected::Vector{Any} # placeholder index (1-based) => original inline object
end

# ---------------------------------------------------------------------------
# Collect units from the AST
# ---------------------------------------------------------------------------

collect_units!(units, x) = units # Code, LaTeX, HorizontalRule, unknown blocks: keep as is

function collect_units!(units, md::Markdown.MD)
    foreach(c -> collect_units!(units, c), md.content)
    units
end

collect_units!(units, v::AbstractVector) = (foreach(c -> collect_units!(units, c), v); units)
collect_units!(units, p::Markdown.Paragraph) = add_unit!(units, p.content)

function collect_units!(units, h::Markdown.Header)
    h.text isa Vector{Any} || return units
    title = lowercase(strip(Markdown.plaininline(h.text)))
    title in UNTRANSLATED_HEADERS && return units
    add_unit!(units, h.text)
end

collect_units!(units, l::Markdown.List) = collect_units!(units, l.items)
collect_units!(units, q::Markdown.BlockQuote) = collect_units!(units, q.content)
collect_units!(units, a::Markdown.Admonition) = collect_units!(units, a.content)
function collect_units!(units, f::Markdown.Footnote)
    f.text isa AbstractVector && collect_units!(units, f.text)
    units
end

function collect_units!(units, t::Markdown.Table)
    for row in t.rows, cell in row
        cell isa Vector{Any} && add_unit!(units, cell)
    end
    units
end

function add_unit!(units, inlines::Vector{Any})
    protected = Any[]
    text = strip(protect_inlines(inlines, protected))
    # Nothing to translate: only whitespace, placeholders and punctuation.
    occursin(r"\p{L}", replace(text, PLACEHOLDER_REGEX => "")) || return units
    push!(units, TranslationUnit(inlines, text, protected))
    units
end

# ---------------------------------------------------------------------------
# Inline protection: inline objects -> Markdown text with placeholders
# ---------------------------------------------------------------------------

protect_inlines(xs::AbstractVector, protected) = join(protect_inline(x, protected) for x in xs)

function protect!(x, protected)
    push!(protected, x)
    placeholder(length(protected))
end

# Anything we do not know how to render safely is protected verbatim.
protect_inline(x, protected) = protect!(x, protected)
# Soft line breaks inside a paragraph become spaces so that every unit is one
# line; blank lines are used as unit separators in batched requests.
protect_inline(s::AbstractString, protected) = replace(s, r"\s*\n\s*" => " ")
protect_inline(b::Markdown.Bold, protected) = "**" * protect_inlines(b.text, protected) * "**"
protect_inline(i::Markdown.Italic, protected) = "*" * protect_inlines(i.text, protected) * "*"

function protect_inline(l::Markdown.Link, protected)
    # Cross references (`[`foo`](@ref)`, `[text](@ref Foo.bar)`) must be kept verbatim.
    startswith(l.url, "@") && return protect!(l, protected)
    texts = l.text isa AbstractVector ? l.text : Any[l.text]
    # Links whose label is only code (e.g. [`Base.sum`](url)) are kept verbatim as well.
    all(x -> x isa Markdown.Code, texts) && return protect!(l, protected)
    "[" * protect_inlines(texts, protected) * "](" * protect!(LinkURL(l.url), protected) * ")"
end

"Wrapper so a link URL can be stored as a placeholder and restored exactly."
struct LinkURL
    url::String
end

# ---------------------------------------------------------------------------
# Restoration: translated text -> inline objects
# ---------------------------------------------------------------------------

"""
    restore_inlines(text, protected) -> Union{Vector{Any},Nothing}

Parse translated `text` as Markdown and replace placeholders with the original
inline objects. Return `nothing` if the result cannot be trusted.
"""
function restore_inlines(text::AbstractString, protected::Vector{Any})
    md = Markdown.parse(strip(text))
    length(md.content) == 1 || return nothing
    p = only(md.content)
    p isa Markdown.Paragraph || return nothing
    used = zeros(Int, length(protected))
    restored = try
        restore_inline_vector(p.content, protected, used)
    catch e
        e isa PlaceholderError || rethrow()
        return nothing
    end
    all(==(1), used) || return nothing
    restored
end

struct PlaceholderError <: Exception end

function lookup(protected, used, i::Int)
    1 <= i <= length(protected) || throw(PlaceholderError())
    used[i] += 1
    protected[i]
end

function restore_inline_vector(xs::AbstractVector, protected, used)
    out = Any[]
    for x in xs
        append!(out, restore_inline(x, protected, used))
    end
    out
end

restore_inline(x, protected, used) = Any[x]

function restore_inline(s::AbstractString, protected, used)
    out = Any[]
    pos = firstindex(s)
    for m in eachmatch(PLACEHOLDER_REGEX, s)
        m.offset > pos && push!(out, s[pos:prevind(s, m.offset)])
        obj = lookup(protected, used, parse(Int, m.captures[1]))
        obj isa LinkURL && throw(PlaceholderError()) # URL placeholder outside a link
        push!(out, obj)
        pos = m.offset + ncodeunits(m.match)
    end
    pos <= lastindex(s) && push!(out, s[pos:end])
    out
end

function restore_inline(b::Markdown.Bold, protected, used)
    Any[Markdown.Bold(restore_inline_vector(b.text, protected, used))]
end

function restore_inline(i::Markdown.Italic, protected, used)
    Any[Markdown.Italic(restore_inline_vector(i.text, protected, used))]
end

function restore_inline(l::Markdown.Link, protected, used)
    m = match(r"^⟦(\d+)⟧$", strip(l.url))
    m === nothing && throw(PlaceholderError())
    url = lookup(protected, used, parse(Int, m.captures[1]))
    url isa LinkURL || throw(PlaceholderError())
    texts = l.text isa AbstractVector ? l.text : Any[l.text]
    Any[Markdown.Link(restore_inline_vector(texts, protected, used), url.url)]
end

# ---------------------------------------------------------------------------
# Batching
# ---------------------------------------------------------------------------

function make_batches(units::Vector{TranslationUnit}, limit::Integer = BATCH_TEXT_LENGTH)
    batches = Vector{Vector{TranslationUnit}}()
    current = TranslationUnit[]
    len = 0
    for u in units
        l = length(u.text) + 2
        if !isempty(current) && len + l > limit
            push!(batches, current)
            current = TranslationUnit[]
            len = 0
        end
        push!(current, u)
        len += l
    end
    isempty(current) || push!(batches, current)
    batches
end

"""
    translate_units(translator, units; source_lang, target_lang) -> Vector{String}

Translate units in batches. A batch whose output does not split back into the
same number of paragraphs is retried one unit at a time.
"""
function translate_units(translator, units::Vector{TranslationUnit}; source_lang, target_lang)
    results = String[]
    for batch in make_batches(units)
        if length(batch) > 1
            joined = join((u.text for u in batch), "\n\n")
            translated = translate_text(translator, joined; source_lang, target_lang)
            parts = split(strip(translated), r"\n[ \t]*\n+")
            if length(parts) == length(batch)
                append!(results, String.(strip.(parts)))
                continue
            end
            @debug "Batched translation returned $(length(parts)) paragraphs for $(length(batch)) units; translating one by one"
        end
        for u in batch
            push!(results, String(strip(translate_text(translator, u.text; source_lang, target_lang))))
        end
    end
    results
end

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

"""
    translate_md!(md::Markdown.MD; translator=default_translator(),
                  source_lang="en", target_lang=DEFAULT_LANG[]) -> md

Translate the text of a Markdown document in place with the Sarashina translate API.

Code blocks, math, inline code, cross references (`[`foo`](@ref)`), URLs and the
`# Extended help` header are left untouched. Paragraphs whose translation cannot be
mapped back safely keep their original text.
"""
function translate_md!(
    md::Markdown.MD;
    translator::AbstractTranslator = default_translator(),
    source_lang::AbstractString = SOURCE_LANG[],
    target_lang::AbstractString = DEFAULT_LANG[],
)
    validate_langs(source_lang, target_lang)
    source_lang == target_lang && return md
    units = collect_units!(TranslationUnit[], md)
    isempty(units) && return md
    translated = translate_units(translator, units; source_lang, target_lang)
    for (u, t) in zip(units, translated)
        restored = restore_inlines(t, u.protected)
        if restored === nothing
            @debug "Could not restore the translated text; keeping the original" u.text t
            continue
        end
        empty!(u.inlines)
        append!(u.inlines, restored)
    end
    md
end

"""
    translate_md(md; kwargs...) -> Markdown.MD

Non-mutating version of [`translate_md!`](@ref). `md` may also be a Markdown string.
"""
# `md.meta` may hold a `Module`, which cannot be deep-copied; copy only the content.
translate_md(md::Markdown.MD; kwargs...) =
    translate_md!(Markdown.MD(deepcopy(md.content), copy(md.meta)); kwargs...)
translate_md(md::AbstractString; kwargs...) = translate_md!(Markdown.parse(md); kwargs...)
