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

  # only nodes that have getpeerinfo snapshots enabled are listed.
  snapshotNodes = lib.filterAttrs (
    name: host: host.bitcoind.peerinfoSnapshots.enable
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
        <a href="/peerinfo-snapshots/${name}/">node ${name}</a>${
          lib.optionalString (flags != "") " (${flags})"
        }
        (last ${toString host.bitcoind.peerinfoSnapshots.daysToKeep} days)
      </li>
    '';

  mkOverviewNodeList = hosts: ''
    <ul>
      ${builtins.concatStringsSep "  " (lib.mapAttrsToList mkOverviewNodeEntry hosts)}
    </ul>
  '';

in
stdenv.mkDerivation {
  name = "peerinfo-snapshots-page";

  phases = [ "installPhase" ];

  installPhase = ''
        mkdir -p $out
        cat > $out/index.html << EOF
        ${
          (mkHTMLPage "peer-observer getpeerinfo snapshots" (''
            <h1>peer-observer getpeerinfo snapshots</h1>
            <span>
              Snapshots of each node's <code>getpeerinfo</code> RPC output, taken
              every six hours and compressed with zstd. While the
              <a href="/addrman-snapshots/">addrman snapshots</a> show which peers
              a node <em>knows</em>, these show which peers it was actually
              <em>connected to</em> at that point in time, including connection
              direction, services, subversion, and traffic counters. Provided as is.
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
