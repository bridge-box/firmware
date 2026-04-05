#!/bin/sh
# Overlay verification — checks that overlay is working correctly.
# Exit 0 = all checks passed
# Exit 1 = verification failed (agent will rollback)
#
# Called by bb-agent after apply.sh completes.

CHECKS_PASSED=0
CHECKS_FAILED=0

check() {
    local name="$1"
    local cmd="$2"

    if eval "$cmd" >/dev/null 2>&1; then
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
        logger -t verify-overlay "PASS: $name"
    else
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
        logger -t verify-overlay "FAIL: $name"
    fi
}

# 1. Bridge interface is up
check "bridge_interface_up" "[ -d /sys/class/net/br0 ] && [ \"$(cat /sys/class/net/br0/operstate 2>/dev/null)\" = 'up' ]"

# 2. nftables rules loaded (nfqdns table exists)
check "nft_nfqdns_table" "nft list table inet nfqdns >/dev/null 2>&1"

# 3. nfqdns process running
check "nfqdns_running" "pgrep -x nfqdns >/dev/null 2>&1"

# 4. DNS interception active (queue 100 has a listener)
check "nfqueue_bound" "[ -f /proc/net/netfilter/nfnetlink_queue ] && grep -q '100' /proc/net/netfilter/nfnetlink_queue 2>/dev/null"

# 5. WAN connectivity (can reach a known IP)
check "wan_connectivity" "ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1"

# Summary
logger -t verify-overlay "verification: $CHECKS_PASSED passed, $CHECKS_FAILED failed"

if [ "$CHECKS_FAILED" -gt 0 ]; then
    logger -t verify-overlay "VERIFICATION FAILED — agent will rollback"
    exit 1
fi

logger -t verify-overlay "VERIFICATION PASSED"
exit 0
