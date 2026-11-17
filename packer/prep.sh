sudo apt install xorriso
sudo usermod -aG kvm flash42
newgrp kvm        # for this terminal; or log out/in
packer build win10.pkr.hcl
