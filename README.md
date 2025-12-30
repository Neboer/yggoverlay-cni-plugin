# yggoverlay-cni-plugin

CNI plugin for containerd to manage yggdrasil overlay network for VPN connection between containers

## Usage

first, create man8br config

/etc/cni/net.d/30-man8br0.conflist
```json
{
  "cniVersion": "1.0.0",
  "name": "man8br",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "man8br0",
      "isGateway": true,
      "ipMasq": true,
      "ipMasqBackend": "nftables",
      "ipam": {
        "type": "host-local",
        "routes": [
          {
            "dst": "0.0.0.0/0"
          },
          {
            "dst": "2000::/3"
          }
        ],
        "ranges": [
          [
            {
              "subnet": "10.4.0.0/24"
            }
          ],
          [
            {
              "subnet": "3ffe:ffff:0:01ff::/64",
              "rangeStart": "3ffe:ffff:0:01ff::0010",
              "rangeEnd": "3ffe:ffff:0:01ff::ffff"
            }
          ]
        ]
      }
    },
    {
      "type": "yggoverlay"
    }
  ]
}
```

then, create container via command like this

```bash
nerdctl run -i -t --network=man8br --hostname test-alpine-1 --dns xxx --name test-alpine-1 alpine:latest
```

and then the container will be added to a bridge and assigned a yggdrasil address.

## What does it do

This CNI-like plugin configures a "ygg" network for containers. It must run after the bridge plugin (so the bridge and container veth exist). IPv4 and IPv6 routing are supported; IPv6 is optional and described below.

Behavior (high-level)
- Compute the container's ygg address suffix deterministically from the container name (hostname). Example approach: hash the hostname (e.g. SHA-256 or FNV-1a) and use the low-order bits to form the address suffix (keeps addresses stable across restarts).
- Talk to the host ygg admin socket to request the assigned ygg address and the ygg subnet for the host.
- Add the host-side bridge address for the ygg subnet: use the subnet plus ::1 as the bridge/gateway address (e.g. for prefix 300:0:0:1::/64 the bridge addr is 300:0:0:1::1).
- On the container interface, create a separate routing table (table number 199, named "ygg" conceptually) and add policy routing rules so ygg routes are used with priority.
- Change container's default IPv6 2000::/3 public internet access route's srcaddr as container's source address, to seperate its ipv6 internet connection from its ygg access.
- Populate table 199 with:
  - A directly-connected route for the ygg prefix (e.g. 300:0:0:1::/64) via the host-side link (host0), using normal neighbor/link resolution.
  - A route that sends traffic to the 200::/7 range via the host ygg gateway (300:0:0:1::1) with the container source address set to the container's ygg address (e.g. 300:0:0:1::100). NAT may be applied at the host if needed, but avoid NAT when possible for performance.

Example ip(8) commands (IPv6 examples)
- Add host bridge address (run on host):
  ip -6 addr add 300:0:0:1::1/64 dev br0
- Add policy rule on container to prefer table 199 (high priority):
  ip -6 rule add to 300:0:0:1::/64 lookup 199 priority 100
- Add table 199 routes (inside container or configured via netlink):
  ip -6 route add 300:0:0:1::/64 dev host0 table 199
  ip -6 route add 200::/7 via 300:0:0:1::1 src 300:0:0:1::100 table 199

Notes & gotchas
- Must run after the bridge plugin so the bridge device and the container veth are present.
- Requires CAP_NET_ADMIN and privileges to modify host and container network state.
- Ensure idempotency: check whether addresses, rules, and routes already exist before adding.
- Host link name (host0) or bridge name may vary; discover these dynamically from the container's veth pair.
- Decide and document the deterministic mapping algorithm from hostname -> suffix to avoid address collisions.
- IPv4 can follow the same pattern (parallel table and rules) if you need dual-stack; IPv6 can be made optional.