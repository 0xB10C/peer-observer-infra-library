{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  webOptions = (import ./web/web.nix { inherit config lib pkgs; }).options;
  nodeOptions =
    (import ./node/node.nix {
      inherit
        config
        lib
        pkgs
        ;
    }).options;
in
{
  options = {
    infra = {

      global = lib.mkOption {
        default = { };
        description = ''
          Global settings applied to every host in the deployment
          (both nodes and webservers).
        '';
        type = lib.types.submodule {
          options = {
            admin = lib.mkOption {
              default = { };
              description = ''
                Admin user created on all hosts for SSH access.
              '';
              type = lib.types.submodule {
                options = {
                  username = lib.mkOption {
                    type = lib.types.str;
                    default = null;
                    example = "myuser";
                    description = ''
                      Admin username. Cannot be "root" - root login
                      is disabled.
                    '';
                  };
                  sshPubKeys = lib.mkOption {
                    type = with lib.types; listOf str;
                    default = [ ];
                    description = ''
                      SSH public keys added to the admin user's
                      authorized_keys on all hosts. Must not be
                      empty - evaluation will throw if no keys are
                      provided, to prevent locking yourself out.
                    '';
                    example = [
                      "ssh-ed25519 AAAA..."
                    ];
                    apply =
                      val:
                      if val == [ ] then
                        throw "The option `global.admin.sshPubKeys` must not be empty. Otherwise, you won't be able to SSH into your hosts."
                      else
                        val;
                  };
                };
              };
            };

            extraConfig = lib.mkOption {
              type = lib.types.attrs;
              default = { };
              example = {
                system.stateVersion = "25.11";
              };
              description = ''
                NixOS configuration attribute set merged into every
                host (both nodes and webservers). Use for settings
                that should be uniform across all machines, such as
                system.stateVersion or locale settings.
              '';
            };
          };
        };
      };

      agenixSecretsDir = lib.mkOption {
        default = null;
        type = lib.types.path;
        example = ./secrets;
        description = ''
          Path to the directory containing .age-encrypted secret
          files. All hosts read WireGuard keys and Grafana
          passwords from this path.
        '';
      };

      webservers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule { options = webOptions; });
        default = { };
        description = ''
          Named webservers that aggregate data from nodes into a
          single web interface (Grafana, Prometheus, fork-observer,
          addrman-observer). Each key becomes the host name.
        '';
      };

      nodes = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule { options = nodeOptions; });
        default = { };
        description = ''
          Named peer-observer nodes. Each runs a Bitcoin Core
          instance, extractors, tools, and a NATS message broker.
          Each key becomes the host name.
        '';
      };
    };
  };

  config =
    let
      checkUniqueBy =
        keyFn: attrset:
        let
          values = builtins.attrValues attrset;
          keys = map keyFn values;
          uniqueKeys = builtins.attrNames (
            builtins.listToAttrs (
              map (k: {
                name = toString k;
                value = true;
              }) keys
            )
          );
        in
        builtins.length keys == builtins.length uniqueKeys;
    in
    {
      assertions = [
        {
          assertion = checkUniqueBy (x: x.id) config.infra.nodes;
          message = "The `id`'s of the `infra.nodes` are not unique.";
        }
        {
          assertion = checkUniqueBy (x: x.id) config.infra.webservers;
          message = "The `id`'s of the `infra.webservers` are not unique.";
        }
        {
          assertion = checkUniqueBy (x: x.wireguard.ip) (config.infra.nodes // config.infra.webservers);
          message = "The `infra.<nodes/webservers>.<name>.wireguard.ip`'s are not unique.";
        }
        {
          assertion = checkUniqueBy (x: x.wireguard.pubkey) (config.infra.nodes // config.infra.webservers);
          message = "The `infra.<nodes/webservers>.<name>.wireguard.pubkey`'s are not unique.";
        }
        {
          assertion = config.infra.global.admin.username != "root";
          message = "The `infra.global.admin.username` CAN NOT be 'root' as root login is disabled.";
        }
      ];
    };
}
