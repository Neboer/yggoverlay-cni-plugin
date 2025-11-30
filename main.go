package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strings"
	"syscall"

	"github.com/containernetworking/cni/pkg/skel"
	"github.com/containernetworking/cni/pkg/types"
	current "github.com/containernetworking/cni/pkg/types/100"
	"github.com/containernetworking/cni/pkg/version"
	"github.com/containernetworking/plugins/pkg/ipam"
	"github.com/containernetworking/plugins/pkg/netlinksafe"
	"github.com/containernetworking/plugins/pkg/ns"
	bv "github.com/containernetworking/plugins/pkg/utils/buildversion"
	"github.com/vishvananda/netlink"

	"github.com/Neboer/yggoverlay-cni-plugin/yggoverlay"
)

// PluginConf is whatever you expect your configuration json to be. This is whatever
// is passed in on stdin. Your plugin may wish to expose its functionality via
// runtime args, see CONVENTIONS.md in the CNI spec.
type PluginConf struct {
	// This embeds the standard NetConf structure which allows your plugin
	// to more easily parse standard fields like Name, Type, CNIVersion,
	// and PrevResult.
	types.NetConf
	// BrName string `json:"bridge"` // host network bridge mode interface's name useless here we can use prevResult
	YGGTablePriority int `json:"yggTablePriority"` // routing table priority for YGG overlay default 100
	YGGTableID       int `json:"yggTableID"`       // routing table ID for YGG overlay default 199
}

// parseConfig parses the supplied configuration (and prevResult) from stdin.
func parseConfig(stdin []byte) (*PluginConf, error) {
	conf := PluginConf{}

	if err := json.Unmarshal(stdin, &conf); err != nil {
		return nil, fmt.Errorf("failed to parse network configuration: %v", err)
	}

	// Parse previous result. This will parse, validate, and place the
	// previous result object into conf.PrevResult. If you need to modify
	// or inspect the PrevResult you will need to convert it to a concrete
	// versioned Result struct.
	if err := version.ParsePrevResult(&conf.NetConf); err != nil {
		return nil, fmt.Errorf("could not parse prevResult: %v", err)
	}

	if conf.YGGTablePriority == 0 {
		conf.YGGTablePriority = 100
	}

	if conf.YGGTableID == 0 {
		conf.YGGTableID = 199
	}

	// End previous result parsing

	return &conf, nil
}

func ensureAddr(br netlink.Link, family int, ipn *net.IPNet) error {
	addrs, err := netlinksafe.AddrList(br, family)
	if err != nil && err != syscall.ENOENT {
		return fmt.Errorf("could not get list of IP addresses: %v", err)
	}

	ipnStr := ipn.String()
	for _, a := range addrs {
		// string comp is actually easiest for doing IPNet comps
		if a.IPNet.String() == ipnStr {
			return nil
		}
	}

	addr := &netlink.Addr{IPNet: ipn, Label: ""}
	if err := netlink.AddrAdd(br, addr); err != nil && err != syscall.EEXIST {
		return fmt.Errorf("could not add IP address to %q: %v", br.Attrs().Name, err)
	}

	// Set the bridge's MAC to itself. Otherwise, the bridge will take the
	// lowest-numbered mac on the bridge, and will change as ifs churn
	if err := netlink.LinkSetHardwareAddr(br, br.Attrs().HardwareAddr); err != nil {
		return fmt.Errorf("could not set bridge's mac: %v", err)
	}

	return nil
}

// cmdAdd is called for ADD requests
func cmdAdd(args *skel.CmdArgs) error {
	conf, err := parseConfig(args.StdinData)
	if err != nil {
		return err
	}

	// A plugin can be either an "originating" plugin or a "chained" plugin.
	// Originating plugins perform initial sandbox setup and do not require
	// any result from a previous plugin in the chain. A chained plugin
	// modifies sandbox configuration that was previously set up by an
	// originating plugin and may optionally require a PrevResult from
	// earlier plugins in the chain.

	// START chained plugin code
	if conf.PrevResult == nil {
		// current plugin must be called just before an bridge plugin.
		return fmt.Errorf("must be called as chained plugin")
	}

	// Convert the PrevResult to a concrete Result type that can be modified.
	prevResult, err := current.GetResult(conf.PrevResult)
	if err != nil {
		return fmt.Errorf("failed to convert prevResult: %v", err)
	}

	if len(prevResult.Interfaces) == 0 {
		return fmt.Errorf("got no Interfaces, cannot continue, Quitting")
	}

	// Start configure container ygg network
	hostYggInfo, err := yggoverlay.GetHostYGGNetInfo()
	if err != nil {
		return fmt.Errorf("failed to get host YGG network info: %v", err)
	}
	brInterfaceInfo := prevResult.Interfaces[0]
	containerInterfaceInfo := prevResult.Interfaces[2]
	brInterface, err := netlink.LinkByName(brInterfaceInfo.Name)
	if err != nil {
		return fmt.Errorf("failed to lookup %q: %v", brInterfaceInfo.Name, err)
	}

	// ensure brInterface has ygg address hostYggInfo.BridgeYGGAddr
	err = ensureAddr(brInterface, netlink.FAMILY_V6, hostYggInfo.BridgeYGGAddr)
	if err != nil {
		return fmt.Errorf("failed to ensure ygg addr on bridge %q: %v", brInterfaceInfo.Name, err)
	}

	// configure ygg overlay network on container network namespace
	netns, err := ns.GetNS(args.Netns)
	if err != nil {
		return fmt.Errorf("failed to open netns %q: %v", args.Netns, err)
	}
	defer netns.Close()

	// args.Args is like CNI_ARGS=NERDCTL_CNI_DHCP_HOSTNAME=test-nginx-4;IgnoreUnknown=1 we parse it.
	parsedArgs := map[string]string{}
	if args.Args != "" {
		argPairs := strings.Split(args.Args, ";")
		for _, pair := range argPairs {
			kv := strings.SplitN(pair, "=", 2)
			if len(kv) == 2 {
				parsedArgs[kv[0]] = kv[1]
			}
		}
	}
	containerHostName, ok := parsedArgs["NERDCTL_CNI_DHCP_HOSTNAME"]
	if !ok || containerHostName == "" {
		return fmt.Errorf("failed to get container ID from CNI_ARGS NERDCTL_CNI_DHCP_HOSTNAME, hostname must be set")
	}

	precalculatedContainerYGGAddr, err := yggoverlay.EncodeContainerNameToYGGAddr(hostYggInfo.YGGSubnetAddr, containerHostName)
	if err != nil {
		return fmt.Errorf("failed to encode container name to YGG address: %v", err)
	}
	precalculatedContainerYGGAddr.Mask = net.CIDRMask(64, 128) // set /64 mask

	err = netns.Do(func(hostNS ns.NetNS) error {
		containerInterface, err := netlink.LinkByName(containerInterfaceInfo.Name)
		if err != nil {
			return fmt.Errorf("failed to lookup %q: %v", containerInterfaceInfo.Name, err)
		}

		// 1. If container has IPv6 address, change it's routes' src addr to IPv6 addr.
		// find specificed IPv6 address and its gateway from prevResult.IPs
		var containerIPv6 *current.IPConfig
		for _, ip := range prevResult.IPs {
			if ip == nil || ip.Address.IP == nil {
				continue
			}
			// To4() == nil means it's IPv6
			if ip.Address.IP.To4() == nil {
				if containerIPv6 != nil {
					return fmt.Errorf("multiple IPv6 addresses found in prevResult.IPs")
				}
				containerIPv6 = ip
			}
		}

		if containerIPv6 != nil {
			// If no gateway is set, error out
			if containerIPv6.Gateway == nil {
				return fmt.Errorf("IPv6 route gateway must be set")
			}

			// change this route, set its src = containerIPv6.Address.IP
			routes, err := netlink.RouteList(containerInterface, netlink.FAMILY_V6)
			if err != nil && err != syscall.ENOENT {
				return fmt.Errorf("could not list IPv6 routes: %v", err)
			}

			for _, rt := range routes {
				if rt.Gw == nil {
					continue
				}
				if rt.Gw.Equal(containerIPv6.Gateway) {
					// need change this route to use src = containerIPv6.Address.IP
					// set the route's source to the container IPv6 address while preserving other fields
					rt.Src = containerIPv6.Address.IP

					if err := netlink.RouteReplace(&rt); err != nil {
						return fmt.Errorf("failed to replace route via %v: %v", rt.Gw, err)
					}

					break
				}
			}
		}

		return yggoverlay.ConfigYGGOverlayNetwork(
			containerInterface,
			precalculatedContainerYGGAddr,
			hostYggInfo.BridgeYGGAddr,
			conf.YGGTableID,
			conf.YGGTablePriority,
		)
	})

	if err != nil {
		return fmt.Errorf("failed to configure YGG overlay network: %v", err)
	}

	// Pass the prevResult through this plugin to the next one
	result := prevResult

	return types.PrintResult(result, conf.CNIVersion)
}

// cmdDel is called for DELETE requests
func cmdDel(args *skel.CmdArgs) error {
	conf, err := parseConfig(args.StdinData)
	if err != nil {
		return err
	}
	_ = conf

	// Do your delete here

	return nil
}

func main() {
	// command-line subcommand parser
	if len(os.Args) > 1 {
		cmd := os.Args[1]
		switch cmd {
		case "getsuffix":
			if len(os.Args) < 3 {
				fmt.Fprintf(os.Stderr, "usage: %s getsuffix <string>\n", os.Args[0])
				os.Exit(2)
			}
			inputStr := os.Args[2]
			// return the last 8 characters (or the whole string if shorter)
			ygginfo, err := yggoverlay.GetHostYGGNetInfo()
			if err != nil {
				fmt.Fprintf(os.Stderr, "error getting host YGG info: %v\n", err)
				os.Exit(1)
			}
			resultIP, err := yggoverlay.EncodeContainerNameToYGGAddr(ygginfo.YGGSubnetAddr, inputStr)
			if err != nil {
				fmt.Fprintf(os.Stderr, "error encoding container name to YGG addr: %v\n", err)
				os.Exit(1)
			}
			fmt.Println(resultIP.IP.String())
			os.Exit(0) // successfully
			// handled the subcommand, exit before running as a CNI plugin
			return
		}
	}

	skel.PluginMainFuncs(skel.CNIFuncs{
		Add:    cmdAdd,
		Check:  cmdCheck,
		Del:    cmdDel,
		Status: cmdStatus,
		/* FIXME GC */
	}, version.All, bv.BuildString("yggoverlay"))
}

func cmdCheck(_ *skel.CmdArgs) error {
	// TODO: implement
	return fmt.Errorf("not implemented")
}

// cmdStatus implements the STATUS command, which indicates whether or not
// this plugin is able to accept ADD requests.
//
// If the plugin has external dependencies, such as a daemon
// or chained ipam plugin, it should determine their status. If all is well,
// and an ADD can be successfully processed, return nil
func cmdStatus(args *skel.CmdArgs) error {
	conf, err := parseConfig(args.StdinData)
	if err != nil {
		return err
	}
	_ = conf

	// If this plugins delegates IPAM, ensure that IPAM is also running
	if err := ipam.ExecStatus(conf.IPAM.Type, args.StdinData); err != nil {
		return err
	}

	// TODO: implement STATUS here
	// e.g. querying an external deamon, or delegating STATUS to an IPAM plugin

	return nil
}
