let
  # when changing any of these keys, use the following to re-key:
  # nix run github:ryantm/agenix -- -r -i test-only-user-key

  # the corresponding test-only private key is in "test-only-user-key"
  test-only-user = "age1erm4yqwgzx0j3j06hcwvnh7x6snlwhwykucmn2vvx27fgphm49eslxtxfj";

  # these are test-only keys generated with ssh-keygen -t ed25519 -N "" -f ssh_node1_host_ed25519_key
  node1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF4Ly3H1v/sdxsJacnCa91r+MxYMIVwMftTZxtm4DSwz";
  node2 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGwGP+ZjSrlkdByOK7K/7/Ela1ErUfLO5waAnsNki9Sw";
  web1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILkN+TyfAtTNo3dSKihqh4vTFz9HAmKES2H85idAJyVE";
  # web2 has "setup = true;", so it doesn't get any secrets yet.
in
{

  ## node secrets
  # node1
  "wireguard-private-key-node1.age".publicKeys = [
    node1
    test-only-user
  ];

  # node2
  "wireguard-private-key-node2.age".publicKeys = [
    node2
    test-only-user
  ];

  ## web secrets
  # web1
  "wireguard-private-key-web1.age".publicKeys = [
    web1
    test-only-user
  ];
  "grafana-admin-password-web1.age".publicKeys = [
    web1
    test-only-user
  ];
}
