"""
    DocstringTranslationSarashinaBackend

Translate Julia docstrings with the Sarashina translate API
(`sarashina3.2-translate`), inspired by DocstringTranslation.jl.

```julia
using DocstringTranslationSarashinaBackend
@switchlang! "ja"   # requires ENV["SARASHINA_API_KEY"]
```
"""
module DocstringTranslationSarashinaBackend

using Base.Docs: DocStr

using HTTP
using JSON
using Markdown
using SHA
using Scratch

const SUPPORTED_LANGS = ("ja", "en")
const SUPPORTED_STYLES = ("auto", "plain", "polite")

const DEFAULT_LANG = Ref{String}("en")
const SOURCE_LANG = Ref{String}("en")
const TRANSLATION_CACHE_DIR = Ref{String}()

include("api.jl")
include("markdown.jl")
include("cache.jl")
include("switchlang.jl")

export @switchlang!
export SarashinaTranslator, translate_text, translate_md, translate_md!

function __init__()
    TRANSLATION_CACHE_DIR[] = @get_scratch!("translation")
end

end # module DocstringTranslationSarashinaBackend
