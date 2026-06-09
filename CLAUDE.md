# yggoverlay-cni-plugin

A CNI chained plugin that assigns each container a deterministic Yggdrasil IPv6 address derived from its hostname. It must run after the `bridge` plugin in a conflist.

## Architecture

```
Host machine
├── yggdrasil daemon  (socket: /var/run/yggdrasil.sock)
├── bridge (man8br0)  ← plugin adds BridgeYGGAddr (subnet::1/64)
└── container veth pair
    └── container netns
        ├── ygg addr added to veth (subnet::<sha256_suffix>/64, NOPREFIXROUTE|NODAD)
        ├── table 199: subnet/64 dev veth  (direct)
        ├── table 199: 200::/7 via subnet::1 src <ygg_addr>
        └── ip rule: to 200::/7 lookup 199 priority 100
```

## Package layout

| File | Responsibility |
|---|---|
| `main.go` | CNI entry point; `cmdAdd` / `cmdDel` / `cmdCheck` / `cmdStatus` |
| `yggoverlay/ygginfo.go` | Queries Yggdrasil admin socket (`getSelf`) to get host IP, subnet, and bridge addr |
| `yggoverlay/name2yggaddr.go` | Deterministic SHA-256 hostname → IPv6 suffix mapping |
| `yggoverlay/addyggtoiface.go` | Configures ygg addr, routes, and policy rule inside container netns |
| `yggoverlay/rmyggfromiface.go` | Reverses the above on container deletion |
| `scripts/test-e2e.sh` | End-to-end and parallel stress tests |

## Build & test

```bash
make build                         # produces ./out/yggoverlay
sudo cp out/yggoverlay /opt/cni/bin/yggoverlay

make test-e2e                      # build + install + run all e2e/stress tests (requires sudo)

# Tunable env vars for test-e2e:
#   NETWORK=man8yggbr  PARALLEL=5  CYCLES=4  SKIP_V4ONLY=0

# helper: compute ygg address for a hostname
./out/yggoverlay getsuffix <hostname>
```

## CNI configuration (conflist)

The plugin must appear **after** the `bridge` plugin. It needs no mandatory config fields; optional fields:

```json
{
  "type": "yggoverlay",
  "yggTablePriority": 100,
  "yggTableID": 199
}
```

### IPv4+IPv6 mode

Include the host's Yggdrasil subnet in `ipam.ranges`. The container gets a regular IPv6 address for public internet (its default IPv6 route `src` is fixed to that address), plus the ygg address for Yggdrasil connectivity.

### IPv4-only mode

Omit any IPv6 subnet from `ipam.ranges`. The plugin still adds the ygg address and table 199 policy routing; it silently skips the IPv6 default route `src` fixup. The container can reach `200::/7` (Yggdrasil) but has no global IPv6 routes.

## Hostname derivation

The plugin reads the container hostname from `CNI_ARGS`:
1. `NERDCTL_CNI_DHCP_HOSTNAME` — set by nerdctl when `--hostname` is used
2. `K8S_POD_NAMESPACE` — fallback for podman / Kubernetes environments

If neither is present, ADD fails with an error.

## Address derivation

`EncodeContainerNameToYGGAddr(prefix, hostname)` in `name2yggaddr.go`:
1. SHA-256 hash the hostname
2. Take the low `(128 - prefixLen)` bits as the suffix
3. OR with the prefix

This produces a stable address across container restarts as long as the hostname and host Yggdrasil subnet don't change.

## Idempotency

All three netlink operations in `ConfigYGGOverlayNetwork` tolerate `EEXIST`:
- `AddrAdd` — carries `IFA_F_NODAD` (address immediately usable, no DAD wait) and `IFA_F_NOPREFIXROUTE` (no auto-connected route)
- `RouteAdd` (route1: direct subnet, route2: 200::/7 via gateway)
- `RuleAdd` (to 200::/7 lookup tableID)

The bridge-side `ensureAddr` in `main.go` checks before adding.

## Known issues / TODO

- `cmdCheck` always returns `nil` — should verify the ygg address and routes are present.
- `/* FIXME GC */` — the GarbageCollect handler is unimplemented.
