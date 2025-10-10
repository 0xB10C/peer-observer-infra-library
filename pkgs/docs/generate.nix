{
  pkgs,
  lib,
  runCommand,
  nixosOptionsDoc,
  ...
}:
let
  # evaluate our options
  eval = lib.evalModules {
    modules = [
      ../../modules/infra.nix
      {
        _module = {
          args.pkgs = pkgs;
          check = false;
        };
      }
    ];
  };
  # generate our docs
  optionsDoc = nixosOptionsDoc {
    inherit (eval) options;
  };
in
# create a derivation for capturing the markdown output
runCommand "docs.adoc" { } ''
  cat ${optionsDoc.optionsAsciiDoc} >> $out
''
