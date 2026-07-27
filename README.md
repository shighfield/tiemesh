# Meshtastic terminal client (Free Pascal)

A console client for a Meshtastic radio, written in Object Pascal for the Free
Pascal Compiler (FPC / Lazarus). It talks to the radio over **serial (USB)**,
**WiFi (TCP)**, or optionally **Bluetooth LE**, and gives you a node list,
channels, direct messages, traceroute, and a clear‑screen‑but‑keep‑the‑log view.

## What "the radio" means here

The feature set you asked for — node list, direct messages, channels, traceroute
— is the Meshtastic client feature set, so this targets the **Meshtastic client
API**: a stream of `ToRadio` / `FromRadio` Protocol Buffers exchanged with the
device. The same protobuf protocol is used over serial, TCP and BLE.

## Files

| File | Purpose |
|------|---------|
| `tiemesh.pas` | The program: terminal UI, commands, message log |
| `meshclient.pas` | Node database, channels, handshake, send/dispatch logic |
| `meshtransport.pas` | Transport interface + serial & TCP transports + stream framing |
| `meshproto.pas` | Hand-rolled protobuf wire codec + Meshtastic messages |
| `meshble.pas` | Optional Linux/BlueZ BLE transport (opt-in, see below) |

## Build

Serial + TCP (works on Linux, Windows, macOS):

```
fpc tiemesh.pas
```

With the Linux BLE transport compiled in as well:

```
fpc -dMESH_BLE tiemesh.pas
```

### Cross-compiling for Windows from Linux

With the win64 RTL units installed (build them once from the FPC sources with
`make rtl packages OS_TARGET=win64 CPU_TARGET=x86_64`, then
`make rtl_install packages_install ... INSTALL_PREFIX=/usr`), it's just:

```
fpc -Twin64 tiemesh.pas
```

No MinGW needed — FPC links PE executables with its internal linker.

### Prebuilt Windows binary

`tiemesh.exe` in this repo is a prebuilt 64-bit Windows binary, cross-compiled
from the sources at the same commit. It's fully static — no DLLs or installer,
just run it from a terminal (`tiemesh.exe --serial COM5`, or `--tcp <ip>`).

It's provided as a convenience, but you should really build your own from the
source: it's one `fpc` command, you can read exactly what you're running, and
you're not trusting a binary blob someone committed to a git repo. It may also
lag behind the sources if a commit forgets to refresh it.

## Run

```
./tiemesh --serial /dev/ttyACM0        # Linux
tiemesh.exe --serial COM5              # Windows (COM number is in Device Manager)
./tiemesh --serial /dev/cu.usbmodem1   # macOS
./tiemesh --tcp 192.168.1.50           # radio on WiFi (default port 4403)
./tiemesh --tcp meshtastic.local:4403  # host:port form
./tiemesh --ble AA:BB:CC:DD:EE:FF      # only if built with -dMESH_BLE
```

For `--tcp` the radio must be on your network with WiFi enabled in its network
settings (e.g. a Heltec V3/V4, RAK, or T-Beam with WiFi configured via the
phone app); the firmware then listens on TCP port 4403. Note the device accepts
only **one** TCP client at a time, and a WiFi-connected radio switches off its
Bluetooth.

Add `--verbose` to also show the radio's debug console output. Add
`--baud <rate>` to override the serial speed (default 115200). Add `--show-ids`
to start with node ids shown alongside short names (see `/names` below). Add
`--hops <n>` to set the outgoing hop limit (default 3, max 7). In a BLE build, add
`--ble-adapter <hciN>` if your Bluetooth controller isn't `hci0`.

An incoming message rings the terminal bell (a DM rings twice, so you can tell
it apart without looking). Over SSH the bell sounds on **your** terminal, not
the remote machine. Silence it with `--no-bell` or the `/bell` command, or play
a sound file instead with e.g. `--bell-cmd "aplay ~/alert.wav"` (the command is
run in the background, so a slow or missing player never stalls the client).
If you hear nothing, check that your terminal's audible bell is enabled — many
terminals default to a visual bell or none at all.

The on-screen log is colourised using the CRT unit's 16-colour palette, one
colour per field: timestamps green, node names/ids cyan, DM/channel tags
magenta, message text light grey, hop counts dark grey, SNR values brown,
acknowledgements light blue, status/config lines yellow, and failed deliveries
red. (Colour goes through CRT's `TextColor` rather than raw ANSI escapes,
because the CRT unit runs the terminal in raw mode and does not pass embedded
escape codes through.) Pass `--no-colour` to disable it. The log **file** is
always written as plain text regardless, so it stays greppable.

`http://` and `https://` URLs in messages are emitted as OSC 8 terminal
hyperlinks, so they're clickable in terminals that support them (most modern
ones: GNOME Terminal, kitty, WezTerm, iTerm2, Windows Terminal, foot, …).
Because the CRT unit swallows escape codes, the hyperlink codes are written
straight to the terminal, bypassing CRT; the visible URL text still goes through
CRT so it keeps its colour. Terminals without OSC 8 support simply show the URL
as plain text.

## Commands

```
/nodes                 list known nodes
/channels              list channels
/dm <target> <text>    send a direct message
/trace <target>        run a traceroute
/info <target>         request telemetry (battery, voltage, uptime, sensors)
/whois <target>        ask a node to send its name (short/long)
/to <target>           set a default DM target (blank = broadcast)
/ch <index>            set the outgoing channel index (0..7)
/clear                 clear the screen (the log is kept)
/log                   replay this session's messages (colourised)
/log <n>               show the last n lines from the log file
/verbose               toggle device debug output
/capture               toggle silent capture of device debug to file
/confirm               toggle the send-confirmation prompt
/names                 toggle short names / short names with !ids
/hops [n]              show or set the outgoing hop limit (1..7)
/bell                  toggle the incoming-message sound
/quit                  disconnect and exit
<text>                 send text to the current target/channel
```

`<target>` may be a node id (`!aabbccdd`), a raw node number, `^all` for
broadcast, or a node's short/long name.

Nodes are displayed by their short name once the radio has learned it, falling
back to the `!aabbccdd` id for nodes that haven't sent a NodeInfo yet. `/log <n>`
re-resolves ids when replaying the file, so lines logged before a node's name was
known will show the name if it has been learned since. `/nodes` lists both the
short name and the id together. `/names` switches between short names alone
(`OO11`) and short names with their ids (`OO11 (!458f4727)`), which is useful
when two nodes share a short name. Start in the id-showing mode with
`--show-ids`.

`/whois <target>` asks a specific node to send its NodeInfo so its name is
learned on demand, rather than waiting for that node's next scheduled name
broadcast — handy for the many heard-but-unnamed nodes on a large mesh. Like
`/info`, it has no timeout and may get no reply: NodeInfo packets are longer
and less reliable than plain messages, and your radio already auto-requests a
name the first time it hears an unknown node, so `/whois` is essentially a
manual retry.

When you type a message (not a command) and press Enter, tiemesh asks you to
confirm before transmitting — it shows the destination (`channel N`, or `DM to
<node>`), and `Enter`/`y` sends while `n`/`Esc` cancels and restores the text for
editing. Toggle this off/on with `/confirm`.

Every message — incoming, outgoing, acknowledgements, traceroute replies — is
written to `~/tiemesh.log` in your home directory. `/log` on its own replays this
session's messages in colour; `/log <n>` reads the last n lines back from the
file, so it shows the full history across sessions (the file is appended to,
never truncated). `/clear` only wipes the visible screen. Lines replayed from the
file are plain text (as stored); live and session messages are colourised. The
radio's own debug console output is kept separate: it is discarded by default.
Under `--verbose`/`/verbose` it is shown on screen and written to
`~/tiemesh-debug.log` (ANSI colour codes stripped); `/capture` writes it to that
file **without** showing it on screen, for quietly recording a radio's console.
This keeps `/log` and `~/tiemesh.log` to actual messages rather than
device internals.

## Line editing and history

The input line supports in-place editing while you type:

- **Left / Right** — move the cursor within the line
- **Home / End** (also **Ctrl-A / Ctrl-E**) — jump to start / end
- **Backspace** — delete the character before the cursor
- **Delete** — delete the character at the cursor
- typing **inserts** at the cursor rather than only appending
- **Up / Down** — recall previous lines (last 12 kept for the session)

Editing assumes the input stays on a single screen row; a message long enough to
wrap to a second line may position the cursor imprecisely on the wrapped part.

## Deploying to a Raspberry Pi

`build-on-pi.sh` copies the sources to a Pi and builds them there over SSH (the
simplest route — the Pi compiles this in seconds, avoiding cross-toolchain
setup). It defaults to `dietpi@dietpi`; override with environment variables or
flags:

```
./build-on-pi.sh                 # copy + build on the Pi
./build-on-pi.sh --ble           # build with the BLE transport
./build-on-pi.sh --run           # build then launch on the Pi
PI_HOST=192.168.1.42 ./build-on-pi.sh
```

It checks that `fpc` is installed on the Pi, copies the units, `README.md`, and
`meshble.pas` (when present), and prints the run command. Serial access on the
Pi needs the login user in the `dialout` group.

## Protocol details this implementation relies on

These are the concrete facts the code is built on, with sources, so nothing here
is guesswork:

* **Stream framing.** On serial/TCP each protobuf is prefixed with a 4‑byte
  header: `0x94 0xC3` then a 16‑bit big‑endian length (max 512). Bytes that
  aren't a valid frame are the device's debug console text. — Meshtastic
  *Client API (Serial/TCP/BLE)* and *Python* docs.
* **Serial speed** for the client API is fixed at **115200 8N1** (this is
  separate from the "Serial Module", which defaults to 38400). — Meshtastic
  Python `SerialInterface`.
* **Handshake.** On connect the client sends `ToRadio.want_config_id` (field 3)
  with a random nonce; the radio streams `my_info`, `node_info`s, config and
  `channel`s, then `FromRadio.config_complete_id` (field 7) echoing the nonce.
* **Encryption is handled by the device.** Software outside the radio only sees
  packets whose `decoded` (`Data`) field is already populated; the device
  decrypts on receive and encrypts on send. This client never needs the PSK. —
  Meshtastic Client API docs.
* **Keep-alive heartbeat.** The radio stops streaming packets to a serial/TCP/BLE
  client that goes quiet, so the client must periodically send a
  `ToRadio.heartbeat` (field 7). The firmware describes this message as used to
  keep the connection awake on serial, and the official Python client sends one
  every 300s. This client sends one every 120s from `Poll`. Without it, config
  succeeds but no live messages ever arrive.
* **Hop limit.** Outgoing packets always carry a hop limit, because a
  phone-originated *direct* packet with hop_limit 0 is never relayed and only
  reaches direct neighbours (so `/dm` and `/info` to a multi-hop node would
  fail). The default is 3 (the Meshtastic default); set it with `--hops <n>` or
  the `/hops` command, up to the maximum of 7. Note the trade-off: a higher hop
  limit reaches further but adds mesh traffic, and some operators configure
  their routers to drop high-hop packets — which can prevent your broadcasts
  from being rebroadcast and therefore stop the implicit ACK for public
  messages. If public messages stop showing "acknowledged", try a lower value.
* **Field numbers used** (from `mesh.proto`, `portnums.proto`, `channel.proto`):
  `ToRadio.packet=1, want_config_id=3, disconnect=4, heartbeat=7`;
  `FromRadio.id=1, packet=2, my_info=3, node_info=4, config_complete_id=7, channel=10`;
  `MeshPacket.from=1(fixed32), to=2(fixed32), channel=3, decoded=4, encrypted=5, id=6(fixed32), rx_time=7, rx_snr=8(float), hop_limit=9, want_ack=10, rx_rssi=12, hop_start=15`;
  `Data.portnum=1, payload=2, want_response=3, dest=4, source=5, request_id=6, reply_id=7`;
  `NodeInfo.num=1, user=2, position=3, snr=4, last_heard=5, device_metrics=6, channel=7, hops_away=9, is_favorite=10`;
  `User.id=1, long_name=2, short_name=3, hw_model=5`;
  `Channel.index=1, settings=2, role=3`; `ChannelSettings.name=3`;
  `RouteDiscovery.route=1(fixed32,packed), snr_towards=2(int32,packed), route_back=3, snr_back=4`.
* **PortNums:** text=1, position=3, nodeinfo=4, routing=5, telemetry=67, traceroute=70.
* **Telemetry** (`telemetry.proto`): `Telemetry.time=1, device_metrics=2, environment_metrics=3`;
  `DeviceMetrics.battery_level=1, voltage=2, channel_utilization=3, air_util_tx=4, uptime_seconds=5`.
  `/info` sends a `Telemetry` with an empty `device_metrics` and `want_response=true`.
* **Traceroute** sends an empty `RouteDiscovery` on port 70 with
  `want_response=true`; the reply carries the completed route. SNR values in a
  RouteDiscovery are stored as dB×4 (the UI divides by 4).

The encoder was checked against a real captured "Hello" broadcast
(`0a 17 15 ff ff ff ff 22 09 08 01 12 05 48 65 6c 6c 6f 35 5b 06 ec 94 50 01`),
which decodes exactly to this field layout.

## Honest caveats

* **Serial build confirmed to compile and run** on Linux FPC. On Unix the
  program pulls in `cthreads` first (handled automatically in `tiemesh.pas`)
  so the background reader thread works; without it FPC aborts with runtime
  error 232 ("no thread support compiled in"). It targets standard FPC/Lazarus
  units (`Serial`, `Crt`, `Classes`, `SyncObjs`).
* **The TCP transport reuses the serial stream framer** and was verified against
  a mock server (correct framing and `want_config` handshake on the wire); it
  has had less soak time against real radios than the serial path.
* **The Windows build is cross-compiled and smoke-tested under Wine** (argument
  parsing and all exit paths), not yet on real Windows hardware with a radio.
* **BLE is Linux/BlueZ‑only, opt‑in, and untested on hardware.** `meshble.pas`
  uses BlueZ over D‑Bus and is only compiled with `-dMESH_BLE`. It requires the
  radio to be paired/trusted first (`bluetoothctl`). It polls the `FromRadio`
  characteristic (the documented drain model) rather than subscribing to
  `FromNum` notifications, to keep it to plain D‑Bus method calls. If GATT
  auto‑discovery misbehaves you can construct `TBLETransport.CreatePaths` with
  explicit characteristic object paths. The **serial path is the validated
  design**; BLE is a working scaffold that needs verification on your device.
* **Serial DTR/RTS.** Opening a serial port can toggle DTR/RTS, which reboots
  some ESP32 boards. The client's `want_config` handshake recovers from a reboot
  automatically, so at worst you'll see a brief reconnect.
* **Little‑endian host assumed** for `fixed32`/`float` decoding (covers x86/ARM).
