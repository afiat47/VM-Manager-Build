#!/usr/bin/env bash
# Runs at the end of the Ubuntu installation (autoinstall late-commands), in the installer
# environment: the new system is mounted at /target, the install media at /cdrom.
set -euo pipefail

say() { echo "vm-manager: $*"; }

# The role chosen in the boot menu: vmm.role=create (first server) or vmm.role=join.
role="$(tr ' ' '\n' </proc/cmdline | sed -n 's/^vmm\.role=//p' | tail -n1)"
case "${role}" in
create | join) ;;
*) role=create ;;
esac

say "copying the installation bundle to /opt/vm-manager (several GB)"
mkdir -p /target/opt/vm-manager
cp -a /cdrom/vmm/. /target/opt/vm-manager/

mkdir -p /target/etc/vm-manager
echo "${role}" >/target/etc/vm-manager/role

install -m 0755 /cdrom/vmm-iso/vmm-firstboot /target/usr/local/sbin/vmm-firstboot
install -m 0755 /cdrom/vmm-iso/vmm-install /target/usr/local/sbin/vmm-install
install -m 0755 /cdrom/vmm-iso/vmm-join /target/usr/local/sbin/vmm-join
install -m 0644 /cdrom/vmm-iso/vmm-firstboot.service /target/etc/systemd/system/vmm-firstboot.service
curtin in-target --target=/target -- systemctl enable vmm-firstboot.service

say "role ${role}; VM Manager is set up on first boot"
