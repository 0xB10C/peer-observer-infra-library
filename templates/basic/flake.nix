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
  };

  outputs =
    {
      self,
      nixpkgs,
      peer-observer-infra-library,
      disko,
    }:
    let
      infra = import ./infra.nix { inherit nixpkgs peer-observer-infra-library disko; };

      # Systems we have a devShell for
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
      formatter = forAllSystems ({ system, ... }: nixpkgs.legacyPackages.${system}.nixfmt-tree);

      nixosConfigurations = (peer-observer-infra-library.lib "x86_64-linux").mkConfigurations infra;

      # a shell with all needed tools
      # enter with `nix develop`
      devShells = forAllSystems (
        { pkgs, system, ... }:
        {
          default = pkgs.mkShell {
            buildInputs = [
              pkgs.nixos-anywhere
              pkgs.nixos-rebuild
              pkgs.just
              pkgs.wireguard-tools
              pkgs.age
              pkgs.openssl
              peer-observer-infra-library.packages.${system}.agenix
            ];

            shellHook = ''
              # Shell functions (alternative to justfile recipes)
              deploy() {
                local host=$1
                echo "deploying $host..."
                nixos-rebuild switch \
                --flake .#$host \
                --target-host $host \
                --build-host $host \
                --sudo \
                --show-trace
              }

              build-vm() {
                local host=$1
                echo "building $host..."
                nixos-rebuild build-vm \
                --flake .#$host \
                --show-trace
              }
              export -f deploy
              export -f build-vm

              echo ""
              echo "Run 'just' to see available commands, or use these shell functions:"
              echo "  deploy <host>   - Deploy configuration to host"
              echo "  build-vm <host> - Build VM for local testing"
              echo ""
            '';
          };
        }
      );
    };
}
