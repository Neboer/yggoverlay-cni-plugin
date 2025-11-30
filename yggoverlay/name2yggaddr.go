package yggoverlay

import (
	"crypto/sha256"
	"fmt"
	"math/big"
	"net"
)

// EncodeContainerNameToYGGAddr
// 输入 IPv6 前缀 (net.IPNet) 和字符串，输出同前缀长度的 IPv6 地址 (net.IPNet)
func EncodeContainerNameToYGGAddr(prefix *net.IPNet, src string) (*net.IPNet, error) {
	if prefix.IP.To16() == nil {
		return nil, fmt.Errorf("prefix is not a valid IPv6 network")
	}

	ones, bits := prefix.Mask.Size()
	if bits != 128 {
		return nil, fmt.Errorf("prefix mask must be IPv6 (128 bits)")
	}

	// 前缀长度
	prefixLen := ones
	remainingBits := 128 - prefixLen

	// ========== prefix_int ==========
	prefixInt := new(big.Int).SetBytes(prefix.IP)

	// ========== SHA256 哈希 ==========
	hash := sha256.Sum256([]byte(src))
	hashInt := new(big.Int).SetBytes(hash[:])

	// ========== suffix ==========
	// suffix = last remainingBits bits of hashInt
	mask := new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), uint(remainingBits)), big.NewInt(1))
	suffix := new(big.Int).And(hashInt, mask)

	// ========== 拼接 full IPv6 integer ==========
	// 清空 prefixInt 的低 remainingBits 位
	prefixClearMask := new(big.Int).Not(mask)
	full := new(big.Int).And(prefixInt, prefixClearMask)
	full = full.Or(full, suffix)

	// 转回 net.IP
	ipBytes := full.Bytes()

	// 需要确保是 16 字节
	if len(ipBytes) < 16 {
		padding := make([]byte, 16-len(ipBytes))
		ipBytes = append(padding, ipBytes...)
	}

	ip := net.IP(ipBytes)

	// 构造新的 IPNet，保留原 Mask
	return &net.IPNet{
		IP:   ip,
		Mask: prefix.Mask,
	}, nil
}
