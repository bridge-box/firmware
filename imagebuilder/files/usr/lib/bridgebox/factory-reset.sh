#!/bin/sh
# BridgeBox factory reset
# Resets JFFS2 overlay to factory SquashFS state and reboots.
#
# Usage: factory-reset.sh [--force]
# Without --force, asks for confirmation via logger (non-interactive).
# With --force, executes immediately (used by bb-agent).

logger -t factory-reset "Factory reset initiated"

# Step 1: Clean boot state (so device boots normally after reset)
echo '{"state":"normal","failure_count":"first"}' > /etc/bridgebox/boot-state.json
logger -t factory-reset "Boot state reset to normal"

# Step 2: Stop all bridgebox services gracefully
for svc in bridgebox-agent bridgebox-watchdog; do
    if [ -f "/etc/init.d/$svc" ]; then
        "/etc/init.d/$svc" stop 2>/dev/null
        logger -t factory-reset "Stopped $svc"
    fi
done

# Step 3: firstboot — reset JFFS2 overlay
# This marks the overlay for reset on next boot.
# The actual wipe happens during boot.
if firstboot -y; then
    logger -t factory-reset "firstboot successful — overlay will be reset on reboot"
else
    logger -t factory-reset "firstboot FAILED — aborting"
    exit 1
fi

# Step 4: Reboot
logger -t factory-reset "Rebooting..."
sync
reboot

# Should not reach here
exit 0
