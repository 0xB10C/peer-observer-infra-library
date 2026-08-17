{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  CONSTANTS = import ../constants.nix;
  # Directory bitcoind writes debug.log into: the chain's datadir subdir ("" for
  # mainnet, "regtest/" for regtest, ...). The in-progress ("today") per-day
  # archive is staged here too, right next to debug.log, so it's easy to find
  # while it fills up. Ends in a "/".
  logDir = "${config.services.bitcoind.mainnet.dataDir}/${
    CONSTANTS.BITCOIND_DATADIR_SUBDIR_BY_CHAIN."${config.peer-observer.node.bitcoind.chain}"
  }";
in
{
  config = lib.mkIf (config.peer-observer.node.enable && !config.peer-observer.base.setup) {

    systemd.tmpfiles.rules = optionals config.peer-observer.node.bitcoind.detailedLogging.enable [
      "d ${CONSTANTS.DEBUG_LOGS_DIR} 775 ${config.services.bitcoind.mainnet.user} ${config.services.bitcoind.mainnet.group} -"
    ];

    # Rotate bitcoind's debug.log hourly and accumulate each compressed hourly
    # chunk in a per-day gzip archive kept next to debug.log in the bitcoind data
    # dir (so the in-progress "today" log is easy to find there). A day's file is
    # only published to DEBUG_LOGS_DIR (which is nginx-served and rcloned) once it
    # is finalized -- i.e. once we've rolled into the next day and no further
    # chunks can be appended -- so a half-finished day is never exposed or
    # rcloned away.
    #
    # Unlike logrotate's copytruncate (which briefly keeps two copies of the log
    # on disk and can lose lines written during the copy), we rename the live log
    # aside with an atomic same-filesystem move and have bitcoind reopen a fresh
    # debug.log via SIGHUP, so the log is never duplicated on disk.
    systemd.services."bitcoind-debug-log-rotate" =
      mkIf config.peer-observer.node.bitcoind.detailedLogging.enable
        {
          after = [ "bitcoind-mainnet.service" ];
          script = ''
            set -euo pipefail
            NODE="${config.peer-observer.base.name}"

            # Date the chunk by its content, not the wall clock at rotation time.
            # The hourly run at 00:00 rotates the 23:00-00:00 chunk, whose lines
            # all belong to the *previous* day; naively using `date` here would
            # misfile them under the new day. Subtracting an hour (as the old
            # logrotate `datehourago` did) keeps a boundary chunk with the day
            # its contents were written.
            DATE=$(date -d '1 hour ago' +%Y%m%d)
            CURRENT="debug.log-$DATE-$NODE.gz"
            # In-progress day, staged next to debug.log in the bitcoind data dir.
            STAGED="${logDir}$CURRENT"

            # Finalize completed days first: any staged day-file other than the
            # one we're currently accumulating ($CURRENT) has received all of its
            # hourly chunks, so publish it to the served/rcloned dir. The data dir
            # and DEBUG_LOGS_DIR are usually different filesystems, so this `mv` is
            # a copy+delete that briefly exposes the file growing under its final
            # name -- acceptable, since rclone/nginx are very unlikely to read it
            # during that sub-second window. Runs even when there's nothing to
            # rotate (e.g. bitcoind down), so a completed day isn't held back by a
            # later outage.
            for f in ${logDir}debug.log-*-"$NODE".gz; do
              [ -e "$f" ] || continue
              [ "$(basename "$f")" = "$CURRENT" ] && continue
              mv "$f" ${CONSTANTS.DEBUG_LOGS_DIR}/
            done

            # Retention: keep detailedLogging.logsToKeep days of published archives.
            find ${CONSTANTS.DEBUG_LOGS_DIR} -name "debug.log-*.gz" \
              -mtime +${toString config.peer-observer.node.bitcoind.detailedLogging.logsToKeep} \
              -delete

            LOG="${logDir}debug.log"
            # Nothing to rotate if bitcoind isn't running yet or hasn't created
            # the log; finalization above has already run, so just stop here.
            [ -f "$LOG" ] || exit 0
            TMP="$LOG.rotating"

            # Move the live log aside (atomic rename on the same filesystem, so no
            # second copy is ever on disk), then ask bitcoind to reopen a fresh
            # debug.log via SIGHUP.
            mv "$LOG" "$TMP"
            kill -HUP "$(cat ${config.services.bitcoind.mainnet.pidFile})"

            # bitcoind reopens the log on its next write; give it a moment so it
            # has stopped writing to the rotated-away inode before we compress it.
            sleep 2

            # Compress this hour's chunk and append it to the day's staged
            # archive. gzip members concatenate into a single valid stream, so a
            # day's file accumulates up to 24 chunks and still decompresses with
            # zcat/gunzip.
            ${pkgs.gzip}/bin/gzip -c "$TMP" >> "$STAGED"
            rm -f "$TMP"
          '';
          serviceConfig = {
            Type = "oneshot";
            User = config.services.bitcoind.mainnet.user;
            Group = config.services.bitcoind.mainnet.group;
          };
        };

    systemd.timers."bitcoind-debug-log-rotate" =
      mkIf config.peer-observer.node.bitcoind.detailedLogging.enable
        {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "hourly";
            Persistent = true;
          };
        };
  };
}
