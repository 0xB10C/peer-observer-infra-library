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

      global = {
        admin = {
          username = lib.mkOption {
            type = lib.types.str;
            default = null;
            description = "The username of the admin user. Used for logging in via SSH.";
          };
          sshPubKeys = lib.mkOption {
            type = with lib.types; listOf str;
            default = [ ];
            description = "SSH public keys that will be able to login (i.e. authorized_keys).";
            example = [
              "ssh-rsa AAAAB3Nza.."
            ];
            apply =
              val:
              if val == [ ] then
                throw "The option `global.admin.sshPubKey` must not be empty. Otherwise, you won't be able to SSH into your hosts."
              else
                val;
          };
        };

        extraConfig = lib.mkOption {
          type = lib.types.attrs;
          default = { };
          example = {
            system.stateVersion = "25.11";
          };
          description = "Configuration applied to all node and webserver systems.";
        };
      };

      agenixSecretsDir = lib.mkOption {
        default = null;
        type = lib.types.path;
        example = ./secrets;
        description = "Path to the agenix secrets directory.";
      };

      webservers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule { options = webOptions; });
        default = { };
        description = "A set of named webservers.";
      };

      nodes = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule { options = nodeOptions; });
        default = { };
        description = "A set of named nodes.";
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
