# shellcheck shell=bash
#
# Deployment and secret-management helpers, loaded into the dev shell via
# shellHook (see flake.nix). Run `infra-help` for the user-facing summary.

usage() {
  echo "Usage: $1 $2"
}

# Print the summary of all helpers
infra-help() {
  cat <<'EOF'
peer-observer infrastructure helpers

  deploy <host> [target]                 Deploy a configuration; target defaults to host
  build-vm <host>                        Build a host VM (requires a compatible Linux builder)
  initial-deploy <host> <target>         Install NixOS with nixos-anywhere (wipes the target disk)
  get-host-key <host> [port]             Print a host SSH public key for secrets/secrets.nix
  gen-wg-key <host>                      Generate and encrypt a WireGuard private key
  gen-grafana-password <host>            Generate and encrypt a Grafana administrator password
  rekey                                  Re-encrypt all secrets after recipient changes
  view-secret <file>                     Decrypt and print a file from secrets/
EOF
}

# Deploy a host configuration. Builds on the target, so this works from
# machines that can't build x86_64-linux locally (e.g. macOS).
deploy() {
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    usage deploy "<host> [target]"
    return 2
  fi

  local host=$1
  local target=${2:-$host}

  echo "deploying $host (target $target)..."
  nixos-rebuild switch \
    --flake ".#$host" \
    --target-host "$target" \
    --build-host "$target" \
    --sudo \
    --show-trace
}

# Build a host VM for local testing. Builds locally: on non-Linux machines
# this requires a compatible Linux builder.
build-vm() {
  if [ "$#" -ne 1 ]; then
    usage build-vm "<host>"
    return 2
  fi

  local host=$1
  echo "building $host..."
  nixos-rebuild build-vm \
    --flake ".#$host" \
    --show-trace
}

# Install NixOS on a fresh server with nixos-anywhere. Wipes the target disk.
initial-deploy() {
  if [ "$#" -ne 2 ]; then
    usage initial-deploy "<host> <target>"
    return 2
  fi

  local host=$1
  local target=$2
  local reply
  echo "WARNING: installing NixOS on $target will wipe its target disk."
  read -r -p "Type 'yes' to continue: " reply
  if [ "$reply" != "yes" ]; then
    echo "Aborted."
    return 1
  fi
  nixos-anywhere \
    --generate-hardware-config nixos-generate-config "./hosts/$host/hardware-configuration.nix" \
    --flake ".#$host" \
    --target-host "$target" \
    --build-on remote
}

# Internal: read USER_KEY (age) and HOST_KEY (SSH) for a host from
# secrets/secrets.nix, failing early on placeholders or missing keys.
recipient_keys() {
  local host=$1
  local secrets_file=secrets/secrets.nix

  case "$host" in
    ""|*[!A-Za-z0-9_-]*)
      echo "ERROR: Host name must contain only letters, numbers, hyphens, and underscores"
      return 1
      ;;
  esac

  if [ ! -f "$secrets_file" ]; then
    echo "ERROR: $secrets_file does not exist"
    return 1
  fi

  USER_KEY=$(sed -nE 's/.*user = "([^"]+)".*/\1/p' "$secrets_file")
  HOST_KEY=$(sed -nE "s/.*$host = \"([^\"]+)\".*/\\1/p" "$secrets_file")

  case "$USER_KEY" in
    ""|*fake*|*FIXME*)
      echo "ERROR: User age key is not configured in $secrets_file"
      echo "Generate one with: age-keygen -o ~/.age/key.txt"
      return 1
      ;;
  esac

  # Base64 key material never contains "..", so two consecutive dots always
  # mean an unedited placeholder from the template's secrets.nix.
  case "$HOST_KEY" in
    ""|*..*)
      echo "ERROR: $host SSH key is missing or a placeholder in $secrets_file"
      echo "Run 'get-host-key <host-ip>' and update $secrets_file first"
      return 1
      ;;
  esac
}

# Internal: encrypt a secret to both the user's age key and the host's SSH
# key. age only accepts SSH recipients from a file (-R), so the host key is
# written to a temp file for the duration of the call.
encrypt_for_host() {
  local host=$1
  local secret=$2
  local output=$3
  local host_key_file
  local status

  recipient_keys "$host" || return

  host_key_file=$(mktemp) || return
  printf '%s\n' "$HOST_KEY" > "$host_key_file"
  printf '%s\n' "$secret" | age -r "$USER_KEY" -R "$host_key_file" -o "$output"
  status=$?
  rm -f "$host_key_file"
  return "$status"
}

# Generate a WireGuard keypair, encrypt the private key for a host, and
# print the public key to copy into infra.nix
gen-wg-key() {
  if [ "$#" -ne 1 ]; then
    usage gen-wg-key "<host>"
    return 2
  fi

  local host=$1
  local private_key
  local public_key
  private_key=$(wg genkey) || return
  public_key=$(printf '%s\n' "$private_key" | wg pubkey) || return

  echo "=== Generating WireGuard key for $host ==="
  encrypt_for_host "$host" "$private_key" "secrets/wireguard-private-key-$host.age" || return
  echo ""
  echo "Private key encrypted to: secrets/wireguard-private-key-$host.age"
  echo ""
  echo "Public key for infra.nix:"
  echo "  pubkey = \"$public_key\";"
}

# Generate a random Grafana administrator password and encrypt it for a host
gen-grafana-password() {
  if [ "$#" -ne 1 ]; then
    usage gen-grafana-password "<host>"
    return 2
  fi

  local host=$1
  local password
  password=$(openssl rand -base64 32) || return

  echo "=== Generating Grafana password for $host ==="
  encrypt_for_host "$host" "$password" "secrets/grafana-admin-password-$host.age" || return
  echo ""
  echo "Password encrypted to: secrets/grafana-admin-password-$host.age"
  echo ""
  echo "Grafana admin password (save this):"
  echo "  $password"
}

# Internal: resolve the identity file for decryption: $AGE_IDENTITY,
# defaulting to ~/.age/key.txt.
age_identity() {
  local id="${AGE_IDENTITY:-$HOME/.age/key.txt}"
  if [ ! -f "$id" ]; then
    echo "ERROR: No age identity at $id" >&2
    echo "Create one with 'age-keygen -o ~/.age/key.txt', or point AGE_IDENTITY at your key (an SSH private key also works if its public key is a recipient in secrets/secrets.nix)" >&2
    return 1
  fi
  printf '%s\n' "$id"
}

# Re-encrypt all secrets after changing recipients in secrets/secrets.nix
rekey() {
  if [ "$#" -ne 0 ]; then
    usage rekey ""
    return 2
  fi

  local id
  id=$(age_identity) || return
  (cd secrets && agenix -r -i "$id")
}

# Decrypt and print a secret (for debugging)
view-secret() {
  if [ "$#" -ne 1 ]; then
    usage view-secret "<file>"
    return 2
  fi

  local id
  id=$(age_identity) || return
  age -d -i "$id" "secrets/$1"
}

# Print a host's SSH public key for secrets/secrets.nix. Takes a raw
# IP/hostname (ssh-keyscan ignores ~/.ssh/config) and an optional port.
get-host-key() {
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    usage get-host-key "<host> [port]"
    return 2
  fi

  local host=$1
  local port=${2:-22}

  # age only accepts ed25519 and RSA SSH keys; the banner comments land on
  # stdout on newer OpenSSH, so filter them explicitly.
  local keys
  keys=$(ssh-keyscan -t ed25519,rsa -p "$port" "$host" 2>/dev/null | grep -v '^#')
  if [ -z "$keys" ]; then
    echo "ERROR: no SSH key received from $host on port $port" >&2
    return 1
  fi

  echo "=== SSH public key for $host (port $port) ==="
  printf '%s\n' "$keys"
  echo ""
  echo "Add the key part (without the host prefix) to secrets/secrets.nix."
}

# Export the helpers so they are available in subshells (e.g. CI's
# `nix develop --command bash -c ...`).
if [ -n "$BASH_VERSION" ]; then
  export -f usage infra-help deploy build-vm initial-deploy recipient_keys encrypt_for_host \
    age_identity gen-wg-key gen-grafana-password rekey view-secret get-host-key
fi

echo "peer-observer infrastructure helpers are available. Run 'infra-help' for usage."
