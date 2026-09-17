# Seagate Business Storage Windows Server 4-bay NAS front panel for Linux

Linux support for the front LCD, backlight and buttons on the
[Seagate Business Storage Windows Server 4-bay NAS](https://www.seagate.com/in/en/support/external-hard-drives/network-storage/business-storage-windows-server-4-bay-nas/).

This was written for the MSS0731-family hardware used in the 4-bay Windows Server NAS.
It replaces the original Windows XBig front-panel service with a small FreePascal
hardware process and keeps the menu/UI in a normal Bash script so it is easy to edit.

## What's in this repo

- `seagate-xbig-frontpanel.pas` — hardware layer. Owns the GPIO lines, drives the
  16x2 HD44780-compatible LCD, controls the backlight and reports button events.
- `gpiod_min.pas` — small dynamic libgpiod 2.x binding used by the Pascal program.
- `seagate-xbig-menu.sh` — reference menu/UI. This is where the displayed pages,
  navigation, long-press actions and Linux status collection live.
- `PROTOCOL.md` — stdin/stdout protocol between the UI and the hardware process.

The hardware and UI are deliberately separate. You can replace the shell menu with
another program without needing to reimplement the GPIO or LCD handling.

## Hardware

The front panel is connected through the Fintek F71889ED Super-I/O and exposed by
Linux through `gpio-f7188x`.

The relevant front-panel signals are:

```text
GPIO40..47  LCD D0..D7
GPIO70      LCD RS
GPIO71      LCD R/W
GPIO72      LCD E
GPIO73      backlight control A
GPIO74      UP button
GPIO75      DOWN button
GPIO76      backlight control B
```

The Pascal program accesses these only through libgpiod. It does not use raw
Super-I/O port access.

## Requirements

Runtime:

- Linux with the `gpio-f7188x` driver
- libgpiod 2.x (`libgpiod.so.3`; Debian 13 package `libgpiod3`)
- Bash for the included menu
- permission to access the matching `/dev/gpiochip*` devices (normally root)

To build from source you also need FreePascal.

## Compile

Keep `seagate-xbig-frontpanel.pas` and `gpiod_min.pas` in the same directory, then:

```sh
fpc -O2 seagate-xbig-frontpanel.pas
```

This creates:

```text
seagate-xbig-frontpanel
```

If you are using a release that includes a precompiled x86-64 binary, you can skip
this step.

## Run

Make the files executable if needed:

```sh
chmod +x seagate-xbig-frontpanel seagate-xbig-menu.sh
```

Then start the menu:

```sh
sudo ./seagate-xbig-menu.sh
```

The menu starts the Pascal hardware process automatically and checks that the
protocol version matches before continuing.

To test the hardware process by itself:

```sh
sudo ./seagate-xbig-frontpanel
```

It accepts simple line-based commands such as:

```text
INIT
LINE 0 Hello
LINE 1 Linux NAS
BACKLIGHT 2
MODE ACTIVE
```

See `PROTOCOL.md` for the complete interface.

## Customizing the menu

Most users should only need to edit `seagate-xbig-menu.sh`. The Pascal program is
intended to stay as the board-specific hardware layer while the menu remains a
normal, readable shell script.

The protocol and menu are versioned separately so the UI can evolve without
changing the hardware interface.
