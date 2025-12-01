## Micromanager Edge Installer

One-line installer for the Micromanager IoT stack on Raspberry Pi and Linux edge devices.

This directory is a **template** for the public `FFTY50/micromanager-installer` repository.  
When you create that repo on GitHub, copy this `README.md` and your `install.sh` into it.

The installer repo only contains the **installer script**. The actual application runs from Docker images (for example `ffty50/micromanager-app:latest`).

---

### Requirements

- Raspberry Pi 4/5 (recommended) or x86_64 Linux
- Fresh install of:
  - Raspberry Pi OS / Debian / Ubuntu
- `curl` installed (default on most images)
- Internet access to:
  - Docker package mirror
  - Docker image registry (e.g. Docker Hub)

You do **not** need Node.js or git on the device.

---

### Quick Install (Production)

Runs the full Micromanager stack:
- Micromanager app (POS parsing)
- Frigate NVR
- Cloudflared tunnel

```bash
curl -fsSL https://raw.githubusercontent.com/FFTY50/micromanager-installer/main/install.sh | sudo bash
```

The script will:
- Detect your system
- Install Docker
- Create `/opt/micromanager`
- Pull the Micromanager + Frigate + Cloudflared images
- Run an interactive wizard to fill in `.env` (serial ports, n8n URLs, Cloudflare token, etc.)
- Start the stack with `docker compose up -d`

---

### Test Modes

These modes are for **lab/demo environments** and use the **built-in emulator** instead of a real POS serial connection.

#### Micromanager Only (Test)

Runs only the Micromanager container with a **named pipe** `/tmp/serial_txn` wired as the serial port.  
No Frigate, no Cloudflare.

```bash
curl -fsSL https://raw.githubusercontent.com/FFTY50/micromanager-installer/main/install.sh | sudo bash -s -- --test
```

- Good for:
  - Quick parser/queue tests
  - Validating health/metrics
- After install, you can run:

```bash
docker exec -it micromanager-app npm run emulator -- --random --burst 5
```

to generate synthetic transactions.

#### Full Stack Test (Test Full)

Runs Micromanager **plus** Frigate **plus** Cloudflared with a **placeholder** token, still using the emulator pipe.

```bash
curl -fsSL https://raw.githubusercontent.com/FFTY50/micromanager-installer/main/install.sh | sudo bash -s -- --test-full
```

This gives you a full end‑to‑end lab setup:

- `micromanager-app` at `http://localhost:3000`
- Frigate UI at `http://localhost:8971`
- Emulator on `/tmp/serial_txn`

You can:

```bash
docker exec -it micromanager-app npm run emulator -- --random --burst 5
docker logs -f micromanager-app | grep -i frigate
```

and check Frigate for video bookmarks.

---

### Upgrading

To pull the latest containers and restart:

```bash
cd /opt/micromanager
sudo docker compose pull
sudo docker compose up -d
```

If the installer script itself changes, just re-run the same curl command you used originally.

---

### Uninstall / Cleanup

From the device:

```bash
cd /opt/micromanager
sudo docker compose down
sudo rm -rf /opt/micromanager
```

This stops and removes the containers and deletes the Micromanager data directory. Docker itself will remain installed.

---

### Troubleshooting

- **Installer fails with 404 from raw.githubusercontent.com**

  Make sure you are using the correct URL and branch name:

  ```bash
  curl -fsSL https://raw.githubusercontent.com/FFTY50/micromanager-installer/main/install.sh
  ```

- **Docker image pull fails**

  - Check network connectivity.
  - Verify the image name (for example `ffty50/micromanager-app:latest`) is accessible from this network.

- **No serial ports detected in production mode**

  The installer will fall back to `/dev/ttyUSB0`. Ensure your POS is connected and recognized by the OS:

  ```bash
  ls /dev/ttyUSB*
  ```

For deeper documentation, see the main Micromanager repo.


