using EEMaps
using Documenter

DocMeta.setdocmeta!(EEMaps, :DocTestSetup, :(using EEMaps); recursive=true)

makedocs(;
    modules=[EEMaps],
    authors="marcos <marcosdasilva@5a.tec.br> and contributors",
    sitename="EEMaps.jl",
    format=Documenter.HTML(;
        canonical="https://marcosdasilva.github.io/EEMaps.jl",
        edit_link="master",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/marcosdasilva/EEMaps.jl",
    devbranch="master",
)
