let
  # when changing any of these keys, use the following to re-key:
  # agenix -r -i <yourkey>.agekey

  # The public key part of an age key.
  # Generated with "age-keygen -o <yourkey>.agekey"
  # This key allows you to decrypt the secrets
  # DON'T ADD OR COMMIT AN UNENCRYPTED SECRET KEY TO GIT
  # Rather, store it in a password manager.
  # FIXME:
  user = "age1dcfake..";

  # get these with "ssh-keyscan <ip>" once you installed NixOS on the hosts
  node01 = "ssh-ed25519 AAAAC3N..";
  node02 = "ssh-ed25519 AAAAC3N..";
  web01 = "ssh-ed25519 AAAAC3Nz..";
in
{

  # NOTE: If you rename your hosts, you need to change the names below too.

  # For each host you'll need to generate and encrypt secrets.
  # Once you have generated a secret, open the file with e.g.
  # `agenix -e wireguard-private-key-node01.age`
  # and insert, save, and close the file.
  # See the secrest section in https://github.com/0xB10C/peer-observer-infra-library
  # for instructions on how to generate the secrests.

  ## nodes

  # node01
  "wireguard-private-key-node01.age".publicKeys = [
    node01
    user
  ];

  # node02
  "wireguard-private-key-node02.age".publicKeys = [
    node02
    user
  ];

  ## webservers

  # web01
  "wireguard-private-key-web01.age".publicKeys = [
    web01
    user
  ];
  "grafana-admin-password-web01.age".publicKeys = [
    web01
    user
  ];
}
