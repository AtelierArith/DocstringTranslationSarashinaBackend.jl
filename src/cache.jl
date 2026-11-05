# Translation cache, stored in this package's scratch space.
#
# Layout (same idea as DocstringTranslation.jl):
#
#     <cache dir>/<Root>/<major.minor>/<Sub>/.../<sha256 of original>/original.md
#                                                                    /<lang>.md
#
# where `Root.Sub...` is the module that owns the docstring and `major.minor`
# is its package version (or Julia's `VERSION` for Base/stdlibs).

"""
    switchtranslationcachedir!(dir)

Store translated docstrings under `dir` instead of the package scratch space.
"""
switchtranslationcachedir!(dir::AbstractString) = (TRANSLATION_CACHE_DIR[] = String(dir))

hashmd(md::Markdown.MD)::String = bytes2hex(sha256(string(md)))

function prevminor(v::VersionNumber)
    VersionNumber(v.major, max(0, v.minor - 1), 0)
end

function insertversion(svec::AbstractVector, v::VersionNumber)
    out = String.(svec)
    insert!(out, min(2, length(out) + 1), "$(v.major).$(v.minor)")
    out
end

function moduleversion(m::Module)
    v = try
        pkgversion(m)
    catch
        nothing
    end
    something(v, VERSION)
end

"""
    pathofcachedir(md::Markdown.MD, allowold=false)

Directory where translations of docstrings of `md.meta[:module]` are stored.
With `allowold=true`, fall back to the previous minor version's directory when
the current one does not exist.
"""
function pathofcachedir(md::Markdown.MD, allowold::Bool = false)
    haskey(md.meta, :module) || throw(ArgumentError("No :module found in the markdown metadata."))
    mod = md.meta[:module]
    svec = split(string(mod), ".")
    v = moduleversion(mod)
    d = joinpath(TRANSLATION_CACHE_DIR[], insertversion(svec, v)...)
    if !isdir(d) && allowold
        return joinpath(TRANSLATION_CACHE_DIR[], insertversion(svec, prevminor(v))...)
    end
    d
end

translationpath(md::Markdown.MD, hash::AbstractString, lang::AbstractString) =
    joinpath(pathofcachedir(md, true), hash, lang * ".md")

istranslated(md::Markdown.MD, lang::AbstractString = DEFAULT_LANG[]) =
    isfile(translationpath(md, hashmd(md), lang))

"""
    postprocess_content(content)

Convert `\$\$ ... \$\$` blocks into `math` code fences, which is how Julia's
Markdown parser expects display math.
"""
function postprocess_content(content::AbstractString)
    replace(content, r"\$\$(.*?)\$\$"s => s"```math\1```")
end

function load_translation(md::Markdown.MD, lang::AbstractString = DEFAULT_LANG[])
    path = translationpath(md, hashmd(md), lang)
    Markdown.parse(postprocess_content(read(path, String)))
end

function cache_original(md::Markdown.MD)
    dir = joinpath(pathofcachedir(md), hashmd(md))
    mkpath(dir)
    write(joinpath(dir, "original.md"), string(md))
end

function cache_translation(hash_original::AbstractString, transmd::Markdown.MD, lang::AbstractString = DEFAULT_LANG[])
    dir = joinpath(pathofcachedir(transmd), hash_original)
    mkpath(dir)
    write(joinpath(dir, lang * ".md"), string(transmd))
end
