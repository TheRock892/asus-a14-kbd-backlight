# asus-a14-kbd-backlight

Userspace workaround for keyboard backlight control and Fn hotkeys (F4/F5/F6)
on the **ASUS Zenbook A14 (UX3407QA)**, Snapdragon X Elite (ARM64), running
Linux.

## The problem

On this laptop the keyboard backlight fades continuously on its own, and
`Fn+F4` (cycle keyboard backlight), `Fn+F5` (brightness down) and `Fn+F6`
(brightness up) don't do anything out of the box. This happens because the
kernel has no driver for the ASUS EC HID device (`0B05:0220`,
HID-over-I2C) — it just binds to the generic `hid-generic` driver, which
doesn't know how to talk to it.

A proper kernel driver ("HID: asus: add new Asus EC hid device for keyboard
backlight and FN HotKeys") has been proposed upstream but is not merged yet.
Once it lands in the kernel you're running, you should uninstall this
workaround and let the real driver take over.

## What this does

`install-kbd-backlight.sh` installs a small Python daemon
(`asus-a14-kbd-backlightd`) that:

- Talks directly to the EC over the HID feature report used by the
  pending kernel patch (handshake `5A D0 8F 01`, then `5A BA C5 C4 <level>`
  to set brightness 0-3).
- Registers a standard LED class device (`asus::kbd_backlight`) through the
  kernel's `uleds` framework, so existing tools (`brightnessctl`, desktop
  environment keyboard-backlight controls, etc.) work with it exactly as
  they would with a real upstream driver.
- Decodes the `Fn+F4`/`Fn+F5`/`Fn+F6` key presses from the same HID channel
  and runs whatever brightness commands you configure (see
  [Adapting it to your setup](#adapting-it-to-your-setup)).
- Re-handshakes with the EC and turns the backlight off/on around real
  suspend/resume, via a `systemd-sleep` hook.

It's a userspace stand-in for the missing kernel driver, not a general
keyboard-backlight framework — it's specific to this EC protocol and this
exact USB/HID vendor:product id (`0B05:0220`).

## Requirements

- An ASUS Zenbook A14 (UX3407QA) or a laptop using the same ASUS EC HID
  protocol (vendor:product `0B05:0220`).
- Linux with systemd, the `uleds` kernel module available, and `brightnessctl`
  (or anything else that writes to `/sys/class/leds/asus::kbd_backlight/brightness`).
- Root access to install (it creates a systemd service and a sleep hook).

## Install

```sh
sudo sh install-kbd-backlight.sh
```

This is idempotent — re-run it any time to update/reinstall.

Check it's running:

```sh
systemctl status asus-a14-kbd-backlight.service
```

## Uninstall

```sh
sudo sh install-kbd-backlight.sh --uninstall
```

This removes the daemon, service, and sleep hook. The last known brightness
level, persisted at `/var/lib/asus-a14-kbd-backlight/level`, is left in place
in case you reinstall later — remove that directory by hand if you don't
need it.

## Adapting it to your setup

The daemon currently forwards the three Fn hotkeys to Omarchy-specific
commands (`omarchy-brightness-keyboard`, `omarchy-brightness-display`). If
you're not running [Omarchy](https://omarchy.org), open
`install-kbd-backlight.sh`, find the `main()` function in the embedded
Python script, and replace those `subprocess.run([...])` calls with
whatever your desktop environment uses to change keyboard/screen brightness.

## Known limitations

- The lid switch on this hardware is not reliably exposed to Linux (ACPI,
  evdev, logind, and this same HID channel never reported a clean
  open/close in testing), so there's no way to auto-blank the backlight on
  lid-close, docked or not. This is a hardware/firmware limitation, not
  something this workaround can fix.
- `/dev/hidrawN` numbering isn't stable across reboots; the daemon always
  resolves the right device by HID vendor:product id at startup, so this
  doesn't affect normal use.

## License

MIT — see [LICENSE](LICENSE).
