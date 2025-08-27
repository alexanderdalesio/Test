#!/usr/bin/env bash
# setup_rgb_fan.sh — WS2812 rainbow on GPIO10 with auto-start systemd service
# Usage (after you host this file as a raw Pastebin URL):
#   curl -fsSL "https://pastebin.com/raw/XXXXXXXX" | sudo bash

set -euo pipefail

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run this via sudo:  curl -fsSL <RAW_URL> | sudo bash" >&2
    exit 1
  fi
}
need_root

# Determine the target non-root user (who invoked sudo)
TARGET_USER="${SUDO_USER:-}"
if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
  # best-effort guess (first /home entry)
  if [[ -d /home ]] && ls /home >/dev/null 2>&1; then
    TARGET_USER="$(ls /home | head -n1 || true)"
  fi
fi
if [[ -z "${TARGET_USER}" || ! -d "/home/${TARGET_USER}" ]]; then
  echo "Could not determine a non-root user. Re-run with: curl ... | sudo bash (from your normal user)" >&2
  exit 1
fi

HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
APP_DIR="$HOME_DIR/Desktop/Testing/rgb-fan"
VENV_DIR="$APP_DIR/env"
PY_SCRIPT="$APP_DIR/rgb_fan.py"
SERVICE="rgb-fan.service"
SERVICE_PATH="/etc/systemd/system/$SERVICE"

echo "[1/6] apt update and base packages…"
apt update
DEBIAN_FRONTEND=noninteractive apt install -y \
  python3-venv python3-pip python3-dev build-essential raspi-config

echo "[2/6] Enable SPI and load drivers…"
# Enable SPI via raspi-config (non-interactive)
raspi-config nonint do_spi 0 || true
# Load kernel modules now (will auto-load on next boot as well)
modprobe spi_bcm2835 || true
modprobe spidev || true

echo "[3/6] Create app dir and virtualenv…"
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$APP_DIR"
sudo -u "$TARGET_USER" bash -lc "python3 -m venv '$VENV_DIR'"
sudo -u "$TARGET_USER" bash -lc "source '$VENV_DIR/bin/activate' && \
  pip install --upgrade pip && \
  pip install adafruit-blinka adafruit-circuitpython-neopixel-spi"

echo "[4/6] Write Python LED script…"
cat > "$PY_SCRIPT" <<'PY'
# rgb_fan.py — Forever rainbow on WS2812 via SPI (GPIO10/MOSI)
# Wire: DIN→GPIO10 (MOSI), GND→GND, +5V→5V. Use a 5 V level shifter on DIN.
import time, signal, sys
import board, busio
import neopixel_spi as neopixel  # from adafruit-circuitpython-neopixel-spi

NUM_LEDS = 2          # change this if you have more pixels
BRIGHTNESS = 0.5
FPS = 100
SPEED_SCALE = 0.75    # 25% slower than the earlier rainbow
FRAME_STEP = 2.0 * SPEED_SCALE

spi = busio.SPI(board.SCLK, MOSI=board.MOSI)   # SPI0: SCLK=GPIO11, MOSI=GPIO10
pixels = neopixel.NeoPixel_SPI(
    spi, NUM_LEDS, brightness=BRIGHTNESS,
    pixel_order=neopixel.GRB, auto_write=False
)

def wheel(pos: int):
    pos = 255 - pos
    if pos < 85:  return (255 - pos*3, 0, pos*3)
    if pos < 170:
        pos -= 85
        return (0, pos*3, 255 - pos*3)
    pos -= 170
    return (pos*3, 255 - pos*3, 0)

def cleanup_and_exit(*_):
    try:
        pixels.fill((0, 0, 0)); pixels.show()
    finally:
        sys.exit(0)

signal.signal(signal.SIGTERM, cleanup_and_exit)
signal.signal(signal.SIGINT, cleanup_and_exit)

frame = 0.0
sleep_s = 1.0 / FPS

while True:
    for i in range(NUM_LEDS):
        pixels[i] = wheel(int(frame + i * 32) & 0xFF)
    pixels.show()
    frame = (frame + FRAME_STEP) % 256.0
    time.sleep(sleep_s)
PY
chown "$TARGET_USER:$TARGET_USER" "$PY_SCRIPT"

echo "[5/6] Create systemd service…"
cat > "$SERVICE_PATH" <<UNIT
[Unit]
Description=RGB Fan LEDs (WS2812 rainbow over SPI)
After=multi-user.target

[Service]
Type=simple
User=$TARGET_USER
Group=$TARGET_USER
WorkingDirectory=$APP_DIR
Environment=PYTHONUNBUFFERED=1
# ensure access to /dev/spidev* without needing a re-login
SupplementaryGroups=spi gpio
ExecStart=$VENV_DIR/bin/python $PY_SCRIPT
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

echo "[6/6] Enable + start service…"
systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl restart "$SERVICE"

# Add the user to groups for interactive use (effective next login)
usermod -aG spi "$TARGET_USER" || true
usermod -aG gpio "$TARGET_USER" || true

echo
echo "All set."
echo "Service status:  sudo systemctl status $SERVICE --no-pager"
echo "Logs:            journalctl -u $SERVICE -e --no-pager"
echo "Stop/Start:      sudo systemctl stop|start $SERVICE"
echo
echo "Files created:"
echo "  $PY_SCRIPT"
echo "  $SERVICE_PATH"
echo
echo "If LEDs don't light: check wiring DIN→GPIO10, common GND, solid 5V, and use a 5V level shifter."
