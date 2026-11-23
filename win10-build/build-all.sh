./build-image.sh
./build-installer.sh -k "${SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
./build-qcow.sh
