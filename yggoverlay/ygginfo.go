package yggoverlay

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"

	"github.com/yggdrasil-network/yggdrasil-go/src/admin"
)

type HostYggdrasilNetInfo struct {
	YGGIPAddr     *net.IPNet // host's Yggdrasil IP address, e.g., 200:xx:yy:zz::aa/128
	YGGSubnetAddr *net.IPNet // subnet address, the rest is all zero. E.g., 300:xx::/64
	BridgeYGGAddr *net.IPNet // network address for srvgrp0 bridge interface, it has a '1' in the last segment. E.g., 300:xx:yy:zz::1/64
}

var yggdrasilSockPaths = []string{
	"/var/run/yggdrasil.sock",
	"/run/yggdrasil/yggdrasil.sock",
}

func getInfoFromSocket(sockPath string) (address, subnet string, err error) {
	conn, err := net.Dial("unix", sockPath)
	if err != nil {
		return "", "", err
	}
	defer conn.Close()

	decoder := json.NewDecoder(conn)
	encoder := json.NewEncoder(conn)
	send := &admin.AdminSocketRequest{Name: "getSelf"}
	recv := &admin.AdminSocketResponse{}

	if err := encoder.Encode(&send); err != nil {
		return "", "", err
	}
	if err := decoder.Decode(&recv); err != nil {
		return "", "", err
	}
	if recv.Status == "error" {
		if recv.Error != "" {
			fmt.Fprintln(os.Stderr, "Admin socket returned an error:", recv.Error)
		} else {
			fmt.Fprintln(os.Stderr, "Admin socket returned an error but didn't specify any error text")
		}
		return "", "", fmt.Errorf("admin socket returned an error")
	}

	var resp admin.GetSelfResponse
	if err := json.Unmarshal(recv.Response, &resp); err != nil {
		return "", "", err
	}

	return resp.IPAddress, resp.Subnet, nil
}

type yggdrasilctlSelfInfo struct {
	Address string `json:"address"`
	Subnet  string `json:"subnet"`
}

func getInfoFromCLI() (address, subnet string, err error) {
	out, err := exec.Command("yggdrasilctl", "-json", "getself").Output()
	if err != nil {
		return "", "", fmt.Errorf("yggdrasilctl failed: %w", err)
	}
	var info yggdrasilctlSelfInfo
	if err := json.Unmarshal(out, &info); err != nil {
		return "", "", fmt.Errorf("failed to parse yggdrasilctl output: %w", err)
	}
	if info.Address == "" || info.Subnet == "" {
		return "", "", fmt.Errorf("yggdrasilctl output missing address or subnet fields")
	}
	return info.Address, info.Subnet, nil
}

// GetHostYGGNetInfo retrieves the Yggdrasil subnet configured on the host machine.
// It tries unix sockets first, then falls back to yggdrasilctl CLI.
func GetHostYGGNetInfo() (*HostYggdrasilNetInfo, error) {
	var address, subnet string
	var sockErrors []error

	for _, sockPath := range yggdrasilSockPaths {
		var err error
		address, subnet, err = getInfoFromSocket(sockPath)
		if err == nil {
			break
		}
		sockErrors = append(sockErrors, fmt.Errorf("%s: %w", sockPath, err))
	}

	if address == "" {
		var cliErr error
		address, subnet, cliErr = getInfoFromCLI()
		if cliErr != nil {
			return nil, fmt.Errorf("all yggdrasil info sources failed — sockets: %v, cli: %w", sockErrors, cliErr)
		}
	}

	_, ipSubnet, err := net.ParseCIDR(subnet)
	if err != nil {
		return nil, err
	}
	ip := net.ParseIP(address)

	bridgeIP := make(net.IP, 16)
	copy(bridgeIP, ipSubnet.IP.To16())
	bridgeIP[15] = 1
	bridgeSubnetIP := &net.IPNet{
		IP:   bridgeIP,
		Mask: ipSubnet.Mask,
	}

	return &HostYggdrasilNetInfo{
		YGGIPAddr:     &net.IPNet{IP: ip, Mask: net.CIDRMask(128, 128)},
		YGGSubnetAddr: ipSubnet,
		BridgeYGGAddr: bridgeSubnetIP,
	}, nil
}
