# system-to-install for the win10 pipeline dummy.
#
# This is the NixOS machine that 03-install-nixos.sh wipes the (former
# Windows) disk and installs: it builds
#   .#nixosConfigurations.win10-target.config.system.build.diskoScriptNoDeps
#   .#nixosConfigurations.win10-target.config.system.build.toplevel
# and hands both to stock nixos-anywhere (--phases disko,install).
#
# It is also the embryonic "saved configs" artifact of the future product:
# agent config = machine config, pushed through the same channel.
#
# BEFORE USE: paste your public key into users.users.root.openssh
# .authorizedKeys.keys — the SAME key you give to 01-prepare-payload.sh -k.
# 04-verify-install.sh ssh'es in with it; without it the pipeline loses
# access the moment the installer is replaced by this system.
#
# Place it in the build dir (next to 01..04) and run:
#   ./03-install-nixos.sh -f . -c win10-target
{
  description = "win10 pipeline dummy: system-to-install";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    disko.url = "github:nix-community/disko";
  };

  outputs = { self, nixpkgs, disko }:
    {
      nixosConfigurations.win10-target = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          {
            # --- disk layout: disko wipes /dev/sda and recreates it ---------
            # (the guest's IDE disk — the same device Windows used to live on)
            disko.devices.disk.main = {
              device = "/dev/sda";
              type = "disk";
              content = {
                type = "gpt";
                partitions = {
                  esp = {
                    size = "1G";
                    type = "EF00";
                    content = {
                      type = "filesystem";
                      format = "vfat";
                      mountpoint = "/boot";
                      mountOptions = [ "umask=0077" ];
                    };
                  };
                  root = {
                    size = "100%";
                    content = {
                      type = "filesystem";
                      format = "ext4";
                      mountpoint = "/";
                    };
                  };
                };
              };
            };

            # --- bootloader: registers the "Linux Boot Manager" firmware ----
            # entry. After disko wipes the disk this is the entry the
            # firmware falls through to when the dead Windows Boot Manager
            # fails (the reboot fallthrough 03's header describes).
            boot.loader.systemd-boot.enable = true;
            boot.loader.systemd-boot.configurationLimit = 3;
            boot.loader.efi.canTouchEfiVariables = true;

            # keep the serial console alive post-install, so run/serial.log
            # (02's capture) covers the third boot too
            boot.kernelParams = [ "console=ttyS0,115200" ];

            # --- access: 04-verify-install.sh logs in with this key ----------
            services.openssh.enable = true;
            services.openssh.settings.PermitRootLogin = "prohibit-password";
            users.users.root.openssh.authorizedKeys.keys = [
              # PASTE YOUR PUBLIC KEY HERE, e.g.:
              # "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@host"
            ];

            networking.hostName = "win10-target";
            system.stateVersion = "25.11";
          }
        ];
      };
    };
}
