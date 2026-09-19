#!/bin/bash
#source https://gist.github.com/fguisso/08428cb4793be7442e3c209b00caf59d
# Specify the Windows 11 ISO to download
WIN11_ISO_URL="https://ts.buzzheavier.com/d/t3wgmn5p49ir?v=_tV1MLUQ9DZ34iNL2QhoJuVnfgia3agAlYAbBS12_B7v6ZzQVN0pCXWsYADDZc2MBKyaE9dZxp681HKLHoJlWsrm7DuCND8_jeJw6Zx8GM4zMSBBrs__FjApQjNuXxSDWNJ_V8F7pAN129CBDQFU-6CtyOGQOh4hYc0jtVxXqpfnUpaA1TalBZOBCCiAdLyWmUPrLTrM_hMneymAS4nIHGgIgUBBAlRFBxh08zyfytCiBZQrwxqZ7dv2OBawaKuGT2MFkCoYKA"

# Download the Windows 11 ISO
wget -O /var/lib/vz/template/iso/Windows11.iso $WIN11_ISO_URL

# Create a new VM in Proxmox
qm create 9000 --name Windows11 --memory 8589 --cpu host --net0 virtio,bridge=vmbr0

# Add a SATA hard drive to the VM
qm set 9000 --scsihw virtio-scsi-pci --scsi0 /var/lib/vz/images/9000/vm-9000-disk-0.qcow2,ssd=1,size=50G

# Attach the Windows 11 ISO to the VM's CD/DVD drive
qm set 9000 --ide2 /var/lib/vz/template/iso/Windows11.iso,media=cdrom

# Set the VM to use the "kvm64" CPU type
qm set 9000 --cpu kvm64

# Enable the QXL display driver for improved performance
qm set 9000 --vga qxl

# Add a Spice console to the VM for remote desktop access
qm set 9000 --spicehw virtio-vga --spiceport 5900 --password mypassword

# Set the SMBIOS UUID to a unique value for each VM
qm set 9000 --smbios1 uuid=$(uuidgen)

# Start the VM
qm start 9000

exit 0;

bash -c "$(wget -qLO - https://gist.githubusercontent.com/guillaumebeyssac/4fe56484b4cb2bd5491ce6f52a75fbc2/raw/a2aca5cfff4ef713f60a59fa776ff5c28f928139/install-win10-proxmox.md"
