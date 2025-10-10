{
  stdenv,
  config,
  lib,
  limited ? true,
  ...
}:

let

  CONSTANTS = import ../constants.nix;

  mkHTMLPage = title: body: ''
      <!doctype html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>${title}</title>
          <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet" integrity="sha384-QWTKZyjpPEjISv5WaRU9OFeRpok6YctnYmDr5pNlyT2bRjXh0JMhjY6hW+ALEwIH" crossorigin="anonymous">
        </head>
        <body>
          <nav class="navbar navbar-expand-lg ${
            if limited then "bg-light" else "bg-warning"
          } border-bottom border-body mb-3">
            <div class="container">
              <a class="navbar-brand" href="#">${title} ${lib.optionalString limited "(limited)"}</a>
              <button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#navbarNavAltMarkup" aria-controls="navbarNavAltMarkup" aria-expanded="false" aria-label="Toggle navigation">
                <span class="navbar-toggler-icon"></span>
              </button>
              <div class="collapse navbar-collapse" id="navbarNavAltMarkup">
                <div class="navbar-nav">
                  <a class="nav-link" href="/forks/">forks</a>
                  ${
                    if (!limited) then
                      ''
                        <a class="nav-link" href="/monitoring/d/home/home">monitoring</a>
                        <a class="nav-link" href="/monitoring/playlists">playlist</a>
                        <a class="nav-link" href="/debug-logs/">debug logs</a>
                        <a class="nav-link" href="/websocket/">websocket</a>
                      ''
                    else
                      ""
                  }
                </div>
              </div>
            </div>
          </nav>
          <div class="container">
            ${body}
          </div>
          <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.min.js" integrity="sha384-0pUGZvbkm6XF6gxjEnlmuGrJXVbNuzT9qBBavbLwCsOGabYfZo0T0to5eqruptLy" crossorigin="anonymous"></script>
        </body>
    </html>
  '';

  mkBitcoinCoreVersion = host: ''
    <a class="text-decoration-none"
      href="${
        builtins.replaceStrings
          [ ".git" ]
          [
            ""
          ]
          host.bitcoind.package.gitURL
      }/tree/${host.bitcoind.package.gitBranch}"
    >${host.bitcoind.package.gitBranch}</a>@<a class="text-decoration-none"
      href="${
        builtins.replaceStrings
          [ ".git" ]
          [
            ""
          ]
          host.bitcoind.package.gitURL
      }/commit/${host.bitcoind.package.gitCommit}"
    >${builtins.substring 0 8 host.bitcoind.package.gitCommit}</a>
  '';

  mkBadgeClass = condition: if condition then "success" else "secondary text-decoration-line-through";

  mkOverviewNodeEntry =
    name: host:
    ''
      <div class="col col-12">
        <div class="card m-2">
          <div class="card-body">
            <h3 class="card-title" id="node-${name}">${name}</h3>
            <p>
              ${host.description}
              <br>
              Bitcoin node version
              <span class="font-monospace text-decoration-none">
                ${if limited then "[redacted]" else mkBitcoinCoreVersion host}
              </span>
            </p>

            <p>
              <span class="badge text-bg-${
                if (host.arch == "x86_64-linux") then "light" else "warning"
              }">${host.arch}</span>
              <span class="badge text-bg-${
                if (host.bitcoind.prune == 0) then "primary" else "info"
              }">prune=${toString host.bitcoind.prune}</span>
              <span class="badge text-bg-${mkBadgeClass host.bitcoind.detailedLogging.enable}">detailed debug.log</span>
              ${lib.optionalString (host.bitcoind.net.useTor) ''
                <span class="badge text-bg-success">onion</span>
              ''}
              ${lib.optionalString (host.bitcoind.net.useI2P) ''
                <span class="badge text-bg-success">i2p</span>
              ''}
              ${lib.optionalString (host.bitcoind.net.useCJDNS) ''
                <span class="badge text-bg-success">cjdns</span>
              ''}
              ${lib.optionalString (host.bitcoind.net.useASMap) ''
                <span class="badge text-bg-success">ASMap</span>
              ''}
              ${lib.optionalString (host.bitcoind.package.sanitizersAddressUndefined) ''
                <span class="badge text-bg-success">ASan & UBSan</span>
              ''}
              ${lib.optionalString (host.bitcoind.package.sanitizersThread) ''
                <span class="badge text-bg-success">TSan</span>
              ''}
              ${lib.optionalString (host.bitcoind.banlistScript != null) ''
                <span class="badge text-bg-success">banlist</span>
              ''}
              ${lib.optionalString host.peer-observer.addrLookup ''
                <span class="badge text-bg-success">addr connectivity check</span>
              ''}
            </p>
    ''
    + (
      if (host.bitcoind.banlistScript != null) then
        ''
          <h5>Banlist Script</h5>
          <div class="card mb-3">
            <div class="card-body">
              <pre class="mb-0">${toString host.bitcoind.banlistScript}</pre>
            </div>
          </div>
        ''
      else
        ""
    )
    + ""
    + (
      if (host.bitcoind.extraConfig != "") then
        ''
          <h5>Extra Configuration</h5>
          <div class="card mb-3">
            <div class="card-body">
              <pre class="mb-0">${toString host.bitcoind.extraConfig}</pre>
            </div>
          </div>
        ''
      else
        ""
    )
    + ''
            <div>
              <a href="${
                if limited then "nice try" else "/addrman/?url=${name}"
              }" class="btn btn-outline-secondary ${lib.optionalString limited "disabled"}">addrman</a>
              <a href="${
                if limited then "nice try" else "/debug-logs/${name}/"
              }" class="btn btn-outline-secondary ${lib.optionalString limited "disabled"}">debug.log</a>
            </div>
          </div>
        </div>
      </div>
    '';

  mkOverviewNodeList = hosts: ''
    <div class="row">
      ${builtins.concatStringsSep "  " (
        lib.mapAttrsToList (name: host: mkOverviewNodeEntry name host) hosts
      )}
    </div>'';

in
stdenv.mkDerivation rec {
  name = "index-page";

  phases = [ "installPhase" ];

  installPhase = ''
        mkdir -p $out
        cat > $out/index.html << EOF
        ${
          (mkHTMLPage "peer-observer" (
            # include a user configurable notice on the top of the page
            config.peer-observer.web.index.notice
            + ''
              <h2>Nodes</h2>
            ''
            + (mkOverviewNodeList config.infra.nodes)
          ))
        }
    EOF
  '';
}
