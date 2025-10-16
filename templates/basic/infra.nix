{
  peer-observer-infra-library,
  disko,
  nixpkgs,
  ...
}:

let
  mkPkgs = system: import nixpkgs { inherit system; };
  customBitcoind =
    { system, overrides }: (peer-observer-infra-library.lib system).mkCustomBitcoind overrides;
in
{
  # This is the definition of a peer-observer infrastructure.
  # The infrastructure consists of one or more nodes and one or more webservers.
  #
  # On nodes, the following services run:
  # - a Bitcoin node (Bitcoin Core by default)
  # - peer-observer extractors and tools
  # - a NATS server for the peer-observer extractors and tools to communicate
  # - a wireguard interface that opens connections to all webservers
  # - ...
  #
  # On webservers, the following services run:
  # - an nginx webserver (requires you to point a (sub)domain to it)
  # - a Prometheus and Grafana instance
  # - the peer-observer frontend tools (websocket, ...)
  # - a fork-observer instance connected to all nodes
  # - an addrman-observer instance connected to all nodes
  # - .. TODO:
  #
  # The configuration options are documented in
  # https://0xb10c.github.io/peer-observer-infra-library/#_infra_agenixsecretsdir
  #
  # However, this is NixOS and you can pretty much override everything.
  # To do this, use the (global, per-hoost) extraConfig arguements below.
  #
  # Keep in mind that you are responsible for securing your servers yourself.
  # You might want to apply additional hardening.

  # NOTE: by default, all hosts defined here are set to `setup = true;`.
  # This enables easier and faster initial set up. Once you provisined the
  # secrets for a node (see README), feel free to set `setup = false;` and
  # redeploy the node.

  # Global configuration options that are applied to all hosts (nodes and webservers).
  global = {
    # FIXME: Configuration of the admin user. You'll need to fill this out to be able to log in via SSH.
    # root login is disabled.
    admin = {
      username = "placeholder";
      sshPubKeys = [
        "ssh-rsa AAAAAAA..."
        "ssh-ed25519 AAAAC..."
      ];
    };
    extraConfig = {
      # When deploying, nixos-rebuild will complain about a missing `system.stateVersion`.
      # You can add it here.
      # See also https://nixos.org/manual/nixos/stable/options.html#opt-system.stateVersion
    };
  };

  # The directory where the secrets (wireguard private keys, Grafana password, ...)
  # are stored (encrypted).
  agenixSecretsDir = ./secrets;

  # This defines nodes. Each node has a unique name, unique id, and a unique
  # wireguard configuration (ip and pubkey). In the following, we define two nodes
  # (node01 and node02).
  nodes = {

    # This node is named `node01`. You can change this name.
    node01 = {
      id = 1;
      wireguard = {
        # feel free to use a different IP range here.
        ip = "10.21.0.1";
        # FIXME:
        # See the section on secrets on how to fill this in
        pubkey = "fakekH7xb/DdO...";
      };
      # FIXME:
      # See NOTE about `setup = true` above.
      setup = true;
      # System architecture of this host. For Intel / AMD, use "x86_64-linux"
      # and for ARM use "aarch64-linux". Other architectures aren't supported
      # at the moment.
      arch = "x86_64-linux";
      # FIXME:
      # Feel free to set this to whatever you like. Note that this might be shown
      # publicly.
      description = ''
        This is a placeholder description for node01. HTML is <b>supported<b>.
      '';
      # Bitcoin node configuration
      bitcoind = {
        # For now, this node uses the default configuration.
        # See node02 for a more advanced configuration.
      };

      extraConfig = {
        # Extra configuration that should be applied to (only) this host goes here.
      };
      extraModules = [
        # FIXME:
        # Extra NixOS modules you want to pass to the system.
        # Usually you need to pass at-least the hardware-configuration.nix file:
        # FIXME: ./hosts/node01/hardware-configuration.nix

        # If you are using disko, you want to pass the disko module and disk
        # configuration too:
        # FIXME: disko.nixosModules.disko
        # FIXME: ./hosts/node01/disko.nix
      ];
    };

    # Same as above: This node is named `node02`. You can change this name.
    node02 = {
      id = 2;
      wireguard = {
        ip = "10.21.0.2";
        pubkey = "fakekH7xb/DdO2...";
      };

      setup = true;
      arch = "x86_64-linux";
      description = ''
        This is a placeholder description for node02. HTML is <b>supported<b>.
      '';

      bitcoind = {

        # Here, we configure a custom bitcoind package to run on this node.
        # You can, for example, change the commit, branch, and repository
        # to run.
        # See https://github.com/0xB10C/peer-observer-infra-library/blob/master/pkgs/bitcoind/default.nix
        package = customBitcoind {
          system = "x86_64-linux";
          overrides = {
            gitURL = "https://github.com/0xb10c/bitcoin.git";
            gitBranch = "this-branch-does-not-exist";
            gitCommit = "faked9953a15d..";
          };
        };

        net = {
          # we enable Tor and I2P connectivity on this node
          # and use a recent ASMap file
          useTor = true;
          useI2P = true;
          useASMap = true;
        };

        # We can also set a banlist to ban certain IP addresses
        # Here, we ban LinkingLion.
        banlistScript = ''
          bitcoin-cli setban 162.218.65.0/24    add 31536000  # LinkingLion
          bitcoin-cli setban 209.222.252.0/24   add 31536000  # LinkingLion
          bitcoin-cli setban 91.198.115.0/24    add 31536000  # LinkingLion
          bitcoin-cli setban 2604:d500:4:1::/64 add 31536000  # LinkingLion
        '';
      };

      extraConfig = {
        # Extra configuration that should be applied to (only) this host goes here.
      };
      extraModules = [
        # FIXME:
        # Extra NixOS modules you want to pass to the system.
        # Usually you need to pass at-least the hardware-configuration.nix file:
        # FIXME: ./hosts/node02/hardware-configuration.nix

        # If you are using disko, you want to pass the disko module and disk
        # configuration too:
        # FIXME: disko.nixosModules.disko
        # FIXME: ./hosts/node02/disko.nix
      ];
    };
  };

  webservers = {

    # This webserver is named `web01`. You can change this name.
    web01 =
      let
        # Note that this domain must be configured to point to the IP address
        # of this host.
        domain = "this-is-a-placeholder.peer.observer";
      in
      {
        id = 1;
        setup = true;
        arch = "x86_64-linux";
        description = "The ${domain} webserver. This is a placeholder.";

        domain = domain;

        wireguard = {
          ip = "10.21.1.1";
          # FIXME:
          pubkey = "fakekH7xb/DdO3...";
        };

        # Username of the Grafana admin user. For the password,
        # see secrets.nix
        # FIXME:
        grafana.admin_user = "placeholder-user-1234";

        # By default, access to the frontend is limited.
        # This means, the IP address of the honeypot nodes shoudn't
        # leak via the frontend. This can be changed (see documentation),
        # but don't do this in a "production" setup. In a production setup,
        # you should put the frontend behind authentification BEFORE turning
        # on full access.
        access_DANGER = "LIMITED_ACCESS";

        # A notice shown on the index page.
        index = {
          # FIXME:
          limitedAccessNotice = ''
            <div class="alert alert-info" role="alert">
              <h2>Placeholder</h2>
              This is a placeholder notice for web01.
            </div>
          '';
          # if you choose "FULL_ACCESS" above, you can also set "fullAccessNotice"
        };

        extraConfig = {
          # For a Let's Encrypt ACME certificate, we would need to accept the terms.
          # When deploying the webserver, NixOS will complain and you can read the
          # terms and set a value here.
          security.acme.acceptTerms = false; # FIXME:
          security.acme.defaults.email = null; # FIXME:
        };

        extraConfig = {
          # Extra configuration that should be applied to (only) this host goes here.
        };
        extraModules = [
          # FIXME:
          # Extra NixOS modules you want to pass to the system.
          # Usually you need to pass at-least the hardware-configuration.nix file:
          # FIXME: ./hosts/web01/hardware-configuration.nix

          # If you are using disko, you want to pass the disko module and disk
          # configuration too:
          # FIXME: disko.nixosModules.disko
          # FIXME: ./hosts/web01/disko.nix
        ];

      };
  };
}
