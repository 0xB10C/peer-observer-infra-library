{
  config,
  lib,
  pkgs,
  peer-observer-infra-library,
  ...
}:

let
  baseOptions = (import ./base/base.nix { inherit config lib pkgs; }).options;
  webOptions = (import ./web/web.nix { inherit config lib pkgs; }).options;
  nodeOptions =
    (import ./node/node.nix {
      inherit
        config
        lib
        pkgs
        peer-observer-infra-library
        ;
    }).options;
in
{
  options.peer-observer = {
    base = lib.mkOption {
      type = lib.types.submodule { options = baseOptions; };
    };
    node = lib.mkOption {
      type = lib.types.submodule { options = nodeOptions; };
    };
    web = lib.mkOption {
      type = lib.types.submodule { options = webOptions; };
    };
  };

  config = {
    # TODO: assert that it's either a node or web
  };
}
