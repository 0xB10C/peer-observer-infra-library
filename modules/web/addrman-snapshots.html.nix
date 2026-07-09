{
  config,
  stdenv,
  lib,
  ...
}:

let
  mkHTMLPage = title: body: ''
      <!doctype html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>${title}</title>
        </head>
        <body>
          <div class="container">
            ${body}
          </div>
        </body>
    </html>
  '';

  # only nodes that have at least one kind of addrman snapshot enabled are listed.
  snapshotNodes = lib.filterAttrs (
    name: host: host.bitcoind.addrmanSnapshots.enable || host.bitcoind.peersDatSnapshots.enable
  ) config.infra.nodes;

  # a comma separated list of the node's enabled privacy networks, e.g. "tor, i2p".
  mkNetFlags =
    host:
    lib.concatStringsSep ", " (
      lib.optional host.bitcoind.net.useTor "tor"
      ++ lib.optional host.bitcoind.net.useI2P "i2p"
      ++ lib.optional host.bitcoind.net.useCJDNS "cjdns"
    );

  mkOverviewNodeEntry =
    name: host:
    let
      flags = mkNetFlags host;
    in
    ''
      <li>
        node ${name}${lib.optionalString (flags != "") " (${flags})"}
        <ul>
          ${lib.optionalString host.bitcoind.addrmanSnapshots.enable ''
            <li>
              <a href="/addrman-snapshots/${name}/"><code>getrawaddrman</code> snapshots</a>
              (last ${toString host.bitcoind.addrmanSnapshots.snapshotsToKeep} days)
            </li>
          ''}
          ${lib.optionalString host.bitcoind.peersDatSnapshots.enable ''
            <li>
              <a href="/peers-dat-snapshots/${name}/"><code>peers.dat</code> snapshots</a>
              (last ${toString host.bitcoind.peersDatSnapshots.snapshotsToKeep} weeks)
            </li>
          ''}
        </ul>
      </li>
    '';

  mkOverviewNodeList = hosts: ''
    <ul>
      ${builtins.concatStringsSep "  " (lib.mapAttrsToList mkOverviewNodeEntry hosts)}
    </ul>
  '';

in
stdenv.mkDerivation {
  name = "addrman-snapshots-page";

  phases = [ "installPhase" ];

  installPhase = ''
        mkdir -p $out
        cat > $out/index.html << EOF
        ${
          (mkHTMLPage "peer-observer addrman snapshots" (''
            <h1>peer-observer addrman snapshots</h1>
            <span>
              Snapshots of each node's address manager are kept: daily
              <code>getrawaddrman</code> JSON snapshots and weekly raw
              <code>peers.dat</code> files. The <code>peers.dat</code> files are
              easier to work with inside Bitcoin Core for e.g. simulations.
              Both are compressed with zstd and provided as is.
              <br>
              Feel free to use the snapshots but please make sure to not leak the node IP addresses to the public.
            </span>
            <h2>snapshots</h2>
            ${(mkOverviewNodeList snapshotNodes)}
          ''))
        }
    EOF
  '';
}
