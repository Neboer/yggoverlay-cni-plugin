#!/usr/bin/env bash
# yggoverlay end-to-end and stress test
#
# Verifies:
#   - Correct ygg address derivation and assignment
#   - table 199 routes and ip rule setup
#   - Address stability across restarts (same hostname → same address)
#   - No residual host rules/routes after container deletion
#   - Correctness under rapid parallel container start/stop (NODAD stress)
#   - IPv4-only network support
#
# Must be run as root.
# Usage: sudo bash scripts/test-e2e.sh [OPTIONS]
#
# Options (env vars or positional):
#   NETWORK        nerdctl network name with yggoverlay   (default: man8yggbr)
#   PARALLEL       containers started simultaneously      (default: 5)
#   CYCLES         parallel stress cycles                 (default: 4)
#   BINARY         path to yggoverlay binary              (default: ./out/yggoverlay)
#   SKIP_V4ONLY    skip IPv4-only subtest (1=skip)        (default: 0)

set -uo pipefail

NETWORK="${NETWORK:-${1:-man8yggbr}}"
PARALLEL="${PARALLEL:-${2:-5}}"
CYCLES="${CYCLES:-${3:-4}}"
BINARY="${BINARY:-./out/yggoverlay}"
SKIP_V4ONLY="${SKIP_V4ONLY:-0}"

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0

pass() { PASS=$((PASS+1)); echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { FAIL=$((FAIL+1)); echo -e "${RED}[FAIL]${NC} $*"; }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }
section() { echo -e "\n${CYAN}══ $* ══${NC}"; }

# ── unique tag so parallel test runs don't collide ───────────────────────────
TAG="ygg-test-$$"

# ── cleanup on exit ──────────────────────────────────────────────────────────
cleanup() {
    local names
    names=$(nerdctl ps -a --format '{{.Names}}' 2>/dev/null | grep "^${TAG}-" || true)
    if [ -n "$names" ]; then
        info "Cleaning up leftover containers..."
        echo "$names" | xargs nerdctl rm -f 2>/dev/null || true
    fi
    # Remove temporary IPv4-only test network if we created it
    if [ -n "${V4_CONFLIST:-}" ] && [ -f "$V4_CONFLIST" ]; then
        rm -f "$V4_CONFLIST"
    fi
}
trap cleanup EXIT

# ── helper: get ygg address from a running container ────────────────────────
container_ygg_addr() {
    # returns the IP (without prefix) of the NOPREFIXROUTE address (ygg addr)
    nerdctl exec "$1" ip -6 addr show 2>/dev/null \
        | grep "noprefixroute" \
        | awk '{print $2}' \
        | cut -d/ -f1 \
        | head -1
}

# ── helper: start a container, return 0 on success ──────────────────────────
start_container() {
    local name="$1" hostname="$2" network="$3"
    nerdctl run -d --network="$network" --hostname "$hostname" --name "$name" \
        alpine sleep 120 >/dev/null 2>&1
}

# ── pre-checks ───────────────────────────────────────────────────────────────
section "Pre-checks"

if [ "$(id -u)" -ne 0 ]; then
    fail "Must run as root (sudo)"
    exit 1
fi

if [ ! -x "$BINARY" ]; then
    fail "Binary not found or not executable: $BINARY"
    exit 1
fi
pass "Binary exists: $BINARY"

if ! nerdctl info >/dev/null 2>&1; then
    fail "nerdctl / containerd not accessible"
    exit 1
fi
pass "nerdctl accessible"

if ! nerdctl network inspect "$NETWORK" >/dev/null 2>&1; then
    fail "Network '$NETWORK' not found. Create it or set NETWORK= to an existing network with yggoverlay."
    exit 1
fi
pass "Network '$NETWORK' exists"

if [ ! -S /var/run/yggdrasil.sock ]; then
    fail "Yggdrasil socket not found at /var/run/yggdrasil.sock"
    exit 1
fi
pass "Yggdrasil socket found"

# ── Test 1: Basic setup ───────────────────────────────────────────────────────
section "Test 1: Basic setup (address, routes, rules)"

T1_NAME="${TAG}-basic"
T1_HOST="${TAG}-basic"

expected_addr=$("$BINARY" getsuffix "$T1_HOST" 2>/dev/null) || {
    fail "getsuffix failed (is yggdrasil running?)"
    expected_addr=""
}

if start_container "$T1_NAME" "$T1_HOST" "$NETWORK"; then
    actual_addr=$(container_ygg_addr "$T1_NAME")

    if [ -n "$expected_addr" ]; then
        if [ "$actual_addr" = "$expected_addr" ]; then
            pass "ygg address matches getsuffix: $actual_addr"
        else
            fail "ygg address mismatch: expected=$expected_addr  actual=$actual_addr"
        fi
    fi

    # Check NOPREFIXROUTE and NODAD flags (flags 02 = NODAD)
    addr_flags=$(nerdctl exec "$T1_NAME" ip -6 addr show 2>/dev/null | grep "noprefixroute" || true)
    if echo "$addr_flags" | grep -q "flags 02"; then
        pass "NODAD flag set on ygg address"
    else
        fail "NODAD flag NOT set on ygg address: $addr_flags"
    fi

    # Check table 199 routes
    routes=$(nerdctl exec "$T1_NAME" ip -6 route show table 199 2>/dev/null || true)
    if echo "$routes" | grep -q "200::/7"; then
        pass "table 199 has 200::/7 route"
    else
        fail "table 199 missing 200::/7 route. Routes: $routes"
    fi

    # Check ip rule
    if nerdctl exec "$T1_NAME" ip -6 rule show 2>/dev/null | grep -q "200::/7 lookup 199"; then
        pass "ip rule: to 200::/7 lookup 199 present"
    else
        fail "ip rule: to 200::/7 lookup 199 NOT found"
    fi

    # No global IPv6 default route should use ygg address as src (check src fixup)
    default_route=$(nerdctl exec "$T1_NAME" ip -6 route show 2>/dev/null | grep "^2000::" || true)
    if [ -n "$default_route" ]; then
        if echo "$default_route" | grep -qv "$actual_addr"; then
            pass "IPv6 default route src is NOT the ygg address (src fixup correct)"
        else
            fail "IPv6 default route src is the ygg address (src fixup broken): $default_route"
        fi
    else
        info "No IPv6 default route (IPv4-only IPAM or no IPv6 gateway) — src fixup not applicable"
    fi

    nerdctl rm -f "$T1_NAME" >/dev/null 2>&1

    # Verify no stale host rules
    stale=$(ip -6 rule show 2>/dev/null | grep "200::/7" || true)
    if [ -z "$stale" ]; then
        pass "No stale host ip rules after container deletion"
    else
        fail "Stale host ip rules remain: $stale"
    fi
else
    fail "Container failed to start for basic test"
    nerdctl rm -f "$T1_NAME" >/dev/null 2>&1 || true
fi

# ── Test 2: Address stability ─────────────────────────────────────────────────
section "Test 2: Address stability (same hostname → same address across restarts)"

T2_HOST="${TAG}-stable"
addrs=()

for run in 1 2 3; do
    name="${TAG}-stable-${run}"
    if start_container "$name" "$T2_HOST" "$NETWORK"; then
        addr=$(container_ygg_addr "$name")
        addrs+=("${addr:-MISSING}")
        nerdctl rm -f "$name" >/dev/null 2>&1
    else
        addrs+=("START_FAILED")
        nerdctl rm -f "$name" >/dev/null 2>&1 || true
    fi
done

all_same=true
ref="${addrs[0]}"
for a in "${addrs[@]}"; do
    [ "$a" != "$ref" ] && all_same=false
done

if $all_same && [ "$ref" != "MISSING" ] && [ "$ref" != "START_FAILED" ]; then
    pass "Address stable across 3 restarts: $ref"
else
    fail "Address NOT stable: ${addrs[*]}"
fi

# ── Test 3: Parallel start/stop stress (NODAD validation) ────────────────────
section "Test 3: Parallel stress — ${PARALLEL} containers × ${CYCLES} cycles"
info "This validates that IFA_F_NODAD makes addresses immediately usable with no EEXIST/DAD errors."

total_start_fail=0
total_addr_fail=0
total_rule_leak=0

for cycle in $(seq 1 "$CYCLES"); do
    info "  Cycle ${cycle}/${CYCLES}: starting ${PARALLEL} containers in parallel..."

    declare -a PIDS=()
    declare -a CNAMES=()

    for i in $(seq 1 "$PARALLEL"); do
        name="${TAG}-par-c${cycle}-${i}"
        CNAMES+=("$name")
        start_container "$name" "par-${cycle}-${i}" "$NETWORK" &
        PIDS+=($!)
    done

    # Collect start results
    cycle_start_fail=0
    for pid in "${PIDS[@]}"; do
        if ! wait "$pid" 2>/dev/null; then
            cycle_start_fail=$((cycle_start_fail+1))
        fi
    done
    total_start_fail=$((total_start_fail+cycle_start_fail))

    if [ "$cycle_start_fail" -eq 0 ]; then
        pass "  Cycle ${cycle}: all ${PARALLEL} containers started"
    else
        fail "  Cycle ${cycle}: ${cycle_start_fail}/${PARALLEL} containers failed to start"
    fi

    # Verify ygg addresses
    cycle_addr_fail=0
    for name in "${CNAMES[@]}"; do
        addr=$(container_ygg_addr "$name")
        if [ -z "$addr" ]; then
            cycle_addr_fail=$((cycle_addr_fail+1))
            fail "  Cycle ${cycle}: ${name} has no ygg address"
        fi
    done
    total_addr_fail=$((total_addr_fail+cycle_addr_fail))

    if [ "$cycle_addr_fail" -eq 0 ]; then
        pass "  Cycle ${cycle}: all ${PARALLEL} containers have ygg addresses"
    fi

    # Remove all containers in parallel
    declare -a RM_PIDS=()
    for name in "${CNAMES[@]}"; do
        nerdctl rm -f "$name" >/dev/null 2>&1 &
        RM_PIDS+=($!)
    done
    for pid in "${RM_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Verify no stale host rules
    stale=$(ip -6 rule show 2>/dev/null | grep "200::/7" || true)
    if [ -z "$stale" ]; then
        pass "  Cycle ${cycle}: no stale host rules after cleanup"
    else
        total_rule_leak=$((total_rule_leak+1))
        fail "  Cycle ${cycle}: stale host rules: $stale"
        # Attempt cleanup to not break subsequent cycles
        ip -6 rule del to 200::/7 2>/dev/null || true
    fi

    unset PIDS CNAMES RM_PIDS
done

info "Parallel stress summary: start_fail=${total_start_fail}  addr_fail=${total_addr_fail}  rule_leaks=${total_rule_leak}"

# ── Test 4: Rapid sequential start/stop ──────────────────────────────────────
section "Test 4: Rapid sequential start/stop (10 iterations)"

seq_fail=0
for i in $(seq 1 10); do
    name="${TAG}-seq-${i}"
    if start_container "$name" "seq-${i}" "$NETWORK"; then
        addr=$(container_ygg_addr "$name")
        nerdctl rm -f "$name" >/dev/null 2>&1
        if [ -z "$addr" ]; then
            seq_fail=$((seq_fail+1))
        fi
    else
        seq_fail=$((seq_fail+1))
        nerdctl rm -f "$name" >/dev/null 2>&1 || true
    fi
done

stale=$(ip -6 rule show 2>/dev/null | grep "200::/7" || true)
if [ "$seq_fail" -eq 0 ] && [ -z "$stale" ]; then
    pass "10 sequential start/stop cycles: no errors, no stale rules"
else
    fail "Sequential test: ${seq_fail} failures, stale_rules='${stale}'"
fi

# ── Test 5: IPv4-only network ─────────────────────────────────────────────────
if [ "$SKIP_V4ONLY" = "0" ]; then
    section "Test 5: IPv4-only network"

    V4_NET="yggtest-v4only-$$"
    V4_BRIDGE="ygtbr${$: -4}"  # short unique bridge name
    V4_CONFLIST="/etc/cni/net.d/99-${V4_NET}.conflist"

    # Write a temporary IPv4-only + yggoverlay conflist
    cat > "$V4_CONFLIST" << CONFEOF
{
  "cniVersion": "1.0.0",
  "name": "${V4_NET}",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "${V4_BRIDGE}",
      "isGateway": true,
      "ipMasq": true,
      "ipMasqBackend": "nftables",
      "ipam": {
        "type": "host-local",
        "routes": [{ "dst": "0.0.0.0/0" }],
        "ranges": [[{ "subnet": "10.255.240.0/24" }]]
      }
    },
    { "type": "yggoverlay" }
  ]
}
CONFEOF

    T5_NAME="${TAG}-v4only"
    T5_HOST="${TAG}-v4only"

    if start_container "$T5_NAME" "$T5_HOST" "$V4_NET"; then
        # Must have ygg addr
        addr=$(container_ygg_addr "$T5_NAME")
        if [ -n "$addr" ]; then
            pass "IPv4-only: ygg address assigned: $addr"
        else
            fail "IPv4-only: no ygg address assigned"
        fi

        # Must NOT have any global IPv6 route (2000::/3 or similar)
        global_rt=$(nerdctl exec "$T5_NAME" ip -6 route show 2>/dev/null \
            | grep -E "^2[0-9a-f]" \
            | grep -v "table 199" || true)
        if [ -z "$global_rt" ]; then
            pass "IPv4-only: no global IPv6 routes (cannot reach global v6)"
        else
            fail "IPv4-only: unexpected global IPv6 route: $global_rt"
        fi

        # Must have table 199
        if nerdctl exec "$T5_NAME" ip -6 route show table 199 2>/dev/null | grep -q "200::/7"; then
            pass "IPv4-only: table 199 has 200::/7 route"
        else
            fail "IPv4-only: table 199 missing 200::/7 route"
        fi

        nerdctl rm -f "$T5_NAME" >/dev/null 2>&1
    else
        fail "IPv4-only: container failed to start"
        nerdctl rm -f "$T5_NAME" >/dev/null 2>&1 || true
    fi

    rm -f "$V4_CONFLIST"
    V4_CONFLIST=""
fi

# ── Summary ───────────────────────────────────────────────────────────────────
section "Summary"
echo -e "  Passed: ${GREEN}${PASS}${NC}   Failed: ${RED}${FAIL}${NC}"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}All tests passed.${NC}"
    exit 0
else
    echo -e "${RED}${FAIL} test(s) failed.${NC}"
    exit 1
fi
