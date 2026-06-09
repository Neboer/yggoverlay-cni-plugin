# yggoverlay-cni-plugin

CNI plugin for containerd to manage Yggdrasil overlay network for VPN connection between containers.

## Usage

First, create the bridge CNI config at `/etc/cni/net.d/30-man8br0.conflist`:

```json
{
  "cniVersion": "1.0.0",
  "name": "man8yggbr",
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
          { "dst": "0.0.0.0/0" },
          { "dst": "2000::/3" }
        ],
        "ranges": [
          [{ "subnet": "10.4.0.0/24" }],
          [{
            "subnet": "3ffe:ffff:0:01ff::/64",
            "rangeStart": "3ffe:ffff:0:01ff::0010",
            "rangeEnd":   "3ffe:ffff:0:01ff::ffff"
          }]
        ]
      }
    },
    {
      "type": "yggoverlay"
    }
  ]
}
```

Replace `3ffe:ffff:0:01ff::/64` with your actual Yggdrasil subnet (the one assigned to this host by `getSelf`).

Then start a container:

```bash
nerdctl run -i -t --network=man8yggbr --hostname test-alpine-1 --name test-alpine-1 alpine:latest
```

The container receives a regular IPv6 address from the IPAM range (for public internet), plus a deterministic Yggdrasil address derived from its hostname (for ygg VPN connectivity).

### IPv4-only variant

Omit the IPv6 subnet from `ipam.ranges`. The plugin still adds the ygg address and policy routing, but skips the IPv6 default route fixup. The container can reach Yggdrasil space (`200::/7`) but has no global IPv6 access.

```json
{
  "cniVersion": "1.0.0",
  "name": "man8yggbr",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "man8br0",
      "isGateway": true,
      "ipMasq": true,
      "ipam": {
        "type": "host-local",
        "routes": [{ "dst": "0.0.0.0/0" }],
        "ranges": [[{ "subnet": "10.4.0.0/24" }]]
      }
    },
    { "type": "yggoverlay" }
  ]
}
```

## What it does

This CNI plugin runs **after** the bridge plugin and configures a Yggdrasil overlay network for the container:

1. **Bridge address** — assigns `subnet::1/64` to the host bridge as the Yggdrasil gateway.
2. **Container address** — computes a deterministic address from the container hostname via SHA-256, adds it to the container veth with `NOPREFIXROUTE` and `NODAD` (immediately usable, no DAD delay).
3. **Policy routing** — inside the container, adds a routing table (default ID 199) with:
   - A direct route for the Yggdrasil subnet via the container veth.
   - A route for `200::/7` (all Yggdrasil space) via `subnet::1` with the container's Yggdrasil address as source.
   - An `ip rule` (default `priority 100`) to use table 199 for traffic to `200::/7`.
4. **IPv6 default route fixup** (IPv4+IPv6 mode only) — sets the source address of the container's existing IPv6 default route to its IPAM-assigned IPv6 address, so public internet IPv6 traffic uses that address rather than the ygg address.

All three netlink operations (`AddrAdd`, `RouteAdd`, `RuleAdd`) are idempotent — `EEXIST` is silently ignored. This means the plugin handles repeated ADD calls gracefully.

## Address derivation

The Yggdrasil address for a container is deterministic: `SHA-256(hostname)` low bits are OR'd with the host's Yggdrasil subnet prefix. The address is stable across container restarts as long as the hostname and the host's Yggdrasil subnet don't change.

```bash
# Preview the address that would be assigned to a given hostname:
./out/yggoverlay getsuffix <hostname>
```

## Optional config fields

```json
{
  "type": "yggoverlay",
  "yggTablePriority": 100,
  "yggTableID": 199
}
```

| Field | Default | Description |
|---|---|---|
| `yggTablePriority` | 100 | `ip rule` priority for the Yggdrasil policy routing rule |
| `yggTableID` | 199 | Routing table ID used for Yggdrasil routes |

## How to build

```bash
make build
./out/yggoverlay --version
sudo cp out/yggoverlay /opt/cni/bin/yggoverlay
```

## Requirements

- A running Yggdrasil daemon with its admin socket at `/var/run/yggdrasil.sock`.
- The bridge plugin must appear **before** `yggoverlay` in the conflist.
- Container must be started with `--hostname` set; the Yggdrasil address is derived from it.
- `CAP_NET_ADMIN` privileges (standard for CNI plugins).
