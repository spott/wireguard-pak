# Wireguard.pak

A [MinUI](https://github.com/shauninman/MinUI) and [NextUI](https://github.com/LoveRetro/NextUI) pak wrapping [WireGuard](https://www.wireguard.com/), a fast and modern VPN.

This pak uses the userspace [`wireguard-go`](https://git.zx2c4.com/wireguard-go/) implementation, since the stock TrimUI kernel ships without in-kernel WireGuard support. Only `CONFIG_TUN=y` is required, which the kernel provides.

## Requirements

This pak is designed for the following MinUI platforms and devices:

- `tg5040`: TrimUI Brick (formerly `tg3040`), TrimUI Smart Pro

The pak may work on other platforms, but it has only been tested on the Brick.

## Installation

1. Mount your MinUI SD card.
2. Download the latest release from GitHub. It will be named `Wireguard.pak.zip`.
3. Copy the zip into the `/Tools/tg5040` directory on the SD card (use the platform folder that matches your device).
4. Extract the zip in place, then delete the zip file.
5. Confirm that there is a `Wireguard.pak/launch.sh` file on your SD card.

## WireGuard Config

To bring the tunnel up, the pak needs a standard `wg0.conf` file.

1. On any machine, generate or obtain a WireGuard client configuration. A minimal example:

   ```ini
   [Interface]
   PrivateKey = <your-private-key>
   Address    = 10.0.0.2/32
   DNS        = 10.0.0.1

   [Peer]
   PublicKey  = <server-public-key>
   Endpoint   = vpn.example.com:51820
   AllowedIPs = 10.0.0.0/24
   PersistentKeepalive = 25
   ```

2. Name the file exactly `wg0.conf` and copy it to the **root of your MinUI SD card** (the same level as `MinUI.zip`, *not* inside `Tools/`).
3. Unmount the SD card and insert it into your MinUI device.

On the first `Enable`, the pak moves `wg0.conf` from the SD card root into the pak's userdata directory (`$USERDATA_PATH/Wireguard/wg0.conf`, mode `0600`) and removes the SD card copy — FAT32 has no permissions, so leaving your private key there is a footgun. Replace the SD card copy at any time to rotate the config.

### Routing

`AllowedIPs` is honored per peer for any CIDR *other than* `0.0.0.0/0` and `::/0`. v0.1 deliberately ignores default-route entries — full-tunnel VPN tends to be a footgun on a handheld, and we haven't built a UI toggle yet.

### DNS

If your config contains a `DNS =` line in the `[Interface]` section, `/etc/resolv.conf` is replaced with the listed nameservers (and any search domains) when the tunnel comes up, and the original file is restored when the tunnel goes down. Omit `DNS =` if you want to keep the system DNS.

**Known limitation (v0.1):** MinUI uses a plain `/etc/resolv.conf` with no resolvconf/systemd-resolved layer. If Wi-Fi reconnects mid-session, the system may rewrite `/etc/resolv.conf` and clobber the VPN DNS. Toggle the pak off and on again to restore it. This will be addressed in a future release.

## Usage

Browse to `Tools > Wireguard` and press `A` to enter the pak.

### Start / Stop

You can start or stop WireGuard from the pak's main menu. When the tunnel is running, the menu shows the daemon PID, the assigned `wg0` IPv4 address, and the most recent peer endpoint to have completed a handshake.

### Start on Boot

Enable `Start on boot` from the pak menu to bring the tunnel up automatically when the device powers on. The on-boot script waits up to 30 seconds for Wi-Fi to associate (a default route to appear) before attempting to connect; if it gives up, it logs and exits cleanly.

## Debug Logging

Logs are written under `$SDCARD_PATH/.userdata/$PLATFORM/logs/`:

- `Wireguard.txt` — main pak (the Tools entry session)
- `Wireguard.on-boot.txt` — on-boot startup

## On-device verification

```sh
# Confirm in-kernel WireGuard is absent (so the userspace path is needed)
zcat /proc/config.gz | grep -E 'WIREGUARD|^CONFIG_TUN'

# After Enable:
ip link show wg0          # interface present
wg show wg0               # peer info, handshakes, transfer counters
ping <peer-vpn-ip>        # tunnel works end-to-end
```

## Building from source

The pak's binaries (`wireguard-go`, `wg`) are cross-compiled from source via Nix. With [Nix](https://nixos.org/download.html) installed and flakes enabled:

```sh
make build      # downloads minui-list/minui-presenter/jq, builds wireguard-go and wg via nix
make release    # produces dist/Wireguard.pak.zip
```

## Acknowledgements

- [minui-tailscale](https://github.com/ben16w/minui-tailscale) by [Ben Wadsworth](https://github.com/ben16w), whose pak structure this project mirrors directly.
- [MinUI](https://github.com/shauninman/MinUI) by [Shaun Inman](https://github.com/shauninman).
- [NextUI](https://github.com/LoveRetro/NextUI) by [@ro8inmorgan](https://github.com/ro8inmorgan), [@frysee](https://github.com/frysee), and the rest of the NextUI contributors.
- [minui-list](https://github.com/josegonzalez/minui-list) and [minui-presenter](https://github.com/josegonzalez/minui-presenter) by [Jose Diaz-Gonzalez](https://github.com/josegonzalez).
- [WireGuard](https://www.wireguard.com/) by Jason A. Donenfeld and contributors.

## License

This project is released under the MIT License. See [LICENSE](LICENSE) for details.
