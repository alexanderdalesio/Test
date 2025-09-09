#!/usr/bin/env bash
# setup_rgb_fan.sh — WS2812 rainbow (GPIO10/MOSI over SPI) as a boot service
# Safe to re-run; it’s idempotent.
# After running, edit /etc/default/rgb-fan to tweak LED count/brightness/speed.

set -euo pipefail

# ---------- helpers ----------
die(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "Run with: sudo bash $0"; }

# ---------- preflight ----------
need_root

# Determine target (non-root) user who invoked sudo
TARGET_USER="${SUDO_USER:-}"
if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
  # best-effort: first user in /home
  if compgen -G "/home/*" > /dev/null; then
    TARGET_USER="$(basename "$(ls -1d /home/* | head -n1)")"
  fi
fi
[[ -n "${TARGET_USER}" && -d "/home/${TARGET_USER}" ]] || die "Could not determine a non-root user."

HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
APP_DIR="$HOME_DIR/Desktop/Testing/rgb-fan"
VENV_DIR="$APP_DIR/env"
PY_SCRIPT="$APP_DIR/rgb_fan.py"
SERVICE="rgb-fan.service"
SERVICE_PATH="/etc/systemd/system/$SERVICE"
ENVFILE="/etc/default/rgb-fan"

echo "[1/8] apt update + base packages"
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y python3-venv python3-pip python3-dev build-essential raspi-config

echo "[2/8] Enable SPI + load modules"
raspi-config nonint do_spi 0 || true
modprobe spi_bcm2835 || true
modprobe spidev || true

echo "[3/8] Create app dir and virtualenv"
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$APP_DIR"
if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  sudo -u "$TARGET_USER" bash -lc "python3 -m venv '$VENV_DIR'"
fi

echo "[4/8] Install Python deps into venv"
sudo -u "$TARGET_USER" bash -lc "source '$VENV_DIR/bin/activate' && \
  pip install --upgrade pip && \
  pip install adafruit-blinka adafruit-circuitpython-neopixel-spi spidev lgpio"

echo "[5/8] Write configurable LED script"
cat > "$PY_SCRIPT" <<'PY'
# rgb_fan.py — Forever rainbow on WS2812 via SPI (GPIO10/MOSI)
# Wire: DIN -> GPIO10 (MOSI), GND -> GND, +5V -> 5V. Use a 5 V level shifter on DIN.
import os, time, signal, sys
import board, busio
import neopixel_spi as neopixel  # from adafruit-circuitpython-neopixel-spi

def getenv_int(name, default):
    try: return int(os.getenv(name, default))
    except: return default

def getenv_float(name, default):
    try: return float(os.getenv(name, default))
    except: return default

# Config via environment (editable in /etc/default/rgb-fan)
NUM_LEDS     = getenv_int('RGBFAN_NUM_LEDS', 2)
BRIGHTNESS   = max(0.0, min(1.0, getenv_float('RGBFAN_BRIGHTNESS', 0.5)))
FPS          = max(1, getenv_int('RGBFAN_FPS', 100))
SPEED_SCALE  = max(0.01, getenv_float('RGBFAN_SPEED_SCALE', 0.75))  # 25% slower than baseline
PIXEL_ORDER  = os.getenv('RGBFAN_PIXEL_ORDER', 'GRB').upper()       # GRB or RGB

ORDER_MAP = {
    'GRB': neopixel.GRB,
    'RGB': neopixel.RGB,
    'GBR': neopixel.GBR,
    'BRG': neopixel.BRG,
    'BGR': neopixel.BGR,
    'RBG': neopixel.RBG,
}
ORDER = ORDER_MAP.get(PIXEL_ORDER, neopixel.GRB)

spi = busio.SPI(board.SCLK, MOSI=board.MOSI)  # SPI0: SCLK=GPIO11, MOSI=GPIO10
pixels = neopixel.NeoPixel_SPI(
    spi, NUM_LEDS, brightness=BRIGHTNESS,
    pixel_order=ORDER, auto_write=False
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
step = 2.0 * SPEED_SCALE  # base was 2; scale by 0.75 => 25% slower

while True:
    for i in range(NUM_LEDS):
        pixels[i] = wheel(int(frame + i * 32) & 0xFF)
    pixels.show()
    frame = (frame + step) % 256.0
    time.sleep(sleep_s)
PY
chown "$TARGET_USER:$TARGET_USER" "$PY_SCRIPT"

echo "[6/8] Create /etc/default env (editable knobs)"
if [[ ! -f "$ENVFILE" ]]; then
  cat > "$ENVFILE" <<ENV
# rgb-fan service config
# Edit, then: sudo systemctl restart rgb-fan.service
RGBFAN_NUM_LEDS=2
RGBFAN_BRIGHTNESS=0.5
RGBFAN_FPS=100
RGBFAN_SPEED_SCALE=0.75
RGBFAN_PIXEL_ORDER=GRB
ENV
fi

echo "[7/8] Create systemd service"
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
Environment=BLINKA_FORCECHIP=BCM2XXX
EnvironmentFile=-$ENVFILE
# allow access to /dev/spidev* and GPIO
SupplementaryGroups=spi gpio
# small settle delay at boot
ExecStartPre=/bin/sleep 1
ExecStart=$VENV_DIR/bin/python $PY_SCRIPT
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

echo "[8/8] Enable + start service"
systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl restart "$SERVICE" || true

# Add user to groups for interactive runs (effective next login)
usermod -aG spi "$TARGET_USER" || true
usermod -aG gpio "$TARGET_USER" || true

# Uninstaller for convenience
UNINSTALL=/usr/local/sbin/rgb-fan-uninstall
cat > "$UNINSTALL" <<DEL
#!/usr/bin/env bash
set -euo pipefail
sudo systemctl stop $SERVICE || true
sudo systemctl disable $SERVICE || true
sudo rm -f $SERVICE_PATH
sudo systemctl daemon-reload
sudo rm -f $ENVFILE
sudo rm -rf $APP_DIR
echo "Removed service and app dir."
DEL
chmod +x "$UNINSTALL"

# Final hints
echo
echo "Done."
echo "Service:     sudo systemctl status $SERVICE --no-pager"
echo "Logs:        journalctl -u $SERVICE -n 50 --no-pager"
echo "Config:      sudo nano $ENVFILE    # then: sudo systemctl restart $SERVICE"
echo "Script path: $PY_SCRIPT"
echo "Uninstall:   sudo $UNINSTALL"
echo

# Warn if SPI node missing (typically needs a reboot the first time)
if [[ ! -e /dev/spidev0.0 ]]; then
  echo "NOTE: /dev/spidev0.0 not present yet. Reboot to finish enabling SPI: sudo reboot"
fi