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
    translate_docstring(md::Markdown.MD) -> Markdown.MD

Return the translation of a docstring into `DEFAULT_LANG[]`, using the cache when
available. `md.meta[:module]` must be set. On API errors, a warning is emitted and
`md` is returned unchanged.
"""
function translate_docstring(md::Markdown.MD)
    lang = DEFAULT_LANG[]
    lang == SOURCE_LANG[] && return md
    meta = md.meta
    if istranslated(md, lang)
        translated = load_translation(md, lang)
    else
        if default_translator() isa SarashinaTranslator &&
           default_translator().api_key === nothing && !haskey(ENV, "SARASHINA_API_KEY")
            return md
        end
        hash_original = hashmd(md)
        translated = try
            translate_md(md)
        catch e
            @warn "Failed to translate docstring with the Sarashina API; showing the original" exception = e
            return md
        end
        translated.meta = copy(meta)
        cache_original(md)
        cache_translation(hash_original, translated, lang)
    end
    merge!(translated.meta, meta)
    translated
end

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

function parsedoc_with_translation(d::DocStr)
    if d.object === nothing
        md = formatdocstr(d)
        md.meta[:module] = d.data[:module]
        md.meta[:path] = d.data[:path]
        d.object = translate_docstring(md)
    end
    d.object
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
