"""
    switchstyle!(style)

Set the Japanese writing style of the default translator:
`"auto"`, `"plain"` (だ・である調) or `"polite"` (です・ます調).
"""
function switchstyle!(style::AbstractString)
    t = default_translator()
    t isa SarashinaTranslator ||
        throw(ArgumentError("switchstyle! requires the default translator to be a SarashinaTranslator"))
    switchtranslator!(SarashinaTranslator(t.api_key, t.endpoint, String(style), t.max_retries, t.readtimeout))
end

function _switchlang!(lang::Union{AbstractString,Symbol})
    l = String(lang)
    l in SUPPORTED_LANGS ||
        throw(ArgumentError("Sarashina translate supports $(SUPPORTED_LANGS) only, got $(repr(l))"))
    DEFAULT_LANG[] = l
end

"""
    try_translate_docstring(md; translator=default_translator(), lang=DEFAULT_LANG[])

Return the translation of a docstring into `lang`, or `nothing` if it cannot be
translated now (no API key, API error). `md.meta[:module]` must be set.
Translations are cached on disk per [`translationkey`](@ref).
"""
function try_translate_docstring(
    md::Markdown.MD;
    translator::AbstractTranslator = default_translator(),
    lang::AbstractString = DEFAULT_LANG[],
)
    lang == SOURCE_LANG[] && return md
    key = translationkey(translator, lang)
    if istranslated(md, key)
        translated = load_translation(md, key)
    else
        canrequest(translator) || return nothing
        translated = try
            translate_md(md; translator, target_lang = lang)
        catch e
            @warn "Failed to translate docstring with the Sarashina API; showing the original" exception = e
            return nothing
        end
        cache_original(md)
        cache_translation(hashmd(md), translated, key)
    end
    merge!(translated.meta, md.meta)
    translated
end

"""
    translate_docstring(md; kwargs...) -> Markdown.MD

Like [`try_translate_docstring`](@ref), but return `md` unchanged when it cannot
be translated.
"""
translate_docstring(md::Markdown.MD; kwargs...) = something(try_translate_docstring(md; kwargs...), md)

# Same as `REPL.formatdoc(::DocStr)`, which is not available when REPL is not loaded
# (e.g. in scripts and tests).
function formatdocstr(d::DocStr)
    buffer = IOBuffer()
    for part in d.text
        print(buffer, part)
    end
    md = Markdown.MD(Any[Markdown.parse(seekstart(buffer))])
    assume_julia_code!(md)
end

assume_julia_code!(x) = x
function assume_julia_code!(md::Markdown.MD)
    foreach(assume_julia_code!, md.content)
    md
end
function assume_julia_code!(c::Markdown.Code)
    isempty(c.language) && (c.language = "julia")
    c
end

# Translated docstrings kept in memory: DocStr => (translation key => translation).
# `d.object` itself always holds the original (untranslated) document, so that
# switching the language or the style takes effect on the next lookup.
const TRANSLATED_DOCS = WeakKeyDict{DocStr,Dict{String,Markdown.MD}}()

function original_doc(d::DocStr)
    if d.object === nothing
        d.object = formatdocstr(d)
    end
    md = d.object
    if md isa Markdown.MD
        md.meta[:module] = d.data[:module]
        md.meta[:path] = d.data[:path]
    end
    md
end

function parsedoc_with_translation(d::DocStr)
    md = original_doc(d)
    md isa Markdown.MD || return md
    lang = DEFAULT_LANG[]
    lang == SOURCE_LANG[] && return md
    translator = default_translator()
    key = translationkey(translator, lang)
    variants = get!(Dict{String,Markdown.MD}, TRANSLATED_DOCS, d)
    haskey(variants, key) && return variants[key]
    translated = try_translate_docstring(md; translator, lang)
    # Not memoized on failure, so the next lookup retries.
    translated === nothing && return md
    variants[key] = translated
end

"""
    @switchlang!(lang)

Switch the language of docstrings to `lang` (`"ja"` or `"en"`).

`Docs.parsedoc` is overridden so that every docstring is translated with the
Sarashina translate API (`sarashina3.2-translate`) when it is first displayed
(e.g. via `?sum` in the REPL). Translations are cached in a scratch space, so
each docstring is translated only once. `ENV["SARASHINA_API_KEY"]` must be set.

# Example
```julia
using DocstringTranslationSarashinaBackend
@switchlang! "ja"
DocstringTranslationSarashinaBackend.switchstyle!("polite") # optional: です・ます調
```
"""
macro switchlang!(lang)
    quote
        local _lang = $(esc(lang))
        $(_switchlang!)(_lang)
        $(install_parsedoc_override)()
        _lang
    end
end

const PARSEDOC_OVERRIDDEN = Ref(false)

function install_parsedoc_override()
    PARSEDOC_OVERRIDDEN[] && return nothing
    if !haskey(ENV, "SARASHINA_API_KEY")
        @warn "ENV[\"SARASHINA_API_KEY\"] is not set; docstrings will not be translated until it is set."
    end
    @eval Docs.parsedoc(d::DocStr) = $(parsedoc_with_translation)(d)
    PARSEDOC_OVERRIDDEN[] = true
    nothing
end
