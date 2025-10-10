{
  lib,
  pkgs,
  github_url,
  stdenv,
  mkdocs,
  python3Packages,
  ...
}:
let
  generate-docs = pkgs.callPackage ./generate.nix { };
in
stdenv.mkDerivation {
  src = ./.;
  name = "docs";

  nativeBuildInputs = [ pkgs.asciidoctor ];

  patchPhase = ''
    cp ${generate-docs} docs.adoc
    cat docs.adoc
    # remove all zero-width-spaces
    sed -i 's#{zwsp}##g' docs.adoc
    sed -E -i 's#file:///nix/store/[a-z0-9]{32}-source/#${github_url}#g' docs.adoc
    sed -E -i 's#/nix/store/[a-z0-9]{32}-source/##g' docs.adoc
  '';

  buildPhase = ''
    mkdir -p $out
    asciidoctor -o $out/index.html docs.adoc
  '';
}
