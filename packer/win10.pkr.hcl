packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = ">= 1.1.3"
    }
  }
}

variable "iso_url" {
  type    = string
  default = ".iso/Win10_22H2_English_x64v1.iso"
}

variable "iso_checksum" {
  type    = string
  default = "none"
}

source "qemu" "win10" {
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  # UEFI, Secure Boot off (stock OVMF, no secboot/SMM variants)
  efi_boot          = true
  efi_firmware_code = "/usr/share/OVMF/OVMF_CODE_4M.fd"
  efi_firmware_vars = "/usr/share/OVMF/OVMF_VARS_4M.fd"
  accelerator = "kvm"
  cpus        = 2
  memory      = 4096
  headless    = true

  disk_size      = "64G"
  disk_interface = "ide"   # v1: no storage drivers needed (doc says virtio; see notes)
  net_device     = "e1000"  # v1: WinRM+SSH work with the in-box driver
  format         = "qcow2"

  cd_files     = ["autounattend.xml"]   # lands at CD root, setup finds it
  boot_wait    = "2s"
  boot_command = ["<enter><wait5><enter><wait5><enter><wait5><enter><wait5><enter>"]
  
  communicator   = "winrm"       # Windows has WinRM during OOBE; SSH gets installed by the answer file
  winrm_username = "Administrator"
  winrm_password = "Packer42!"
  winrm_timeout  = "2h"

  shutdown_command = "shutdown /s /t 10 /f"
  vm_name          = "win10-base.qcow2"
  output_directory = "output-win10"
  skip_compaction  = true
}

build {
  sources = ["source.qemu.win10"]
  provisioner "powershell" {
    inline = ["Get-Service sshd"]   # fails the build if SSH didn't get installed
  }
}
