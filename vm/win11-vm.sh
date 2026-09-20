#!/bin/bash

# ==========================================
# CONFIGURACIÓN (Ajustada a tu servidor 'nuc')
# ==========================================
VMID=9000
VM_NAME="Windows11"
STORAGE="local-zfs"       # <--- Almacenamiento para discos (ZFS)
DISK_SIZE="64"            # Tamaño del disco en GB
ISO_STORAGE="local"       # <--- Almacenamiento para ISOs (local)
WIN_ISO="Windows11.iso"
VIRTIO_ISO="virtio-win.iso"

# ==========================================
# 1. LIMPIEZA PREVIA
# ==========================================
if qm status $VMID >/dev/null 2>&1; then
    echo "La VM $VMID ya existe. Eliminándola para empezar de cero..."
    qm stop $VMID --skiplock
    sleep 3
    qm destroy $VMID --purge
fi

# ==========================================
# 2. CREACIÓN DE LA VM (Hardware base)
# ==========================================
echo "Creando VM $VMID con configuración para Windows 11..."
qm create $VMID \
  --name "$VM_NAME" \
  --memory 8192 \
  --cores 4 \
  --cpu host \
  --machine q35 \
  --bios ovmf \
  --ostype win11 \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-pci \
  --vga qxl \
  --agent enabled=1

# ==========================================
# 3. DISCOS REQUERIDOS (EFI, TPM y Principal)
# ==========================================
echo "Creando disco EFI con Secure Boot..."
qm set $VMID --efidisk0 ${STORAGE}:1,efitype=4m,pre-enrolled-keys=1

echo "Creando TPM 2.0..."
qm set $VMID --tpmstate0 ${STORAGE}:1,version=v2.0

echo "Creando disco principal de $DISK_SIZE GB en $STORAGE..."
qm set $VMID --scsi0 ${STORAGE}:${DISK_SIZE},ssd=1

# ==========================================
# 4. CONEXIÓN DE ISOs
# ==========================================
echo "Conectando ISOs desde $ISO_STORAGE..."
qm set $VMID --ide2 ${ISO_STORAGE}:iso/${WIN_ISO},media=cdrom
qm set $VMID --ide3 ${ISO_STORAGE}:iso/${VIRTIO_ISO},media=cdrom

# ==========================================
# 5. ARRANQUE
# ==========================================
echo "Iniciando VM..."
qm start $VMID
echo "¡Listo! La VM $VMID está corriendo. Abre la consola web."
