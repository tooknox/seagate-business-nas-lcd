# Seagate XBig front-panel protocol

`seagate-xbig-frontpanel` is the hardware process for the Seagate Business
Storage Windows Server 4-bay NAS front panel (MSS0731 family).

The process owns the Fintek GPIO lines for its entire lifetime. A UI talks to it
through ordinary **stdin/stdout text pipes**. Bash may use `coproc`; Python may
use `subprocess`; any other language only needs a child process with two pipes.
There is no socket, daemon registration, or UI-specific dependency.

## Requirements

- Linux with `gpio-f7188x` loaded.
- libgpiod **2.x** runtime (`libgpiod.so.3`; Debian 13 package `libgpiod3`).
- Permission to open the matching `/dev/gpiochip*` devices (normally root on
  this NAS).
- The GPIO chips must have labels `gpio-f7188x-4` and `gpio-f7188x-7`.

The hardware process discovers the gpiochip device numbers by label; callers do
not need to know them.

## Transport

One ASCII command per line is written to stdin. One reply/event per line is
written to stdout. The process flushes stdout after every line.

LCD text is byte-oriented. Printable ASCII `0x20..0x7e` is preserved; other
bytes are displayed as spaces. `LINE` truncates to 16 characters and pads the
remainder with spaces. Every `LINE` command is written to the LCD, even if it is
identical to the previous text. The hardware process intentionally does not
track displayed row contents; duplicate-write suppression is UI policy.

Diagnostic/log text goes to stderr and is not part of the protocol.

## Startup

On successful hardware acquisition the process writes:

```text
READY 1.0
```

If startup fails it writes an error and exits non-zero, for example:

```text
ERROR FATAL cannot find gpio-f7188x-7 (load gpio-f7188x)
```

A normal client should wait for `READY 1.0`, then send `INIT` before writing
LCD text.

## Commands

### `INIT`

Initializes the HD44780-compatible LCD with the recovered Seagate sequence:

```text
0x38 0x38 0x0c 0x01 0x06
```

The values are controller commands (RS=0), not displayed characters:

- `0x38` — Function Set: 8-bit D0..D7 interface, two-line mode, 5x8 font.
  Seagate sends it twice; this implementation preserves that known-good sequence exactly.
- `0x0c` — Display Control: display on, cursor off, blink off.
- `0x01` — Clear Display and return the address/cursor home.
- `0x06` — Entry Mode: advance after each character without shifting the display.

The hardware process waits 1 ms after each byte, matching the recovered Windows
implementation.

Reply:

```text
OK INIT
```

### `LINE <0|1> <text>`

Writes and pads one complete 16-character line. Line numbers are zero-based.
The text is the entire remainder of the command after the line number, so a
leading space in the displayed text is preserved.

```text
LINE 0 wukong         #
LINE 1 192.168.2.11
```

Replies:

```text
OK LINE 0
OK LINE 1
```

`LINE` is unconditional. A client that wants to avoid redundant LCD writes
should cache its own rendered lines, as the reference Bash menu does.

### `CLEAR`

Sends HD44780 clear-display command `0x01`.

```text
OK CLEAR
```

### `BACKLIGHT <1|2|3>`

Uses the three recovered Seagate backlight states:

```text
1 = Off     (GPIO73=0 GPIO76=0)
2 = Light   (GPIO73=0 GPIO76=1)
3 = Strong  (GPIO73=1 GPIO76=1)
```

The undefined `GPIO73=1 GPIO76=0` state is never generated.

Example:

```text
BACKLIGHT 2
```

Reply:

```text
OK BACKLIGHT 2
```

### `MODE IDLE` / `MODE ACTIVE`

Changes only the hardware process's button polling policy:

```text
IDLE   = 150 ms polling
ACTIVE = 10 ms polling
```

The first physical press observed in IDLE is accepted from one sample so a
short wake tap is not lost. ACTIVE presses use two-sample debounce (roughly 10-20 ms depending on
where the physical transition falls between poll ticks). Releases also require two clean samples.

Replies:

```text
OK MODE IDLE
OK MODE ACTIVE
```

UI meaning is intentionally *not* attached to these modes. The reference shell
UI uses IDLE while the dim home screen is inactive and ACTIVE after wake.

### `GETBUTTONS`

Returns the current physical active-low button state once:

```text
BUTTONS UP=0 DOWN=0
BUTTONS UP=1 DOWN=0
```

This is intended for diagnostics; normal UIs should consume asynchronous button
events instead.

### `PING`

```text
OK PONG
```

### `QUIT`

Requests a clean exit. Before releasing the GPIO requests, the process restores
backlight level 2 as a best effort.

```text
OK QUIT
```

EOF on stdin also causes a clean exit.

## Asynchronous button events

The hardware process reports debounced physical events independently of command
replies:

```text
BUTTON UP PRESS
BUTTON UP RELEASE
BUTTON DOWN PRESS
BUTTON DOWN RELEASE
BUTTON BOTH PRESS
BUTTON BOTH RELEASE
```

If a raw button signal stops being continuously asserted before the debounced
release is complete, one interruption event is emitted:

```text
BUTTON UP INTERRUPT
```

or

```text
BUTTON DOWN INTERRUPT
```

A simultaneous-button chord may likewise produce:

```text
BUTTON BOTH INTERRUPT
```

This event exists so a UI implementing a long-press timer cannot accidentally
bridge a very brief release/repress into one long hold. A UI with no long-press
feature may simply ignore `INTERRUPT`.

Simultaneous UP+DOWN is exposed as the logical `BOTH` state, so a custom UI may
assign an action to the chord. From the fully released state it uses the same
debounce policy as the other button states. If another logical press is already
in progress, changing to another raw state (including BOTH) first emits that
press's `INTERRUPT` and is not promoted until the buttons return to a clean
released state. This preserves long-press continuity semantics.

## What belongs in the hardware process

The hardware process intentionally keeps only front-panel hardware/mechanics here:

- gpiochip discovery and persistent ownership
- GPIO40..47 LCD data bus
- GPIO70/71/72 RS/RW/E open-drain control
- GPIO73/76 backlight control
- GPIO74/75 active-low button input
- HD44780 timing and character mapping
- button polling/debounce/physical events

Menu policy does **not** belong here. A UI decides things such as:

- what pages exist
- what a short press does
- long-press duration
- enter/back semantics
- inactivity timeout
- screen indicators
- Linux sensor/network/storage data shown on the LCD

That separation is why a replacement UI does not need any GPIO knowledge.

## Minimal Bash example

```bash
coproc PANEL { exec ./seagate-xbig-frontpanel; }
in_fd=${PANEL[1]}
out_fd=${PANEL[0]}

IFS= read -r -u "$out_fd" hello
[[ $hello == 'READY 1.0' ]] || exit 1

printf '%s\n' INIT >&"$in_fd"
printf '%s\n' 'LINE 0 Hello' >&"$in_fd"
printf '%s\n' 'LINE 1 Linux NAS' >&"$in_fd"
printf '%s\n' 'BACKLIGHT 2' >&"$in_fd"
printf '%s\n' 'MODE IDLE' >&"$in_fd"

while IFS= read -r -u "$out_fd" msg; do
    case $msg in
        'BUTTON UP PRESS')   echo 'up pressed' ;;
        'BUTTON DOWN PRESS') echo 'down pressed' ;;
    esac
done
```

## Hardware notes

The implementation follows the recovered Seagate MSS0731 behavior:

```text
GPIO40..47 -> LCD D0..D7
GPIO70     -> RS
GPIO71     -> R/W (kept at 0; LCD bus is write-only)
GPIO72     -> E
GPIO73     -> backlight A
GPIO74     -> UP button, input, active-low
GPIO75     -> DOWN button, input, active-low
GPIO76     -> backlight B
```

GPIO70..73 and GPIO76 are requested as open-drain outputs. The LCD byte delay is
1 ms, matching the recovered Seagate Windows implementation.
