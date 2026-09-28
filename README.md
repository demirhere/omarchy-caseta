# Caseta Lights

Control Lutron Caseta lights, switches, fans and scenes from the Omarchy bar.
Talks to the Smart Bridge directly over its local LEAP API (TLS on port 8081);
nothing goes through Lutron's cloud.

## Install

```sh
omarchy plugin add https://github.com/demirhere/omarchy-caseta.git --enable
```

Then open the bulb icon in the bar and click **Pair bridge**, or run:

```sh
~/.config/omarchy/plugins/io.github.demirhere.caseta/bin/caseta-setup [bridge-ip]
```

Setup runs in a terminal and never needs root. It:

1. creates a private Python venv and installs
   [pylutron-caseta](https://github.com/gurumitts/pylutron-caseta) 0.29.0 from
   PyPI (this is the only download);
2. finds the bridge over mDNS with `avahi-browse`, or asks for its IP;
3. asks you to press the small black button on the back of the bridge, which
   issues a client certificate for this machine.

Requirements: a Caseta Smart Bridge or Smart Bridge Pro on the same network,
`python3` with the `venv` module, and `avahi-browse` for discovery (optional).

| Path | Contents |
|------|----------|
| `~/.local/share/omarchy-caseta/venv` | Python venv with pylutron-caseta |
| `~/.config/omarchy-caseta/` | Bridge address + client certificate/key (dir mode 700, key mode 600) |
| `~/.local/state/omarchy-caseta/last-levels.json` | Last brightness per dimmer, so "on" restores it |

If DHCP moves the bridge, the helper finds it again by MAC address.

## Usage

Bar icon: left click opens the panel; right click toggles the pinned light (or
turns everything off / back on when nothing is pinned); scroll dims the pinned
light.

Panel: lights are grouped by room. Dimmers, fans (5 speeds) and shades get a
slider; switches get a toggle. The header switch turns every light off and, when
flipped back, restores exactly the lights that were on.

| Key | Action |
|-----|--------|
| `j` / `k` | Move |
| `h` / `l` | Dim / brighten 10% (fan speed down / up) |
| `1`–`9`, `0` | Jump to 10–90%, 100% |
| `Enter` / `Space` | Toggle light / run scene |
| `p` | Pin the light to the bar icon |
| `a` | All off / restore |
| `r` | Reconnect |
| `Esc` | Close |

## Keybindings and scripts

The service registers a `caseta` IPC target. Devices match by id, "Area Name",
a unique name, or a substring.

```sh
omarchy-shell caseta toggle "Office"
omarchy-shell caseta set "Living Room Floor Lamp" 40
omarchy-shell caseta turnOn "Kitchen"
omarchy-shell caseta turnOff "Kitchen"
omarchy-shell caseta scene "Movie Night"
omarchy-shell caseta allOff
omarchy-shell caseta restore
omarchy-shell caseta list      # JSON: state, devices, scenes
omarchy-shell caseta status
```

## How it works

`Service.qml` runs `bin/caseta-bridge daemon` once per shell. The helper holds a
single LEAP connection, pushes zone changes (including physical switch presses)
as JSON lines, and takes commands on stdin. Rapid slider moves are coalesced per
device so the bridge only sees the latest level.

## Remove

```sh
omarchy plugin disable io.github.demirhere.caseta
rm -rf ~/.config/omarchy/plugins/io.github.demirhere.caseta ~/.config/omarchy-caseta \
  ~/.local/share/omarchy-caseta ~/.local/state/omarchy-caseta
```

The bridge keeps the paired certificate until it is factory reset.
