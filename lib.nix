{
  nixpkgs,
  agenix,
  b10c-nix,
  system,
  ...
}:

let

  pkgs = import nixpkgs { inherit system; };
  lib = pkgs.lib;

  mkModules =
    extraModules:
    [
      ./modules/infra.nix
      ./modules/peer-observer.nix
      ./modules/base/base.nix
      ./modules/web/web.nix
      ./modules/node/node.nix
      ./modules/node/profiling.nix

      agenix.nixosModules.default

      b10c-nix.nixosModules.default.fork-observer
      b10c-nix.nixosModules.default.addrman-observer
      b10c-nix.nixosModules.default.peer-observer

    ]
    # e.g. hardware-configuration.nix or disko.nix
    ++ extraModules;

  mkSystem =
    config: extraModules: arch:
    nixpkgs.lib.nixosSystem {
      system = arch;
      modules = (mkModules extraModules) ++ [ config ];
    };

  mkNodeConfig =
    name: nodeConfig: infraConfig:
    infraConfig.global.extraConfig
    // nodeConfig.extraConfig
    // {
      infra = infraConfig;
      peer-observer = {
        node = nodeConfig // {
          enable = true;
        };
        web = {
          enable = false;
        };
        base = {
          inherit name;
          inherit (nodeConfig)
            description
            setup
            wireguard
            arch
            ;
          b10c-pkgs = b10c-nix.packages."${nodeConfig.arch}";
        };
      };
    };

  mkWebConfig =
    name: webConfig: infraConfig:
    infraConfig.global.extraConfig
    // webConfig.extraConfig
    // {
      infra = infraConfig;
      peer-observer = {
        web = webConfig // {
          enable = true;
        };
        node = {
          enable = false;
        };
        base = {
          inherit name;
          inherit (webConfig)
            setup
            description
            wireguard
            arch
            ;
          b10c-pkgs = b10c-nix.packages."${webConfig.arch}";
        };
      };
    };

  mkBitcoind = pkgs.callPackage ./pkgs/bitcoind/default.nix { };
  mkCustomBitcoind = overrides: mkBitcoind overrides;

  # The constants the modules of this library are built around: ports, nginx
  # paths, directories, and the hardcoded-but-public credentials. Exposed so
  # downstream flakes can refer to the same values (e.g. from extraConfig)
  # instead of duplicating them and drifting apart.
  constants = import ./modules/constants.nix;

in
{

  inherit
    mkModules
    mkNodeConfig
    mkWebConfig
    mkCustomBitcoind
    constants
    ;

  mkConfigurations =
    infraConfig:
    let
      nodeConfigs = lib.mapAttrs (
        name: node: mkSystem (mkNodeConfig name node infraConfig) node.extraModules node.arch
      ) infraConfig.nodes;
      webserverConfigs = lib.mapAttrs (
        name: web: mkSystem (mkWebConfig name web infraConfig) web.extraModules web.arch
      ) infraConfig.webservers;
    in
    nodeConfigs // webserverConfigs;
}
