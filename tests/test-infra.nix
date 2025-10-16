{ system, peer-observer-infra-library, ... }:

let
  testOnlySSHHostKeyExtraConfig = name: {
    # don't use this in production! This is only for integration tests.
    system.activationScripts.agenixInstall.deps = [ "installTestOnlySSHKeys" ];
    system.activationScripts.installTestOnlySSHKeys.text = ''
      echo "[installTestOnlySSHKeys] installing test-only SSH host keys..."
      mkdir -p /etc/ssh
      echo "[installTestOnlySSHKeys] installing test-only SSH host keys: pub key"
      cp ${./test-secrets/ssh-host-keys/ssh_${name}_host_ed25519_key.pub} /etc/ssh/ssh_host_ed25519_key.pub
      chmod 600 /etc/ssh/ssh_host_ed25519_key.pub
      echo "[installTestOnlySSHKeys] installing test-only SSH host keys: sec key"
      cp ${./test-secrets/ssh-host-keys/ssh_${name}_host_ed25519_key} /etc/ssh/ssh_host_ed25519_key
      chmod 400 /etc/ssh/ssh_host_ed25519_key
      echo "[installTestOnlySSHKeys] installing test-only SSH host keys: done"
    '';
  };
in
{

  global = {
    admin = {
      username = "admin";
      sshPubKeys = [ "dummy" ];
    };
    extraConfig = { };
  };

  agenixSecretsDir = ./test-secrets;

  nodes = {
    node1 = {
      id = 1;
      setup = false;
      arch = system;
      description = ''
        This is the test-node1.
        An unique value to look for in the integration tests is: 0fc83a94-3eee-44c2-87b4-441638dd75ac";
      '';

      wireguard = {
        ip = "10.0.0.1";
        pubkey = "n1/nE6I5tS3MmxwlWkWr5rtqBhxYfOeqml7Cu8XX1gg=";
      };

      bitcoind = {
        chain = "regtest";
        # for good measure, use a custom bitcoind binary here.
        package = peer-observer-infra-library.mkCustomBitcoind { sanitizersAddressUndefined = true; };
        net = {
          useTor = true;
          useI2P = true;
          useASMap = true;
          # CJDNS package is broken?
          useCJDNS = false;
        };
        detailedLogging = {
          enable = true;
          logsToKeep = 2;
        };
        banlistScript = ''
          bitcoin-cli setban 162.218.65.0/24    add 31536000  # LinkingLion
          bitcoin-cli setban 209.222.252.0/24   add 31536000  # LinkingLion
          bitcoin-cli setban 91.198.115.0/24    add 31536000  # LinkingLion
          bitcoin-cli setban 2604:d500:4:1::/64 add 31536000  # LinkingLion
        '';
      };

      extraConfig = (testOnlySSHHostKeyExtraConfig "node1") // {
        # extra memory needed for peer-observer extractor huge-msg table
        virtualisation.memorySize = 3072;
      };
      extraModules = [ ];
    };
    node2 = {
      id = 2;
      setup = false;
      arch = system;
      description = "This is the test-node2. An unique value to look for in the integration tests is: 09b318bd-fb84-48b3-9984-5f60ebddf864";
      wireguard = {
        ip = "10.0.0.2";
        pubkey = "n2/QUr6X+/6Ii+ExwBXEPAnJLjnrZI5E/npMLFztkGI=";
      };
      bitcoind.chain = "regtest";
      extraConfig = (testOnlySSHHostKeyExtraConfig "node2") // {
        # extra memory needed for peer-observer extractor huge-msg table
        virtualisation.memorySize = 3072;
      };
      extraModules = [ ];
    };
  };
  webservers = {
    web1 = {
      id = 1;
      arch = system;
      domain = "web1";
      wireguard = {
        ip = "10.0.1.1";
        pubkey = "w1/RDa5gEU5nYWdb1+B18lOWaEg4dByv9b+XLdUuHHo=";
      };
      setup = false;
      grafana.admin_user = "b10c";
      fork-observer = {
        networkName = "regtest";
        minForkHeight = 0;
      };
      index = {
        fullAccessNotice = "fullAccessNotice";
        limitedAccessNotice = "limitedAccessNotice";
      };
      extraModules = [ ];
      extraConfig = {
        # we can't get an ACME cert in the test: disable TLS on nginx
        services.nginx.virtualHosts."web1".enableACME = false;
        services.nginx.virtualHosts."web1".forceSSL = false;
      }
      // testOnlySSHHostKeyExtraConfig "web1";
    };
    web2 = {
      id = 2;
      arch = system;
      domain = "web2";
      wireguard = {
        ip = "10.0.1.2";
        pubkey = "placeholder-this-web-is-setup=true";
      };
      setup = true;
      grafana.admin_user = "b10c";
      extraConfig = { };
      extraModules = [ ];
    };
  };
}
