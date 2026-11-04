#!/bin/bash
# Server side: unpack pynq_dfx_upload.tar into the workspace and verify the
# accelerator sources against the frozen SE manifest (se_sources.sha256).
set -euo pipefail
ws=${WS:-$(pwd)}   # workspace: run from <ws> or set WS
cd "$ws"
test -f pynq_dfx_upload.tar
stage=$(mktemp -d "$ws/.stage.XXXX")
tar -xf pynq_dfx_upload.tar -C "$stage"
mkdir -p src
for d in profile_rtl pl_rom_se_candidate; do
    if [ -d "src/$d" ]; then mv "src/$d" "$stage/old_$d"; fi
    mv "$stage/$d" "src/$d"
done
if [ -d pynq_dfx ]; then mv pynq_dfx "$stage/old_pynq_dfx"; fi
mv "$stage/pynq_dfx" pynq_dfx
[ -d src/ip_repo ] || { echo "src/ip_repo missing (copy build_inputs/src/ip_repo)"; exit 1; }
sed -i 's/\r$//' pynq_dfx/scripts/*.sh pynq_dfx/scripts/*.tcl
chmod +x pynq_dfx/scripts/*.sh
sha256sum -c --quiet se_sources.sha256 && echo HASH_OK
mv pynq_dfx_upload.tar se_sources.sha256 "$stage/"
echo "stage=$stage"
ls "$ws"
