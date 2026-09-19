#!/bin/bash

# --- Variables ---
VMID=9000
VM_NAME="Windows11"
STORAGE="local-lvm"   # Ajusta si usas otro almacenamiento (ej. 'local-zfs')
DISK_SIZE="50"        # Tamaño en GB
ISO_STORAGE="local"   # Almacenamiento donde está el ISO (normalmente 'local')
WIN_ISO="Windows11.iso"

# --- Descarga del ISO (si no existe) ---
WIN11_ISO_URL="https://ts.buzzheavier.com/d/t3wgmn5p49ir?v=_tV1MLUQ9DZ34iNL2QhoJuVnfgia3agAlYAbBS12_B7v6ZzQVN0pCXWsYADDZc2MBKyaE9dZxp681HKLHoJlWsrm7DuCND8_jeJw6Zx8GM4zMSBBrs__FjApQjNuXxSDWNJ_V8F7pAN129CBDQFU-6CtyOGQOh4hYc0jtVxXqpfnUpaA1TalBZOBCCiAdLyWmUPrLTrM_hMneymAS4nIHGgIgUBBAlRFBxh08zyfytCiBZQrwxqZ7dv2OBawaKuGT2MFkCoYKA"

if [ ! -f "/var/lib/vz/template/iso/$WIN_ISO" ]; then
    echo "Descargando ISO de Windows 11..."
    wget -O "/var/lib/vz/template/iso/$WIN_ISO" "$WIN11_ISO_URL"
else
    echo "El ISO ya existe, omitiendo descarga."
fi

# --- Crear la VM ---
echo "Creando VM $VMID..."
qm create $VMID \
  --name $VM_NAME \
  --memory 8192 \
  --cpu host \
  --net0 virtio,bridge=vmbr0 \
  --ostype win11 \
  --scsihw virtio-scsi-pci \
  --agent enabled=1

# --- Crear y asignar el disco principal ---
echo "Creando disco de $DISK_SIZE GB en $STORAGE..."
pvesm alloc $STORAGE $VMID vm-$VMID-disk-0 $DISK_SIZE
qm set $VMID --scsi0 $STORAGE:vm-$VMID-disk-0

# --- Crear disco EFI (necesario para arranque UEFI) ---
echo "Creando disco EFI..."
pvesm alloc $STORAGE $VMID vm-$VMID-disk-1 4M
qm set $VMID --efidisk0 $STORAGE:vm-$VMID-disk-1,format=raw,pre-enrolled-keys=1

# --- Crear TPM 2.0 (requisito de Windows 11) ---
echo "Creando TPM 2.0..."
pvesm alloc $STORAGE $VMID vm-$VMID-disk-2 4M
qm set $VMID --tpmstate0 $STORAGE:vm-$VMID-disk-2,version=v2.0

# --- Conectar el ISO de Windows ---
echo "Conectando ISO..."
qm set $VMID --ide2 $ISO_STORAGE:iso/$WIN_ISO,media=cdrom

# --- Configuración de pantalla (SPICE) ---
echo "Configurando pantalla QXL (SPICE)..."
qm set $VMID --vga qxl

# --- (Opcional) Establecer un UUID de SMBIOS personalizado ---
# UUID=$(cat /proc/sys/kernel/random/uuid)
# qm set $VMID --smbios1 uuid=$UUID

# --- Arrancar la VM ---
echo "Iniciando VM $VMID..."
qm start $VMID

echo "VM $VMID creada y iniciada. Accede a la consola SPICE desde la interfaz web."

#bash -c "$(wget -qLO - https://raw.githubusercontent.com/carlosnewmusic/Opnsense/refs/heads/main/vm/win11-vm.sh"
