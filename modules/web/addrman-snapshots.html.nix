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

  # only nodes that have addrman snapshots enabled are listed.
  snapshotNodes = lib.filterAttrs (
    name: host: host.bitcoind.addrmanSnapshots.enable
  ) config.infra.nodes;

  mkOverviewNodeEntry = name: host: ''
    <li>
      node <a href="/addrman-snapshots/${name}/">${name}</a>
      (last ${toString host.bitcoind.addrmanSnapshots.snapshotsToKeep} days${lib.optionalString host.bitcoind.net.useTor "; tor enabled"}${lib.optionalString host.bitcoind.net.useI2P "; i2p enabled"}${lib.optionalString host.bitcoind.net.useCJDNS "; cjdns enabled"})
    </li>
  '';

  mkOverviewNodeList = hosts: ''
    <div class="row">
      ${builtins.concatStringsSep "  " (lib.mapAttrsToList mkOverviewNodeEntry hosts)}
    </div>
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
              Daily <code>getrawaddrman</code> snapshots of the node's address manager are kept.
              They are compressed with zstd (<code>.json.zst</code>) and provided as is.
              <br>
              Feel free to use the snapshots but please make sure to not leak the node IP addresses to the public.
            </span>
            <h2>snapshots</h2>
            <ul>
              ${(mkOverviewNodeList snapshotNodes)}
            </ul>
          ''))
        }
    EOF
  '';
}
