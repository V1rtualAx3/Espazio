#!/usr/bin/env bash
# Run once on your Mac: creates the EdDSA key that signs Sparkle updates and prints the command
# storing it as the SPARKLE_ED_PRIVATE_KEY secret. The key never goes into the repository; keep a
# copy safe: losing it means installed copies cannot verify new updates.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR="$HOME/.espazio-signing"
KEY="$DIR/sparkle-private-key.txt"
mkdir -p "$DIR"
chmod 700 "$DIR"
if [[ -e "$KEY" ]]; then
    echo "$KEY already exists: keep using it (a new key would break updates of installed copies)."
    exit 1
fi
PUBLIC="$(swift scripts/sparkle-eddsa.swift generate "$KEY")"
cat <<MSG
Private key: $KEY (keep a backup, never commit it)
Public key:  $PUBLIC (stamped into each release build by CI)

Store it in the repository secrets:
  gh secret set SPARKLE_ED_PRIVATE_KEY --repo V1rtualAx3/Espazio < "$KEY"
MSG
