mkdir -p artifacts
NVRAM_PATH=artifacts/win10-vars.fd

# Create copy of the NVRAM
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$NVRAM_PATH"

# realpath the backing file: the overlay resolves it relative to itself,
# not to $PWD (same reason run.sh does this)
BASE=$(realpath artifacts/win10-base-v1.qcow2)

qemu-img create -f qcow2 -F qcow2 -b "$BASE" artifacts/win10-run.qcow2
