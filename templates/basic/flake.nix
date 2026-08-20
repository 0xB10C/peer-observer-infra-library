{
  description = "A NixOS flake defining peer-observer infrastructure definition.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    peer-observer-infra-library = {
      url = "github:peer-observer/infra-library";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
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
      peer-observer-infra-library,
      disko,
      agenix,
    }:
    let
      infra = import ./infra.nix { inherit nixpkgs peer-observer-infra-library disko; };

      # Systems we have a devShell for
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
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
      formatter = forAllSystems ({ system, ... }: nixpkgs.legacyPackages.${system}.nixfmt-tree);

      nixosConfigurations = (peer-observer-infra-library.lib "x86_64-linux").mkConfigurations infra;

      # A shell with all deployment and secret-management tools.
      # Enter with `nix develop`, then run `infra-help` for available helpers.
      devShells = forAllSystems (
        { pkgs, system, ... }:
        {
          default = pkgs.mkShell {
            buildInputs = [
              pkgs.nixos-anywhere
              pkgs.nixos-rebuild-ng
              pkgs.wireguard-tools
              pkgs.age
              pkgs.openssl
              pkgs.openssh
              agenix.packages.${system}.agenix
            ];

            shellHook = builtins.readFile ./shell-hook.sh;
          };
        }
      );
    };
}
