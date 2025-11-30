package yggoverlay

import (
	"encoding/json"
	"fmt"
	"net"

	"github.com/yggdrasil-network/yggdrasil-go/src/admin"
)

type HostYggdrasilNetInfo struct {
	YGGIPAddr     *net.IPNet // host's Yggdrasil IP address, e.g., 200:xx:yy:zz::aa/128
	YGGSubnetAddr *net.IPNet // subnet address, the rest is all zero. E.g., 300:xx::/64
	BridgeYGGAddr *net.IPNet // network address for srvgrp0 bridge interface, it has a '1' in the last segment. E.g., 300:xx:yy:zz::1/64
}

// GetHostYGGNetInfo retrieves the Yggdrasil subnet configured on the host machine.
func GetHostYGGNetInfo() (*HostYggdrasilNetInfo, error) {
	conn, err := net.Dial("unix", "/var/run/yggdrasil.sock")
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	decoder := json.NewDecoder(conn)
	encoder := json.NewEncoder(conn)
	send := &admin.AdminSocketRequest{Name: "getSelf"}
	recv := &admin.AdminSocketResponse{}

	if err := encoder.Encode(&send); err != nil {
		return nil, err
	}
	if err := decoder.Decode(&recv); err != nil {
		return nil, err
	}
	if recv.Status == "error" {
		if recv.Error != "" {
			fmt.Println("Admin socket returned an error:", recv.Error)
		} else {
			fmt.Println("Admin socket returned an error but didn't specify any error text")
		}
		return nil, fmt.Errorf("admin socket returned an error")
	}

	var resp admin.GetSelfResponse
	if err := json.Unmarshal(recv.Response, &resp); err != nil {
		return nil, err
	}

	_, ipSubnet, err := net.ParseCIDR(resp.Subnet)
	if err != nil {
		return nil, err
	}
	ip := net.ParseIP(resp.IPAddress)

	bridgeSubnetIP := &net.IPNet{
		IP:   net.ParseIP(fmt.Sprintf("%s1", ipSubnet.IP.String())),
		Mask: ipSubnet.Mask,
	}

	hostYGGNet := &HostYggdrasilNetInfo{
		YGGIPAddr:     &net.IPNet{IP: ip, Mask: net.CIDRMask(128, 128)},
		YGGSubnetAddr: ipSubnet,
		BridgeYGGAddr: bridgeSubnetIP,
	}

	return hostYGGNet, nil
}
