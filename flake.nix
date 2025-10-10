{
  description = "A NixOS flake providing library functionality for running peer-observer instances.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    b10c-nix = {
      url = "github:0xb10c/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      agenix,
      b10c-nix,
      ...
    }:
    let
      # Systems the peer-observer infra is supported on.
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forSystem =
        system: f:
        f rec {
          inherit system;
          pkgs = import nixpkgs { inherit system; };
        };

      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: (forSystem system f));
    in
    {

      lib = (
        system:
        (import ./lib.nix {
          inherit
            nixpkgs
            system
            agenix
            b10c-nix
            ;
        })
      );

      packages = forAllSystems (
        { pkgs, system, ... }:
        {
          # re-export of the agenix package to be used by consumers of this flake.
          agenix = agenix.packages.x86_64-linux.agenix;

          # a bitcoind package to be used for peer-observer (and nothing else!)
          # We don't pass any overrides to mkCustomBitcoind, so it's the default one.
          bitcoind = (self.lib system).mkCustomBitcoind { };

          # docs for the modules/infra.nix module
          docs = pkgs.callPackage ./pkgs/docs/default.nix {
            github_url = "https://github.com/0xB10C/peer-observer-infra-library/tree/master/";
          };
        }
      );

      formatter = forAllSystems ({ system, ... }: nixpkgs.legacyPackages.${system}.nixfmt-tree);

      checks = forAllSystems (
        { pkgs, system, ... }:
        {
          test = import ./tests/test.nix {
            inherit nixpkgs system;
            peer-observer-infra-library = self.lib system;
          };
        }
      );
    };
}
