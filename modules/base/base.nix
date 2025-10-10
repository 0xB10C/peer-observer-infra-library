{
  config,
  lib,
  pkgs,
  ...
}:

let
  CONSTANTS = import ../constants.nix;
in
{
  options = {
    id = lib.mkOption {
      type = lib.types.ints.u8;
      description = "The id of this host. Must be unique among hosts of the same category (node / webserver).";
    };

    name = lib.mkOption {
      type = lib.types.str;
      description = "The name of this host. Will be used as hostname and elsewhere. This name might be displayed publicly";
    };

    arch = lib.mkOption {
      default = "x86_64-linux";
      example = "aarch64-linux";
      type = lib.types.str;
      description = "The architecture of this host";
    };

    description = lib.mkOption {
      default = null;
      type = lib.types.str;
      example = "A peer-observer node / webserver";
      description = "Description of this host. This description might be displayed publicly.";
    };

    wireguard = {
      ip = lib.mkOption {
        type = lib.types.str;
        default = null;
        example = "10.0.23.2";
        description = "The IPv4 address this host should be reachable via wireguard.";
      };
      pubkey = lib.mkOption {
        type = lib.types.str;
        default = null;
        example = "fake/nI5tS3MmxwlWkWr5rtqBhxYfOeqml7Cu8fake=";
        description = "The wireguard public key of this host.";
      };
    };

    b10c-pkgs = lib.mkOption {
      default = null;
      description = "The https://github.com/0xb10c/nix package version to use";
    };

    setup = lib.mkEnableOption "This host is being setup. This means, the host doesn't need secrets yet which makes installation of the system with e.g. nixos-anywhere easier.";

    extraConfig = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra configuration for this host";
    };

    extraModules = lib.mkOption {
      example = [
        ./hosts/node1/hardware-configuration.nix
        ./hosts/node1/disko.nix
      ];
      default = [ ];
      description = "Extra modules that should be included: e.g. hardware-configuration.nix or disko.nix";
    };

  };
  config = lib.mkMerge [
    {
      networking = {
        hostName = config.peer-observer.base.name;
        enableIPv6 = true;
      };

      # The admin user
      users.users."${config.infra.global.admin.username}" = {
        group = "users";
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = config.infra.global.admin.sshPubKeys;
      };

      # allow password-less sudo for admin user
      security.sudo.extraRules = [
        {
          users = [ config.infra.global.admin.username ];
          commands = [
            {
              command = "ALL";
              options = [ "NOPASSWD" ];
            }
          ];
        }
      ];

      # Enable SSH, but disable root login and password authentification.
      services.openssh = {
        enable = true;
        settings.PermitRootLogin = "no";
        settings.PasswordAuthentication = false;
      };

      # utilities installed by default
      environment.systemPackages = with pkgs; [
        wget
        vim
        curl
        htop
        git
        ripgrep
        tmux
        jq
      ];

      nix = {
        gc = {
          # Nix store garbage collection
          automatic = true;
          dates = "daily";
          options = "--delete-older-than 7d";
        };
        settings = {
          auto-optimise-store = true;
          substituters = [ "https://b10c-nixpkgs.cachix.org" ];
          trusted-public-keys = [ "b10c-nixpkgs.cachix.org-1:okaPyE6H0JAJb4H1J8r7mnf7Gst+0c6Djz7ff3QDGkY=" ];
          experimental-features = [
            "nix-command"
            "flakes"
          ];
        };
      };
    }

    (lib.mkIf (!config.peer-observer.base.setup) {

      # If this host isn't "setup = true;", also include the following as base configuration
      # This isn't included in the setup configuration to speed up installation and to
      # ensure we have secrets (e.g. the wireguard private already)

      # A wireguard interface for communication between hosts and nodes.
      age.secrets.wireguard-private-key.file = /${config.infra.agenixSecretsDir}/wireguard-private-key-${config.peer-observer.base.name}.age;
      networking.wireguard.interfaces.${CONSTANTS.WIREGUARD_INTERFACE_NAME} = {
        ips = [ "${config.peer-observer.base.wireguard.ip}/32" ];
        privateKeyFile = config.age.secrets.wireguard-private-key.path;
        # peers are set up in node.nix and web.nix respectivly
      };

      # Prometheus exporters
      # TODO: these listen on all interfaces?
      # The ports for these don't need to be opened on the web servers,
      # so this is done on in node.nix just for the nodes.
      services.prometheus.exporters = {
        wireguard = {
          enable = true;
        };
        node = {
          enable = true;
          enabledCollectors = [
            "logind"
            "systemd"
            "stat"
          ];
          disabledCollectors = [
            "textfile"
            "arp"
            "bcache"
            "bonding"
            "btrfs"
            "edac"
            "hwmon"
            "infiniband"
            "ipvs"
            "mdadm"
            "nfs"
            "nfsd"
            "powersupplyclass"
            "pressure"
            "rapl"
            "schedstat"
            "sockstat"
            "softnet"
            "thermal_zone"
            "timex"
            "udp_queues"
            "uname"
            "xfs"
            "zfs"
            "fibrechannel"
            "tapestats"
          ];
        };
      };
    })
  ];
}
