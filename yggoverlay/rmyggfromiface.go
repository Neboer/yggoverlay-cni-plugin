package yggoverlay

import (
	"fmt"
	"net"

	"github.com/vishvananda/netlink"
)

// completly undo the ConfigYGGOverlayNetwork function.
// but it takes no arguments because CNI plugin is executed reversely
// and we have no way to pass the previous parameters here.
// the whole function executed in the netns of the container.
func RemoveYGGOverlayNetwork() error {

	// the add process's steps were:
	// 1. add ygg addr to iface with noprefixroute
	// 2. add route: $YGG_NET dev $IFACE table <tableID>
	// 3. add route: 200::/7 via $GW dev $IFACE table <tableID>
	// 4. add rule: from $YGG_ADDR lookup <tableID> priority <tablePriority>
	// so, here we reverse these steps.

	_, dst200, _ := net.ParseCIDR("200::/7")
	rules, err := netlink.RuleList(netlink.FAMILY_V6)
	if err != nil {
		return fmt.Errorf("list rules: %w", err)
	}
	var ygg_table_id int = -1
	// 1. find the table ID used for YGG overlay by looking for rule to 200::/7
	// and delete that rule
	for _, rule := range rules {
		if rule.Dst != nil && rule.Dst.String() == dst200.String() {
			ygg_table_id = rule.Table
			if err := netlink.RuleDel(&rule); err != nil {
				return fmt.Errorf("delete rule %v: %w", rule, err)
			}
		}
	}

	if ygg_table_id == -1 {
		// no YGG overlay found, nothing to do
		fmt.Println("no YGG overlay rule found, nothing to do")
		return nil
	}

	// usually, this link is the main bridge link of the interface.
	var ygg_link netlink.Link = nil
	// 2. delete the two routes in that table
	routes, err := netlink.RouteListFiltered(netlink.FAMILY_V6, &netlink.Route{
		Table: ygg_table_id,
	}, netlink.RT_FILTER_TABLE)
	if err != nil {
		return fmt.Errorf("list routes in table %d: %w", ygg_table_id, err)
	}
	for _, route := range routes {
		// remember the link for later addr deletion
		ygg_link, err = netlink.LinkByIndex(route.LinkIndex)
		if err != nil {
			return fmt.Errorf("get link by index %d: %w", route.LinkIndex, err)
		}
		// delete the route
		if err := netlink.RouteDel(&route); err != nil {
			return fmt.Errorf("can't delete route %v: %w", route, err)
		}
	}

	if ygg_link == nil {
		fmt.Println("failed to find link for YGG overlay")
		return nil
	}

	// 3. delete the YGG addr from the interface
	addrs, err := netlink.AddrList(ygg_link, netlink.FAMILY_V6)
	if err != nil {
		fmt.Printf("list addrs on link %s: %v\n", ygg_link.Attrs().Name, err)
		return err
	}

	for _, addr := range addrs {
		// find the addr within 200::/7
		if dst200.Contains(addr.IP) {
			if err := netlink.AddrDel(ygg_link, &addr); err != nil {
				return fmt.Errorf("delete addr %v from link %s: %w", addr, ygg_link.Attrs().Name, err)
			}
		}
	}

	return nil
}
