workspace "nixos-anywhere" "C4 model of the nixos-anywhere repository: a CLI that installs NixOS on any SSH-reachable machine (kexec + disko + nixos-install). Inventory mapped from the repo layout: src/, terraform/, tests/, docs/." {

    model {
        # ---- People ----
        operator = person "Operator" "Engineer with a Nix-enabled source machine who provisions target servers by running the CLI (or the Terraform wrapper)."

        # ---- Software system in scope ----
        nixosAnywhere = softwareSystem "nixos-anywhere" "Universal NixOS installer: connects over SSH, kexecs into a NixOS installer, partitions/formats with disko, runs nixos-install, reboots. Single-command unattended installs." {

            cli = container "nixos-anywhere CLI" "Bash orchestrator src/nixos-anywhere.sh, packaged by src/default.nix as a Nix derivation (v1.13.0) with wrapped runtime deps (openssh, nix, curl, gnutar, sshpass, coreutils). Runs on the operator's machine." "Bash + Nix" {
                argParser    = component "Argument parser" "parseArgs(): --flake vs --store-paths, --phases, --disko-mode, --build-on, --kexec, --extra-files, --chown, --generate-hardware-config, --vm-test, ..." "Bash"
                sshClient    = component "SSH client" "runSsh/runSshNoTty wrappers; uploadSshKey() generates an ephemeral ed25519 key and ssh-copy-id's it to the target (sshpass with --env-password)." "Bash + OpenSSH"
                factGatherer = component "Fact gatherer" "importFacts(): pipes src/get-facts.sh through SSH and exports is*/has* facts (os, arch, installer, container, root, ipv6-only, tar/cpio/sudo/doas/wget/curl/setsid/nixos-facter)." "Bash + POSIX sh"
                buildPlanner = component "Build planner" "checkBuildLocally(): decides --build-on local/remote from the nix system and extra-platforms; falls back to building on the remote via ssh-ng store." "Bash + nix"
                hwConfig     = component "Hardware config generator" "generateHardwareConfig(): nixos-facter or nixos-generate-config over SSH; git intent-to-add the generated file into the flake." "Bash + nixos-facter"
                phaseKexec   = component "Phase: kexec" "runKexec(): fetch kexec installer tarball, run kexec under setsid, wait for the machine to return as the NixOS installer on root@ (--post-kexec-ssh-port)." "Bash + kexec"
                phaseDisko   = component "Phase: disko" "runDisko(): nix-copy the disko script (or build it on the remote), upload disk-encryption keys, destroy/create/mount filesystems on the target disks." "Bash + disko"
                phaseInstall = component "Phase: install" "nixosInstall(): copy the system closure to /mnt, apply --extra-files/--chown/--copy-host-keys, then nixos-install --no-root-passwd --no-channel-copy." "Bash + nixos-install"
                phaseReboot  = component "Phase: reboot" "nixosReboot(): unmount /mnt, export ZFS pools, reboot, wait for the target to drop off SSH." "Bash"
                vmTest       = component "VM test runner" "runVmTest(): --vm-test builds FLAKE.config.system.build.installTest and runs it in a local VM instead of installing." "Bash + nix-vm-test"
            }

            terraform = container "Terraform modules" "Optional HCL wrapper (terraform/): all-in-one, install, nix-build, nixos-rebuild. install/ invokes the CLI via a local-exec provisioner (run-nixos-anywhere.sh) with JSON-encoded arguments; terraform/tests provisions hcloud and digitalocean VMs (.tftest.hcl)." "Terraform/OpenTofu HCL"

            tests = container "VM test suite" "End-to-end tests (tests/): nix-vm-test VMs running from-nixos{,-stable,-with-sudo,-generate-config,-build-on-remote,-separated-phases} and ubuntu/fedora/debian kexec scenarios, using nixos-images kexec installers." "Nix + nix-vm-test"

            docs = container "Documentation site" "mdBook book (docs/): quickstart, requirements, CLI reference, how-tos (custom kexec, disko modes, terraform, secrets, no-os, ipv6...). Built via docs/default.nix." "Markdown + mdBook"
        }

        # ---- External systems ----
        target = softwareSystem "Target machine" "Bare-metal or cloud server reachable over SSH (LAN or internet): any x86_64/aarch64 Linux with kexec support, or one booted from a NixOS ISO. Completely wiped by the install." {
            tags "External"
        }
        flakeRepo = softwareSystem "Operator's NixOS flake" "User flake providing nixosConfigurations.HOST.config plus the disko config; source of system.build.diskoScript and system.build.toplevel (alternative: --store-paths)." {
            tags "External"
        }
        nixCache = softwareSystem "Nix binary caches" "cache.nixos.org plus extra substituters and trusted-public-keys taken from the flake and copied from the target machine." {
            tags "External"
        }
        github = softwareSystem "GitHub" "Hosts the default kexec installer tarballs (nix-community/nixos-images releases), flake inputs and git flakes." {
            tags "External"
        }

        # ---- Relationships (container level) ----
        operator -> cli "nixos-anywhere --flake .#HOST user@target [options]" "CLI"
        operator -> terraform "terraform apply using the all-in-one module" "terraform CLI"
        terraform -> cli "local-exec provisioner: run-nixos-anywhere.sh with JSON $ARGUMENTS" "shell"
        cli -> target "drives every phase over SSH: facts, kexec, disko, nixos-install, reboot" "SSH"
        cli -> flakeRepo "evaluates and builds diskoScript + system toplevel" "nix (flakes)"
        cli -> nixCache "nix copy of closures; substituters/trusted-keys exchange" "nix copy / HTTPS"
        cli -> github "downloads the kexec installer tarball (gh-v6.com fallback on IPv6-only targets)" "HTTPS"
        tests -> cli "runs the packaged CLI inside test VMs"
        tests -> target "fresh VMs act as the install targets"

        # ---- Relationships (component level, shown in the CLI component view) ----
        sshClient -> target "ssh-copy-id + remote command execution" "SSH"
        factGatherer -> target "executes src/get-facts.sh on the target" "SSH"
        hwConfig -> target "runs nixos-facter / nixos-generate-config" "SSH"
        phaseKexec -> github "wget/curl the kexec tarball (or upload a local --kexec file)" "HTTPS"
        phaseKexec -> target "setsid kexec/run; reconnect as root@ into the installer" "kexec + SSH"
        phaseDisko -> target "runs the disko script against the target disks" "SSH"
        phaseDisko -> nixCache "nix copy the disko closure into the installer store" "nix copy"
        phaseInstall -> target "nixos-install into /mnt; extra-files, chown, host keys" "SSH"
        phaseInstall -> nixCache "copies the nixos system closure to /mnt" "nix copy"
        buildPlanner -> flakeRepo "reads pkgs.system; remote build via ssh-ng store if needed" "nix"
        vmTest -> flakeRepo "nix build FLAKE.config.system.build.installTest" "nix"
        phaseKexec -> phaseDisko "next phase (--phases)"
        phaseDisko -> phaseInstall "next phase (--phases)"
        phaseInstall -> phaseReboot "next phase (--phases)"
    }

    views {
        systemContext nixosAnywhere "context" "System context: an operator uses nixos-anywhere to install NixOS on a target machine over SSH." {
            include *
            autoLayout
        }

        container nixosAnywhere "containers" "Container view: the CLI, Terraform wrapper, VM test suite and docs, plus the external systems they interact with." {
            include *
            autoLayout
        }

        component cli "cli-components" "Component view of the CLI: the phase pipeline kexec, disko, install, reboot plus its helpers." {
            include *
            exclude operator terraform tests docs
            autoLayout
        }
    }
}
