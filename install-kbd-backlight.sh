#!/bin/sh
# Installa il workaround userspace per la retroilluminazione tastiera /
# tasti Fn (F4/F5/F6) sull'ASUS Zenbook A14 (UX3407QA, Snapdragon ARM),
# finché non viene unito upstream il driver kernel "hid-asus-ec"
# (LKML 20251221-add-support-for-the-asus-hid-ec-v1-1-35d7d70fbbfc@yahoo.com).
#
# Idempotente: si può rilanciare senza problemi per reinstallare/aggiornare.
# Da eseguire con sudo: sudo sh install-kbd-backlight.sh
#
# Per disinstallare: sudo sh install-kbd-backlight.sh --uninstall

set -e

DAEMON=/usr/local/bin/asus-a14-kbd-backlightd
SERVICE=/etc/systemd/system/asus-a14-kbd-backlight.service
SLEEP_HOOK=/usr/lib/systemd/system-sleep/asus-a14-kbd-backlight
MODULES_CONF=/etc/modules-load.d/asus-a14-kbd-backlight.conf
STATE_DIR=/var/lib/asus-a14-kbd-backlight

if [ "$(id -u)" != "0" ]; then
    echo "Serve eseguirlo come root (sudo sh $0)" >&2
    exit 1
fi

if [ "$1" = "--uninstall" ]; then
    systemctl disable --now asus-a14-kbd-backlight.service 2>/dev/null || true
    rm -f "$SERVICE" "$SLEEP_HOOK" "$DAEMON" "$MODULES_CONF"
    systemctl daemon-reload
    echo "Disinstallato. Stato persistito lasciato in $STATE_DIR (rimuovilo a mano se non serve più)."
    exit 0
fi

cat > "$DAEMON" <<'DAEMON_EOF'
#!/usr/bin/env python3
"""ASUS Zenbook A14 (UX3407QA) EC keyboard backlight control.

Userspace workaround for the missing hid-asus-ec kernel driver
(pending upstream, LKML message-id
20251221-add-support-for-the-asus-hid-ec-v1-1-35d7d70fbbfc@yahoo.com).

Talks to the EC over the HID feature report 0x5A on the keyboard's
HID-over-I2C device (0B05:0220), replicating that patch's protocol:
  - init/handshake: 5A D0 8F 01 (required once before brightness works)
  - set level:      5A BA C5 C4 <level 0-3>

Exposes a standard LED class device (asus::kbd_backlight) via the
kernel's uleds framework, same name/shape the real upstream driver
would create. This makes Omarchy's own existing tooling work for free:
  - omarchy-brightness-keyboard (up/down/cycle/off/restore), used by
    the lock screen's idle-blank and wake hooks, and any future OSD
    or keybinding, all drive this through brightnessctl.
The daemon's remaining jobs are decoding Fn hotkeys from the same HID
report and forwarding them to Omarchy's own commands:
  - Fn+F4 (byte[1] == 0xC7): omarchy-brightness-keyboard cycle
  - Fn+F5 (byte[1] == 0x10): omarchy-brightness-display 5%-
  - Fn+F6 (byte[1] == 0x20): omarchy-brightness-display +5%
and applying whatever brightness value lands on the LED class device
to the EC over HID.

Note: this hardware's lid switch is wired only to the EC and is not
exposed to Linux through ACPI, evdev, logind, or this HID channel, so
there is no software signal to auto-mute the backlight when the lid is
closed while docked.

/dev/hidrawN numbering is not stable across reboots, so the target
device is resolved by HID vendor:product (0B05:0220) at every start.
"""
import fcntl
import glob
import os
import select
import struct
import subprocess
import sys
import time

ASUS_VENDOR_ID = 0x0B05
ASUS_KBD_PRODUCT_ID = 0x0220
STATE_DIR = '/var/lib/asus-a14-kbd-backlight'
STATE_FILE = os.path.join(STATE_DIR, 'level')

HIDIOCSFEATURE_64 = 0xC0404806  # _IOC(WRITE|READ, 'H', 0x06, 64)
REPORT_ID = 0x5A
MAX_LEVEL = 3
FN_F4_CODE = 0xC7
FN_F5_CODE = 0x10
FN_F6_CODE = 0x20

LED_NAME = 'asus::kbd_backlight'
ULEDS_PATH = '/dev/uleds'
ULEDS_MAX_NAME_SIZE = 64
LED_BRIGHTNESS_PATH = '/sys/class/leds/%s/brightness' % LED_NAME


def find_hidraw_path():
    for uevent_path in glob.glob('/sys/class/hidraw/*/device/uevent'):
        try:
            with open(uevent_path) as f:
                content = f.read()
        except OSError:
            continue
        for line in content.splitlines():
            if not line.startswith('HID_ID='):
                continue
            parts = line[len('HID_ID='):].split(':')
            if len(parts) == 3 and int(parts[1], 16) == ASUS_VENDOR_ID \
                    and int(parts[2], 16) == ASUS_KBD_PRODUCT_ID:
                node = uevent_path.split('/')[4]  # hidrawN
                return '/dev/' + node
    raise RuntimeError('ASUS keyboard HID device (0B05:0220) not found')


def load_level():
    try:
        with open(STATE_FILE) as f:
            lvl = int(f.read().strip())
            if 0 <= lvl <= MAX_LEVEL:
                return lvl
    except (OSError, ValueError):
        pass
    return MAX_LEVEL


def save_level(lvl):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(STATE_FILE, 'w') as f:
            f.write(str(lvl))
    except OSError:
        pass


def send_cmd(fd, data):
    buf = bytearray(64)
    buf[0:len(data)] = bytes(data)
    fcntl.ioctl(fd, HIDIOCSFEATURE_64, buf, True)


def ec_init(fd):
    send_cmd(fd, [REPORT_ID, 0xD0, 0x8F, 0x01])


def set_level(fd, lvl):
    lvl = max(0, min(MAX_LEVEL, lvl))
    send_cmd(fd, [REPORT_ID, 0xBA, 0xC5, 0xC4, lvl])
    # The upstream patch sleeps 20ms after this exact command before
    # returning, apparently to let the EC actually apply it. Skipping this
    # let the pre-suspend hook return control to systemd-sleep before the
    # EC had switched the backlight off, so it was still lit when the
    # hardware actually went to sleep moments later.
    time.sleep(0.02)


def reinit_once():
    """Called from the systemd-sleep hook after a real suspend/resume."""
    fd = os.open(find_hidraw_path(), os.O_RDWR)
    try:
        ec_init(fd)
        set_level(fd, load_level())
    finally:
        os.close(fd)


def off_once():
    """Called from the systemd-sleep hook just before a real suspend.

    Omarchy's own lock-screen blanking (omarchy-brightness-keyboard off)
    only runs after a 5s idle timer following the lock becoming secure,
    but omarchy-system-sleep-lock only waits for the lock to become
    secure before releasing logind's inhibitor -- suspend can proceed
    well before that 5s timer fires. This sends the EC command directly
    so the backlight is reliably off before the hardware actually
    sleeps, regardless of that race. Deliberately does not touch the
    LED class device's sysfs value or the state file, so the real last
    chosen level is still what reinit_once() restores on resume.
    """
    fd = os.open(find_hidraw_path(), os.O_RDWR)
    try:
        set_level(fd, 0)
    finally:
        os.close(fd)


def register_uleds():
    """Create /sys/class/leds/asus::kbd_backlight via the uleds framework.

    Keeping the returned fd open keeps the LED registered; closing it
    removes the device from sysfs.
    """
    name = LED_NAME.encode()
    name_padded = name + b'\x00' * (ULEDS_MAX_NAME_SIZE - len(name))
    reg = name_padded + struct.pack('i', MAX_LEVEL)
    fd = os.open(ULEDS_PATH, os.O_RDWR)
    os.write(fd, reg)
    return fd


def main():
    current_level = load_level()

    hid_fd = os.open(find_hidraw_path(), os.O_RDWR)
    ec_init(hid_fd)
    set_level(hid_fd, current_level)

    uleds_fd = register_uleds()
    # Reflect the restored level on the LED class device so brightnessctl
    # and anything reading sysfs sees the real current state immediately.
    with open(LED_BRIGHTNESS_PATH, 'w') as f:
        f.write(str(current_level))

    poller = select.poll()
    poller.register(hid_fd, select.POLLIN)
    poller.register(uleds_fd, select.POLLIN)

    while True:
        for fd, _ in poller.poll():
            if fd == uleds_fd:
                data = os.read(uleds_fd, 4)
                (level,) = struct.unpack('i', data)
                level = max(0, min(MAX_LEVEL, level))
                set_level(hid_fd, level)
                save_level(level)
            elif fd == hid_fd:
                try:
                    data = os.read(hid_fd, 64)
                except OSError:
                    continue
                if len(data) < 2 or data[0] != REPORT_ID:
                    continue
                code = data[1]
                if code == FN_F4_CODE:
                    subprocess.run(
                        ['omarchy-brightness-keyboard', 'cycle'],
                        check=False,
                    )
                elif code == FN_F5_CODE:
                    subprocess.run(
                        ['omarchy-brightness-display', '5%-'],
                        check=False,
                    )
                elif code == FN_F6_CODE:
                    subprocess.run(
                        ['omarchy-brightness-display', '+5%'],
                        check=False,
                    )


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'reinit':
        reinit_once()
    elif len(sys.argv) > 1 and sys.argv[1] == 'off':
        off_once()
    else:
        main()
DAEMON_EOF
chmod 755 "$DAEMON"

cat > "$SERVICE" <<'SERVICE_EOF'
[Unit]
Description=ASUS Zenbook A14 EC keyboard backlight control
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/asus-a14-kbd-backlightd
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Deve vivere in /usr/lib/systemd/system-sleep/, NON /etc/systemd/system-sleep/:
# su questo sistema (systemd 262) quella seconda cartella viene ignorata
# silenziosamente, verificato empiricamente con ore di debug.
cat > "$SLEEP_HOOK" <<'SLEEP_EOF'
#!/bin/sh
# systemd-sleep hook.
#
# pre: turn the backlight off directly over HID, synchronously, before the
# hardware actually suspends. Omarchy's own lock-screen blanking
# (omarchy-brightness-keyboard off) is not reliable here: it only runs
# after a 5s idle timer following the lock becoming secure, while
# omarchy-system-sleep-lock releases logind's inhibitor as soon as the
# lock is secure, well before that timer fires -- so suspend can win the
# race and leave the backlight lit through the whole sleep.
#
# post: after a real resume, re-run the EC handshake and re-apply the
# last known brightness level (the EC/I2C link may need re-initialising
# after a real suspend/resume cycle).
logger -t asus-a14-kbd-backlight-sleep "invoked: $1 $2"

case "$1/$2" in
  pre/*)
    /usr/local/bin/asus-a14-kbd-backlightd off
    logger -t asus-a14-kbd-backlight-sleep "off exit=$?"
    ;;
  post/*)
    /usr/local/bin/asus-a14-kbd-backlightd reinit
    logger -t asus-a14-kbd-backlight-sleep "reinit exit=$?"
    ;;
esac
SLEEP_EOF
chmod 755 "$SLEEP_HOOK"

echo uleds > "$MODULES_CONF"
modprobe uleds 2>/dev/null || true

mkdir -p "$STATE_DIR"

systemctl daemon-reload
systemctl enable --now asus-a14-kbd-backlight.service

echo "Installato e avviato. Stato: systemctl status asus-a14-kbd-backlight.service"
