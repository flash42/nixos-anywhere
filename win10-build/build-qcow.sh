NVRAM_PATH=win10-vars.fd

# Create copy of the NVRAM
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$NVRAM_PATH"

qemu-img create -f qcow2 -F qcow2 -b "artifacts/win10-base.qcow2" win10-run.qcow2
