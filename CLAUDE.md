# yggoverlay-cni-plugin

A CNI chained plugin that assigns each container a deterministic Yggdrasil IPv6 address derived from its hostname. It must run after the `bridge` plugin in a conflist.

## Architecture

```
Host machine
├── yggdrasil daemon  (socket: /var/run/yggdrasil.sock)
├── bridge (man8br0)  ← plugin adds BridgeYGGAddr (subnet::1/64)
└── container veth pair
    └── container netns
        ├── ygg addr added to veth (subnet::<sha256_suffix>/64, NOPREFIXROUTE)
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

## Build & test

```bash
make build                         # produces ./out/yggoverlay
sudo cp out/yggoverlay /opt/cni/bin/yggoverlay

# helper: compute ygg address for a hostname
./out/yggoverlay getsuffix <hostname>

# integration test with nerdctl
nerdctl run -it --network=man8br --hostname test-alpine-1 --name test-alpine-1 alpine
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

The bridge plugin's `ipam.ranges` must include the Yggdrasil subnet so the container gets a regular IPv6 address (used as internet-access source); the ygg address is added on top via policy routing.

## Address derivation

`EncodeContainerNameToYGGAddr(prefix, hostname)` in `name2yggaddr.go`:
1. SHA-256 hash the hostname
2. Take the low `(128 - prefixLen)` bits as the suffix
3. OR with the prefix

This produces a stable address across container restarts as long as the hostname and host Yggdrasil subnet don't change.

## Known issues / TODO

### Remaining bugs in `addyggtoiface.go` (to be fixed separately)

**1. No idempotency**
`AddrAdd`, `RouteAdd`, `RuleAdd` all fail with `EEXIST` if called twice. The bridge-side `ensureAddr` in `main.go` does handle this. The container-side equivalents should too (check-then-add, or ignore `syscall.EEXIST`).

**2. Retry only on `route1`, not `route2` or `AddrAdd`**
The 10-attempt retry loop guards against the address being in DAD "tentative" state, but only wraps `route1`. `AddrAdd` itself and `route2` have no retry. If DAD delays matter, the address add should either set `IFA_F_NODAD` or the retry should cover all three operations.

### Minor / cosmetic

- `cmdCheck` always returns `nil` — should verify the ygg address and routes are present.
- `/* FIXME GC */` — the GarbageCollect handler is unimplemented.
