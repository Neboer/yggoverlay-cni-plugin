package yggoverlay

import (
	"fmt"
	"net"
	"time"

	"github.com/vishvananda/netlink"
	"golang.org/x/sys/unix"
)

func ConfigYGGOverlayNetwork(
	iface netlink.Link,
	yggAddr *net.IPNet, // MAN8S_YGGDRASIL_ADDRESS
	gwAddr *net.IPNet, // GW_ADDR
	tableID int, // default: 199
	tablePriority int, // default: 100
) error {
	// Default table if not provided
	if tableID == 0 {
		tableID = 199
	}

	// 2. Add IPv6 address to interface with noprefixroute=1
	addrCIDR := yggAddr.String()
	addr, err := netlink.ParseAddr(addrCIDR)
	if err != nil {
		return fmt.Errorf("invalid addr %s: %w", addrCIDR, err)
	}
	addr.Flags |= unix.IFA_F_NOPREFIXROUTE

	if err := netlink.AddrAdd(iface, addr); err != nil {
		return fmt.Errorf("failed to add addr %s: %w", addrCIDR, err)
	}

	// 3. Add route: $YGG_NET dev $IFACE table <tableID>
	ipNet := addr.IPNet

	route1 := &netlink.Route{
		LinkIndex: iface.Attrs().Index,
		Dst:       ipNet,
		Src:       yggAddr.IP,
		Table:     tableID,
	}

	var lastErr error
	for range 10 {
		if err := netlink.RouteAdd(route1); err != nil {
			lastErr = err
			time.Sleep(100 * time.Millisecond)
			continue
		}
		lastErr = nil
		break
	}
	if lastErr != nil {
		return fmt.Errorf("add route1: %w, command is: ip route add %s dev %s table %d", lastErr, ipNet.String(), iface.Attrs().Name, tableID)
	}

	// 4. Add route: 200::/7 via $GW dev $IFACE table <tableID>
	_, dst200, _ := net.ParseCIDR("200::/7")

	route2 := &netlink.Route{
		Dst:       dst200,
		LinkIndex: iface.Attrs().Index,
		Gw:        gwAddr.IP,
		Src:       yggAddr.IP,
		Table:     tableID,
	}

	if err := netlink.RouteAdd(route2); err != nil {
		return fmt.Errorf("add route2: %w, command is: ip route add 200::/7 via %s dev %s table %d", err, gwAddr.IP.String(), iface.Attrs().Name, tableID)
	}

	// 5. Add rule: to 200::/7 lookup <tableID> priority 100
	rule := netlink.NewRule()
	rule.Dst = dst200
	rule.Table = tableID
	rule.Priority = tablePriority

	if err := netlink.RuleAdd(rule); err != nil {
		return fmt.Errorf("add rule: %w", err)
	}

	return nil
}
