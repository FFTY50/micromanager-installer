#!/usr/bin/env bash
#
# Micromanager IoT Stack Installer
# One-liner install for $50 Manager edge devices
#
# Usage:
#   Production:  curl -fsSL https://raw.githubusercontent.com/FFTY50/micromanager-installer/main/install.sh | sudo bash
#   Test:        curl -fsSL https://raw.githubusercontent.com/FFTY50/micromanager-installer/main/install.sh | sudo bash -s -- --test
#   Test Full:   curl -fsSL https://raw.githubusercontent.com/FFTY50/micromanager-installer/main/install.sh | sudo bash -s -- --test-full
#
set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
INSTALL_DIR="/opt/micromanager"
REPO_URL="https://github.com/FFTY50/micromanager-installer"
DOCKER_IMAGE="ffty50/micromanager-app:latest"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ============================================================================
# Parse Arguments
# ============================================================================
MODE="production"
while [[ $# -gt 0 ]]; do
    case $1 in
        --test)
            MODE="test"
            shift
            ;;
        --test-full)
            MODE="test-full"
            shift
            ;;
        --help|-h)
            echo "Micromanager IoT Stack Installer"
            echo ""
            echo "Usage: sudo bash install.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --test       Install Micromanager only with emulator support (fastest)"
            echo "  --test-full  Install full stack with emulator support (integration testing)"
            echo "  --help       Show this help message"
            echo ""
            echo "Without options, runs full production install with interactive wizard."
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# ============================================================================
# Helper Functions
# ============================================================================
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_banner() {
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║          Micromanager IoT Stack Installer                      ║"
    echo "║          \$50 Manager Edge Device Setup                         ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
}

# ============================================================================
# System Detection
# ============================================================================
detect_system() {
    log_info "Detecting system..."
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
    
    # Detect OS
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_NAME=$NAME
        OS_VERSION=$VERSION_ID
    else
        log_error "Cannot detect OS. This script supports Debian/Ubuntu/Raspberry Pi OS."
        exit 1
    fi
    
    # Check for Raspberry Pi
    IS_PI=false
    if [[ -f /proc/device-tree/model ]]; then
        PI_MODEL=$(cat /proc/device-tree/model 2>/dev/null || echo "")
        if [[ $PI_MODEL == *"Raspberry Pi"* ]]; then
            IS_PI=true
            log_success "Detected: $PI_MODEL"
        fi
    fi
    
    if [[ $IS_PI == false ]]; then
        log_info "Detected: $OS_NAME $OS_VERSION"
    fi
    
    # Check for NVMe storage (Pi 5)
    HAS_NVME=false
    if [[ -d /mnt/nvme ]] || [[ -b /dev/nvme0n1 ]]; then
        HAS_NVME=true
        log_info "NVMe storage detected"
    fi
    
    # Check for USB serial ports
    SERIAL_PORTS=()
    for port in /dev/ttyUSB* /dev/ttyACM*; do
        if [[ -e $port ]]; then
            SERIAL_PORTS+=("$port")
        fi
    done
    
    if [[ ${#SERIAL_PORTS[@]} -gt 0 ]]; then
        log_info "Serial ports found: ${SERIAL_PORTS[*]}"
    else
        log_info "No serial ports detected (will use emulator for testing)"
    fi
}

# ============================================================================
# Install Docker
# ============================================================================
install_docker() {
    if command -v docker &> /dev/null; then
        log_success "Docker already installed: $(docker --version)"
        return 0
    fi
    
    log_info "Installing Docker..."
    
    # Use official convenience script
    curl -fsSL https://get.docker.com | sh
    
    # Add current user to docker group (for non-root usage later)
    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "$SUDO_USER"
        log_info "Added $SUDO_USER to docker group"
    fi
    
    # Start and enable Docker
    systemctl enable docker
    systemctl start docker
    
    log_success "Docker installed successfully"
}

# ============================================================================
# Create Directory Structure
# ============================================================================
setup_directories() {
    log_info "Creating directory structure..."
    
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR/config"
    
    # Create Frigate storage directories
    if [[ $MODE != "test" ]]; then
        if [[ $HAS_NVME == true ]]; then
            FRIGATE_MEDIA="/mnt/nvme/frigate/media"
            FRIGATE_DB="/mnt/nvme/frigate/db"
        else
            FRIGATE_MEDIA="$INSTALL_DIR/frigate/media"
            FRIGATE_DB="$INSTALL_DIR/frigate/db"
        fi
        mkdir -p "$FRIGATE_MEDIA"
        mkdir -p "$FRIGATE_DB"
        log_info "Frigate storage: $FRIGATE_MEDIA"
    fi
    
    log_success "Directories created"
}

# ============================================================================
# Create Named Pipe for Emulator (Test Modes)
# ============================================================================
setup_emulator_pipe() {
    if [[ $MODE == "test" ]] || [[ $MODE == "test-full" ]]; then
        log_info "Setting up emulator named pipe..."
        
        # Remove existing pipe if it exists
        rm -f /tmp/serial_txn
        
        # Create named pipe
        mkfifo /tmp/serial_txn
        chmod 666 /tmp/serial_txn
        
        log_success "Named pipe created: /tmp/serial_txn"
    fi
}

# ============================================================================
# Copy Default Configurations
# ============================================================================
copy_default_configs() {
    log_info "Copying default configurations..."
    
    # Copy Frigate config (for production and test-full modes)
    if [[ $MODE != "test" ]]; then
        if [[ -f "$INSTALL_DIR/local_docs/frigate-config.yml" ]]; then
            cp "$INSTALL_DIR/local_docs/frigate-config.yml" "$INSTALL_DIR/config/frigate.yml"
        else
            # Download default config if not present
            cat > "$INSTALL_DIR/config/frigate.yml" << 'FRIGATE_EOF'
# Frigate NVR Configuration
# Edit camera IPs below to match your setup

mqtt:
  enabled: false

database:
  path: /db/frigate.db

ffmpeg:
  hwaccel_args: preset-rpi-64-h264

tls:
  enabled: false

go2rtc:
  streams:
    POS1:
      - rtsp://10.7.7.101:554/media/live/1/1
    POS1_sub:
      - rtsp://10.7.7.101:554/media/live/1/2

detectors:
  cpu1:
    type: cpu
    num_threads: 2

record:
  enabled: true
  retain:
    days: 60
    mode: motion

snapshots:
  enabled: true
  retain:
    default: 60

cameras:
  POS1:
    enabled: true
    ffmpeg:
      inputs:
        - path: rtsp://10.7.7.101:554/media/live/1/1
          roles: [record]
        - path: rtsp://10.7.7.101:554/media/live/1/2
          roles: [detect]
      hwaccel_args: preset-rpi-64-h264
    detect:
      width: 704
      height: 480
      fps: 5
    motion:
      enabled: true

version: 0.16-0
FRIGATE_EOF
        fi
        log_success "Frigate config created: $INSTALL_DIR/config/frigate.yml"
    fi
}

# ============================================================================
# Generate Environment File
# ============================================================================
generate_env_file() {
    log_info "Generating environment configuration..."
    
    local ENV_FILE="$INSTALL_DIR/.env"
    
    if [[ $MODE == "test" ]]; then
        # Minimal test config
        cat > "$ENV_FILE" << EOF
# Micromanager Test Configuration
# Generated by install.sh --test

# Device
DEVICE_NAME=$(hostname)
MICROMANAGER_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)

# Serial (using emulator pipe)
SERIAL_PORTS=/tmp/serial_txn
SERIAL_BAUD=9600

# Webhooks (disabled for testing)
# N8N_LINES_URL=
# N8N_TXNS_URL=

# Frigate (disabled in test mode)
FRIGATE_ENABLED=false

# Health server
HEALTH_PORT=3000
HEALTH_HOST=0.0.0.0
EOF
    elif [[ $MODE == "test-full" ]]; then
        # Full stack test config
        cat > "$ENV_FILE" << EOF
# Micromanager Full Stack Test Configuration
# Generated by install.sh --test-full

# Device
DEVICE_NAME=$(hostname)
MICROMANAGER_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)

# Serial (using emulator pipe)
SERIAL_PORTS=/tmp/serial_txn
SERIAL_BAUD=9600

# Webhooks (disabled for testing)
# N8N_LINES_URL=
# N8N_TXNS_URL=

# Frigate (enabled, internal network)
FRIGATE_ENABLED=true
FRIGATE_BASE=http://frigate:5000
FRIGATE_URL=http://localhost:8971
FRIGATE_CAMERA_NAME=POS1

# Frigate storage
FRIGATE_MEDIA_PATH=${FRIGATE_MEDIA:-$INSTALL_DIR/frigate/media}
FRIGATE_DB_PATH=${FRIGATE_DB:-$INSTALL_DIR/frigate/db}

# Cloudflare (placeholder - tunnel won't connect)
CLOUDFLARE_TUNNEL_TOKEN=placeholder_token_for_testing

# Health server
HEALTH_PORT=3000
HEALTH_HOST=0.0.0.0
EOF
    else
        # Production config - will be filled by wizard
        cat > "$ENV_FILE" << EOF
# Micromanager Production Configuration
# Edit these values or re-run the setup wizard

# Device
DEVICE_NAME=$(hostname)
MICROMANAGER_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)

# Serial ports (comma-separated)
SERIAL_PORTS=${SERIAL_PORTS[0]:-/dev/ttyUSB0}
SERIAL_BAUD=9600

# n8n Webhook URLs
N8N_LINES_URL=
N8N_TXNS_URL=

# Frigate Integration
FRIGATE_ENABLED=true
FRIGATE_BASE=http://frigate:5000
FRIGATE_URL=
FRIGATE_CAMERA_NAME=POS1

# Frigate storage paths
FRIGATE_MEDIA_PATH=${FRIGATE_MEDIA:-/mnt/nvme/frigate/media}
FRIGATE_DB_PATH=${FRIGATE_DB:-/mnt/nvme/frigate/db}

# Cloudflare Tunnel
CLOUDFLARE_TUNNEL_TOKEN=

# Health server
HEALTH_PORT=3000
HEALTH_HOST=0.0.0.0
EOF
    fi
    
    log_success "Environment file created: $ENV_FILE"
}

# ============================================================================
# Generate Docker Compose File
# ============================================================================
generate_compose_file() {
    log_info "Generating Docker Compose configuration..."
    
    local COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
    
    if [[ $MODE == "test" ]]; then
        # Micromanager only
        cat > "$COMPOSE_FILE" << 'EOF'
# Micromanager Test Configuration (Micromanager only)
# Generated by install.sh --test

services:
  micromanager:
    image: micromanager/micromanager-app:latest
    container_name: micromanager-app
    restart: unless-stopped
    volumes:
      - micromanager-data:/var/lib/micromanager
      - /tmp/serial_txn:/tmp/serial_txn
    env_file:
      - .env
    ports:
      - "3000:3000"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  micromanager-data:
EOF
    elif [[ $MODE == "test-full" ]]; then
        # Full stack with emulator support
        cat > "$COMPOSE_FILE" << 'EOF'
# Micromanager Full Stack Test Configuration
# Generated by install.sh --test-full

networks:
  nvrnet:
    name: nvrnet

services:
  micromanager:
    image: micromanager/micromanager-app:latest
    container_name: micromanager-app
    restart: unless-stopped
    networks: [nvrnet]
    volumes:
      - micromanager-data:/var/lib/micromanager
      - /tmp/serial_txn:/tmp/serial_txn
    env_file:
      - .env
    ports:
      - "3000:3000"
    depends_on:
      - frigate
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  frigate:
    image: ghcr.io/blakeblackshear/frigate:stable
    container_name: frigate
    privileged: true
    restart: unless-stopped
    shm_size: "1g"
    networks: [nvrnet]
    ports:
      - "8971:8971"
      - "127.0.0.1:5000:5000"
    volumes:
      - ./config:/config
      - ${FRIGATE_MEDIA_PATH}:/media/frigate
      - ${FRIGATE_DB_PATH}:/db
      - /etc/localtime:/etc/localtime:ro
      - type: tmpfs
        target: /tmp/cache
        tmpfs:
          size: 512000000
    devices:
      - /dev/dri:/dev/dri
      - /dev/bus/usb:/dev/bus/usb
    environment:
      FRIGATE_RTSP_PASSWORD: ""

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    networks: [nvrnet]
    command: tunnel --no-autoupdate run --token "${CLOUDFLARE_TUNNEL_TOKEN}"
    depends_on:
      - frigate
    extra_hosts:
      - "host.docker.internal:host-gateway"

volumes:
  micromanager-data:
EOF
    else
        # Production - full stack
        cat > "$COMPOSE_FILE" << 'EOF'
# Micromanager Production Configuration
# Generated by install.sh

networks:
  nvrnet:
    name: nvrnet

services:
  micromanager:
    image: micromanager/micromanager-app:latest
    container_name: micromanager-app
    restart: unless-stopped
    networks: [nvrnet]
    devices:
      - /dev/ttyUSB0:/dev/ttyUSB0
      # Add more serial ports as needed:
      # - /dev/ttyUSB1:/dev/ttyUSB1
    volumes:
      - micromanager-data:/var/lib/micromanager
    env_file:
      - .env
    ports:
      - "3000:3000"
    depends_on:
      - frigate
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  frigate:
    image: ghcr.io/blakeblackshear/frigate:stable
    container_name: frigate
    privileged: true
    restart: unless-stopped
    shm_size: "1g"
    networks: [nvrnet]
    ports:
      - "8971:8971"
      - "127.0.0.1:5000:5000"
    volumes:
      - ./config:/config
      - ${FRIGATE_MEDIA_PATH}:/media/frigate
      - ${FRIGATE_DB_PATH}:/db
      - /etc/localtime:/etc/localtime:ro
      - type: tmpfs
        target: /tmp/cache
        tmpfs:
          size: 512000000
    devices:
      - /dev/dri:/dev/dri
      - /dev/bus/usb:/dev/bus/usb
    environment:
      FRIGATE_RTSP_PASSWORD: ""

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    networks: [nvrnet]
    command: tunnel --no-autoupdate run --token "${CLOUDFLARE_TUNNEL_TOKEN}"
    depends_on:
      - frigate
    extra_hosts:
      - "host.docker.internal:host-gateway"

volumes:
  micromanager-data:
EOF
    fi
    
    log_success "Docker Compose file created: $COMPOSE_FILE"
}

# ============================================================================
# Interactive Wizard (Production Mode)
# ============================================================================
run_wizard() {
    if [[ $MODE != "production" ]]; then
        return 0
    fi
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}                    Configuration Wizard                          ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local ENV_FILE="$INSTALL_DIR/.env"
    
    # Device Name
    read -p "Device name [$(hostname)]: " DEVICE_NAME
    DEVICE_NAME=${DEVICE_NAME:-$(hostname)}
    sed -i "s/^DEVICE_NAME=.*/DEVICE_NAME=$DEVICE_NAME/" "$ENV_FILE"
    
    # Serial Ports
    if [[ ${#SERIAL_PORTS[@]} -gt 0 ]]; then
        echo "Detected serial ports: ${SERIAL_PORTS[*]}"
        read -p "Serial port(s) [${SERIAL_PORTS[0]}]: " SERIAL_INPUT
        SERIAL_INPUT=${SERIAL_INPUT:-${SERIAL_PORTS[0]}}
    else
        read -p "Serial port(s) [/dev/ttyUSB0]: " SERIAL_INPUT
        SERIAL_INPUT=${SERIAL_INPUT:-/dev/ttyUSB0}
    fi
    sed -i "s|^SERIAL_PORTS=.*|SERIAL_PORTS=$SERIAL_INPUT|" "$ENV_FILE"
    
    # n8n Webhook URLs
    echo ""
    echo "n8n Webhook URLs (leave blank to skip):"
    read -p "Lines webhook URL: " N8N_LINES
    read -p "Transactions webhook URL: " N8N_TXNS
    if [[ -n "$N8N_LINES" ]]; then
        sed -i "s|^N8N_LINES_URL=.*|N8N_LINES_URL=$N8N_LINES|" "$ENV_FILE"
    fi
    if [[ -n "$N8N_TXNS" ]]; then
        sed -i "s|^N8N_TXNS_URL=.*|N8N_TXNS_URL=$N8N_TXNS|" "$ENV_FILE"
    fi
    
    # Frigate public URL
    echo ""
    read -p "Frigate public URL (for video links): " FRIGATE_URL
    if [[ -n "$FRIGATE_URL" ]]; then
        sed -i "s|^FRIGATE_URL=.*|FRIGATE_URL=$FRIGATE_URL|" "$ENV_FILE"
    fi
    
    # Cloudflare Tunnel Token
    echo ""
    echo -e "${YELLOW}Cloudflare Tunnel Token${NC}"
    echo "Get this from: https://one.dash.cloudflare.com/ → Zero Trust → Networks → Tunnels"
    read -p "Tunnel token: " CF_TOKEN
    if [[ -n "$CF_TOKEN" ]]; then
        sed -i "s|^CLOUDFLARE_TUNNEL_TOKEN=.*|CLOUDFLARE_TUNNEL_TOKEN=$CF_TOKEN|" "$ENV_FILE"
    else
        log_warn "No Cloudflare token provided - tunnel will not connect"
    fi
    
    echo ""
    log_success "Configuration complete!"
}

# ============================================================================
# Start Services
# ============================================================================
start_services() {
    log_info "Starting services..."
    
    cd "$INSTALL_DIR"
    
    # Pull images
    docker compose pull
    
    # Start services
    docker compose up -d
    
    # Wait for services to start
    sleep 5
    
    log_success "Services started"
}

# ============================================================================
# Print Next Steps
# ============================================================================
print_next_steps() {
    echo ""
    
    if [[ $MODE == "test" ]]; then
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║        Micromanager Test Install Complete!                     ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}(Frigate and Cloudflared skipped in test mode)${NC}"
        echo ""
        echo "Next Steps:"
        echo ""
        echo "  1. Run the emulator to generate test transactions:"
        echo -e "     ${CYAN}docker exec -it micromanager-app npm run emulator -- --random --burst 5${NC}"
        echo ""
        echo "  2. Watch transactions flow through:"
        echo -e "     ${CYAN}docker logs -f micromanager-app | grep -i transaction${NC}"
        echo ""
        echo "  3. Check metrics:"
        echo -e "     ${CYAN}curl http://localhost:3000/metrics${NC}"
        echo ""
        echo "  4. For production config, re-run without --test:"
        echo -e "     ${CYAN}sudo $0${NC}"
        echo ""
        
    elif [[ $MODE == "test-full" ]]; then
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║     \$50 Manager Full Stack Test Install Complete!              ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "Services running:"
        echo -e "  ${GREEN}✓${NC} micromanager-app  (POS parsing)     http://localhost:3000"
        echo -e "  ${GREEN}✓${NC} frigate           (NVR)             http://localhost:8971"
        echo -e "  ${YELLOW}⚠${NC} cloudflared       (tunnel)          Placeholder token - not connected"
        echo ""
        echo "Next Steps:"
        echo ""
        echo "  1. Run the emulator to generate test transactions:"
        echo -e "     ${CYAN}docker exec -it micromanager-app npm run emulator -- --random --burst 5${NC}"
        echo ""
        echo "  2. Watch transactions with video bookmarks:"
        echo -e "     ${CYAN}docker logs -f micromanager-app | grep -i frigate${NC}"
        echo ""
        echo "  3. Check Frigate for bookmarks:"
        echo -e "     ${CYAN}http://localhost:8971${NC}"
        echo ""
        echo "  4. Edit Frigate camera config:"
        echo -e "     ${CYAN}nano $INSTALL_DIR/config/frigate.yml${NC}"
        echo -e "     ${CYAN}docker compose -f $INSTALL_DIR/docker-compose.yml restart frigate${NC}"
        echo ""
        echo "  5. To connect tunnel, add real token:"
        echo -e "     ${CYAN}nano $INSTALL_DIR/.env${NC}"
        echo -e "     ${CYAN}docker compose -f $INSTALL_DIR/docker-compose.yml restart cloudflared${NC}"
        echo ""
        
    else
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║     \$50 Manager IoT Stack Installed Successfully!              ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "Services running:"
        echo -e "  ${GREEN}✓${NC} micromanager-app  (POS parsing)     http://localhost:3000"
        echo -e "  ${GREEN}✓${NC} frigate           (NVR)             http://localhost:8971"
        echo -e "  ${GREEN}✓${NC} cloudflared       (tunnel)          Active"
        echo ""
        echo "Next Steps:"
        echo ""
        echo "  1. Edit Frigate camera config with your camera IPs:"
        echo -e "     ${CYAN}nano $INSTALL_DIR/config/frigate.yml${NC}"
        echo -e "     ${CYAN}docker compose -f $INSTALL_DIR/docker-compose.yml restart frigate${NC}"
        echo ""
        echo "  2. Access Frigate UI to verify cameras:"
        echo -e "     ${CYAN}http://localhost:8971${NC}"
        echo ""
        echo "  3. Test POS connection:"
        echo -e "     ${CYAN}docker logs -f micromanager-app${NC}"
        echo ""
        echo "  4. Edit other config if needed:"
        echo -e "     ${CYAN}nano $INSTALL_DIR/.env${NC}"
        echo -e "     ${CYAN}docker compose -f $INSTALL_DIR/docker-compose.yml restart${NC}"
        echo ""
    fi
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "Install directory: ${CYAN}$INSTALL_DIR${NC}"
    echo -e "Documentation: ${CYAN}https://github.com/FFTY50/micromanager-app${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# ============================================================================
# Main
# ============================================================================
main() {
    print_banner
    
    log_info "Install mode: $MODE"
    echo ""
    
    detect_system
    install_docker
    setup_directories
    setup_emulator_pipe
    copy_default_configs
    generate_env_file
    generate_compose_file
    run_wizard
    start_services
    print_next_steps
}

main "$@"

