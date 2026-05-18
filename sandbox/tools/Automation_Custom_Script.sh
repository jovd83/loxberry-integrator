#!/bin/bash
# DietPi runs this file at the very end of automated first-boot setup.
# Path inside the VM: /boot/Automation_Custom_Script.sh
# Triggered by AUTO_SETUP_CUSTOM_SCRIPT_EXEC=/boot/Automation_Custom_Script.sh
# in /boot/dietpi.txt.
#
# Purpose: install LoxBerry on top of the freshly-prepared DietPi base, then
# reboot so the host-side build script can detect the running LoxBerry web UI.

set -u

LOG=/boot/loxberry_install.log
INSTALLER='https://raw.githubusercontent.com/mschlenstedt/Loxberry_Installer/main/install.sh'

{
  echo "=== $(date -Is) LoxBerry auto-install starting ==="
  echo "Kernel: $(uname -a)"
  echo "Disk:   $(df -h / | tail -1)"
  echo

  # The official installer; up to ~2h on small VMs.
  bash <(curl -fsSL "$INSTALLER")
  rc=$?

  echo
  echo "=== $(date -Is) LoxBerry installer exited with rc=$rc ==="

  if [ "$rc" -eq 0 ]; then
    # The installer prints "reboot" as a manual final step; do it ourselves
    # so the host-side script can poll the LoxBerry hostname/IP.
    echo "Rebooting in 10s to finalise LoxBerry install"
    sleep 10
    /sbin/reboot
  else
    echo "LoxBerry installer FAILED. Inspect $LOG and SSH in as root/dietpi."
  fi
} 2>&1 | tee -a "$LOG"
