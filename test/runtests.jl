using Test
using Markdown
using DotEnv

# Load SARASHINA_API_KEY from <package root>/.env if present (used by the live API tests).
const DOTENV_PATH = joinpath(dirname(@__DIR__), ".env")
isfile(DOTENV_PATH) && DotEnv.load!(DOTENV_PATH)
using DocstringTranslationSarashinaBackend
using DocstringTranslationSarashinaBackend:
    AbstractTranslator,
    SarashinaAPIError,
    split_text,
    request_body,
    translate_docstring,
    switchtranslator!,
    switchtranslationcachedir!,
    switchstyle!,
    default_translator,
    DEFAULT_LANG

"""
Fake translator: wraps every paragraph in `<...>` and counts requests.
Placeholders and Markdown markup are kept, like the real API does.
"""
mutable struct MockTranslator <: AbstractTranslator
    requests::Vector{String}
    transform::Function
end
MockTranslator(f = s -> "<" * s * ">") = MockTranslator(String[], f)

function DocstringTranslationSarashinaBackend.translate_text(
    t::MockTranslator, text::AbstractString; source_lang, target_lang,
)
    push!(t.requests, text)
    join((t.transform(p) for p in split(text, "\n\n")), "\n\n")
end

"Fake translator that merges all paragraphs into one (breaks batching)."
struct Merger <: AbstractTranslator
    calls::Vector{String}
end
DocstringTranslationSarashinaBackend.translate_text(m::Merger, text::AbstractString; kwargs...) =
    (push!(m.calls, text); replace(text, "\n\n" => " "))

module DocTarget
"Return the answer."
answer() = 42
end

const SAMPLE = """
    add(x, y)

Return the sum of `x` and `y`. See [`Base.sum`](@ref) and
[the manual](https://docs.julialang.org/en/v1/) for ``\\alpha``.

# Arguments

- `x::Number`: the first value
- `y::Number`: the **second** value

!!! note "Performance"
    This function is pure.

```jldoctest
julia> add(1, 2)
3
```

| Name | Description |
|:-----|:------------|
| `x`  | first value |

# Extended help

More details.
"""

@testset "DocstringTranslationSarashinaBackend" begin
    @testset "translate_md keeps structure" begin
        t = MockTranslator()
        md = Markdown.parse(SAMPLE)
        out = translate_md(md; translator = t, target_lang = "ja")
        s = string(out)
        # one batched request for the whole docstring
        @test length(t.requests) == 1
        # input is not mutated
        @test string(md) == string(Markdown.parse(SAMPLE))
        # code block untouched
        @test occursin("```jldoctest\njulia> add(1, 2)\n3\n```", s)
        @test out.content[1] isa Markdown.Code
        # protected inline objects are restored verbatim
        p = out.content[2]
        @test p isa Markdown.Paragraph
        @test p.content[1] == "<Return the sum of "
        @test p.content[2] isa Markdown.Code && p.content[2].code == "x"
        @test any(x -> x isa Markdown.Link && x.url == "@ref", p.content)
        @test any(x -> x isa Markdown.Link && x.url == "https://docs.julialang.org/en/v1/", p.content)
        @test any(x -> x isa Markdown.LaTeX && x.formula == "\\alpha", p.content)
        # placeholders never leak
        @test !occursin("⟦", s)
        # headers, lists, bold, admonitions, tables are translated
        @test occursin("# <Arguments>", s)
        @test occursin("**second**", s)
        @test occursin("<This function is pure.>", s)
        @test out.content[findfirst(x -> x isa Markdown.Admonition, out.content)].title == "Performance"
        @test occursin("<first value>", s)
        # Extended help header is not translated, but its body is
        @test occursin("# Extended help", s)
        @test occursin("<More details.>", s)
    end

    @testset "fallbacks" begin
        # batch with mismatching paragraph count -> one by one
        md = Markdown.parse("First paragraph.\n\nSecond paragraph.")
        m = Merger(String[])
        out = translate_md(md; translator = m, target_lang = "ja")
        @test length(m.calls) == 3
        @test string(out) == string(md)

        # dropped placeholder -> keep original paragraph
        drop = MockTranslator(s -> replace(s, r"⟦\d+⟧" => ""))
        md = Markdown.parse("Use `foo` here.")
        out = translate_md(md; translator = drop, target_lang = "ja")
        @test string(out) == string(md)

        # same language -> no requests
        t = MockTranslator()
        @test string(translate_md(md; translator = t, target_lang = "en")) == string(md)
        @test isempty(t.requests)
        @test_throws ArgumentError translate_md(md; translator = t, target_lang = "fr")
    end

    @testset "split_text" begin
        text = join(fill("あいうえお。", 2000))
        chunks = split_text(text, 5000)
        @test join(chunks) == text
        @test all(c -> length(c) <= 5000, chunks)
        @test split_text("short", 5000) == ["short"]
        @test join(split_text("a"^12000, 5000)) == "a"^12000
    end

    @testset "SarashinaTranslator" begin
        @test_throws ArgumentError SarashinaTranslator(style = "casual")
        t = SarashinaTranslator(api_key = "dummy", style = "plain")
        b = request_body(t, "Hello", "en", "ja")
        @test occursin("\"style\":\"plain\"", b)
        @test !occursin("style", request_body(t, "こんにちは", "ja", "en"))
        @test translate_text(t, "Hello"; source_lang = "en", target_lang = "en") == "Hello"
        @test_throws ArgumentError translate_text(t, "Hello"; source_lang = "en", target_lang = "zh")
        @test occursin("SARASHINA_API_KEY", sprint(showerror, SarashinaAPIError(401, "Unauthorized")))
    end

    @testset "@switchlang! and cache" begin
        dir = mktempdir()
        switchtranslationcachedir!(dir)
        old = default_translator()
        t = MockTranslator()
        switchtranslator!(t)
        try
            @switchlang! "ja"
            @test DEFAULT_LANG[] == "ja"
            @test_throws ArgumentError @switchlang! "de"
            md = Markdown.parse("Compute something.")
            md.meta[:module] = Base
            md.meta[:path] = "dummy.jl"
            out = translate_docstring(md)
            @test occursin("<Compute something.>", string(out))
            @test out.meta[:module] === Base
            @test length(t.requests) == 1
            # second call hits the cache
            out2 = translate_docstring(md)
            @test string(out2) == string(out)
            @test length(t.requests) == 1
            @test !isempty(readdir(dir))

            # Docs.parsedoc is overridden
            multidoc = Base.Docs.meta(DocTarget)[Base.Docs.Binding(DocTarget, :answer)]
            docstr = first(values(multidoc.docs))
            doc = string(Base.invokelatest(Base.Docs.parsedoc, docstr))
            @test occursin("<Return the answer.>", doc)
        finally
            switchtranslator!(old)
            DEFAULT_LANG[] = "en"
        end
    end

    @testset "switchstyle!" begin
        old = default_translator()
        try
            switchstyle!("polite")
            @test default_translator().style == "polite"
        finally
            switchtranslator!(old)
        end
    end

    if haskey(ENV, "SARASHINA_API_KEY") && get(ENV, "SARASHINA_LIVE_TEST", "true") == "true"
        @testset "Sarashina API (live)" begin
            t = SarashinaTranslator()
            ja = translate_text(t, "Return the sum of two numbers."; source_lang = "en", target_lang = "ja")
            @test occursin("和", ja)
            out = translate_md(Markdown.parse(SAMPLE); translator = t, target_lang = "ja")
            s = string(out)
            @test occursin("```jldoctest\njulia> add(1, 2)\n3\n```", s)
            @test occursin("https://docs.julialang.org/en/v1/", s)
            @test occursin("[`Base.sum`](@ref)", s)
            @test occursin("# Extended help", s)
            @test !occursin("⟦", s)
        end
    else
        @info "SARASHINA_API_KEY is not set; skipping live API tests"
    end
end

@testset "Aqua" begin
    using Aqua
    Aqua.test_all(DocstringTranslationSarashinaBackend; piracies = false)
end
