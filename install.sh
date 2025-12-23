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
    
    # Copy Frigate config (only for test-full mode - production generates via wizard)
    if [[ $MODE == "test-full" ]]; then
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
    elif [[ $MODE == "production" ]]; then
        log_info "Frigate config will be generated by wizard..."
    fi
}

# ============================================================================
# Generate Environment File
# ============================================================================
generate_env_file() {
    log_info "Generating environment configuration..."
    
    local ENV_FILE="$INSTALL_DIR/.env"
    local EXISTING_ID=""
    
    # Try to preserve existing MICROMANAGER_ID if file exists
    if [[ -f "$ENV_FILE" ]]; then
        EXISTING_ID=$(grep "^MICROMANAGER_ID=" "$ENV_FILE" | cut -d'=' -f2)
        if [[ -n "$EXISTING_ID" ]]; then
            log_info "Preserving existing MICROMANAGER_ID: $EXISTING_ID"
        fi
    fi
    
    # Use existing ID or generate a fresh one
    local FINAL_ID=${EXISTING_ID:-$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)}
    
    if [[ $MODE == "test" ]]; then
        # Minimal test config
        cat > "$ENV_FILE" << EOF
# Micromanager Test Configuration
# Generated by install.sh --test

# Device
DEVICE_NAME=$(hostname)
MICROMANAGER_ID=$FINAL_ID

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
MICROMANAGER_ID=$FINAL_ID

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
        # Production config - base config, wizard will add per-port settings
        cat > "$ENV_FILE" << EOF
# Micromanager Production Configuration
# Generated by install.sh

# Device
DEVICE_NAME=$(hostname)
MICROMANAGER_ID=$FINAL_ID

# Serial baud rate (applies to all ports)
SERIAL_BAUD=9600

# n8n Webhook URLs
N8N_LINES_URL=
N8N_TXNS_URL=

# Frigate Integration
FRIGATE_ENABLED=true
FRIGATE_BASE=http://frigate:5000
FRIGATE_URL=

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
    image: ffty50/micromanager-app:latest
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
    image: ffty50/micromanager-app:latest
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
    image: ghcr.io/blakeblackshear/frigate:0.16.2
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
    image: ffty50/micromanager-app:latest
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
    image: ghcr.io/blakeblackshear/frigate:0.16.2
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
# Multi-POS Configuration
# ============================================================================
# Global arrays to store POS configuration (populated by configure_multi_pos)
declare -a POS_SERIAL_PORTS=()
declare -a POS_CAMERA_NAMES=()
POS_COUNT=0

configure_multi_pos() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}                   Multi-POS Configuration                         ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Show detected serial ports
    if [[ ${#SERIAL_PORTS[@]} -gt 0 ]]; then
        echo -e "${GREEN}Detected serial ports:${NC}"
        for i in "${!SERIAL_PORTS[@]}"; do
            echo "  [$i] ${SERIAL_PORTS[$i]}"
        done
        echo ""
    else
        echo -e "${YELLOW}No serial ports detected. You can configure manually.${NC}"
        echo ""
    fi
    
    # Ask how many POS registers
    echo "How many POS registers will this device handle?"
    echo "  1 = Single register"
    echo "  2 = Two registers (e.g., front + back counter)"
    echo "  3 = Three registers"
    echo "  4 = Four registers (maximum)"
    echo ""
    
    while true; do
        read -p "Number of POS registers [1]: " POS_COUNT_INPUT
        POS_COUNT_INPUT=${POS_COUNT_INPUT:-1}
        
        if [[ "$POS_COUNT_INPUT" =~ ^[1-4]$ ]]; then
            POS_COUNT=$POS_COUNT_INPUT
            break
        else
            echo -e "${RED}Please enter a number between 1 and 4${NC}"
        fi
    done
    
    echo ""
    log_info "Configuring $POS_COUNT POS register(s)..."
    echo ""
    
    # Configure each POS
    for ((i=0; i<POS_COUNT; i++)); do
        echo -e "${CYAN}─── POS Position $i ───${NC}"
        
        # Default serial port
        local default_port="/dev/ttyUSB$i"
        if [[ $i -lt ${#SERIAL_PORTS[@]} ]]; then
            default_port="${SERIAL_PORTS[$i]}"
        fi
        
        # Default camera name (e.g., POS1, POS2, etc.)
        local default_camera=""
        case $i in
            0) default_camera="POS1" ;;
            1) default_camera="POS2" ;;
            2) default_camera="POS3" ;;
            3) default_camera="POS4" ;;
        esac
        
        # Prompt for serial port
        read -p "  Serial port [$default_port]: " PORT_INPUT
        PORT_INPUT=${PORT_INPUT:-$default_port}
        POS_SERIAL_PORTS+=("$PORT_INPUT")
        
        # Prompt for camera name
        echo "  Camera name in Frigate (e.g., POS1, front_register, left_counter)"
        read -p "  Camera name [$default_camera]: " CAMERA_INPUT
        CAMERA_INPUT=${CAMERA_INPUT:-$default_camera}
        POS_CAMERA_NAMES+=("$CAMERA_INPUT")
        
        echo ""
    done
    
    # Summary
    echo -e "${GREEN}POS Configuration Summary:${NC}"
    echo "┌──────────┬─────────────────┬────────────────────┐"
    echo "│ Position │ Serial Port     │ Camera Name        │"
    echo "├──────────┼─────────────────┼────────────────────┤"
    for ((i=0; i<POS_COUNT; i++)); do
        printf "│ %-8s │ %-15s │ %-18s │\n" "$i" "${POS_SERIAL_PORTS[$i]}" "${POS_CAMERA_NAMES[$i]}"
    done
    echo "└──────────┴─────────────────┴────────────────────┘"
    echo ""
    
    read -p "Is this correct? [Y/n]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[Nn] ]]; then
        # Reset and retry
        POS_SERIAL_PORTS=()
        POS_CAMERA_NAMES=()
        POS_COUNT=0
        configure_multi_pos
    fi
}

# ============================================================================
# Write Multi-POS Config to Environment File
# ============================================================================
write_pos_config_to_env() {
    local ENV_FILE="$1"
    
    # Remove any existing POS config lines
    sed -i '/^SERIAL_PORT_[0-3]=/d' "$ENV_FILE"
    sed -i '/^FRIGATE_CAMERA_[0-3]=/d' "$ENV_FILE"
    sed -i '/^# POS Position/d' "$ENV_FILE"
    
    # Add new POS configuration
    echo "" >> "$ENV_FILE"
    echo "# Multi-POS Configuration (Per-Port Camera Mapping)" >> "$ENV_FILE"
    
    for ((i=0; i<POS_COUNT; i++)); do
        echo "# POS Position $i" >> "$ENV_FILE"
        echo "SERIAL_PORT_$i=${POS_SERIAL_PORTS[$i]}" >> "$ENV_FILE"
        echo "FRIGATE_CAMERA_$i=${POS_CAMERA_NAMES[$i]}" >> "$ENV_FILE"
    done
}

# ============================================================================
# Generate Frigate Config for Multi-POS
# ============================================================================
generate_frigate_config() {
    local CONFIG_FILE="$INSTALL_DIR/config/frigate.yml"
    
    log_info "Generating Frigate configuration for $POS_COUNT camera(s)..."
    
    # Start with base config
    cat > "$CONFIG_FILE" << 'FRIGATE_BASE'
# Frigate NVR Configuration
# Generated by install.sh - Edit camera IPs below

mqtt:
  enabled: false

database:
  path: /db/frigate.db

ffmpeg:
  hwaccel_args: preset-rpi-64-h264

tls:
  enabled: false

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

go2rtc:
  streams:
FRIGATE_BASE

    # Add go2rtc streams for each camera
    for ((i=0; i<POS_COUNT; i++)); do
        local cam_name="${POS_CAMERA_NAMES[$i]}"
        local ip_suffix=$((101 + i))
        cat >> "$CONFIG_FILE" << EOF
    ${cam_name}:
      - rtsp://10.7.7.${ip_suffix}:554/media/live/1/1
    ${cam_name}_sub:
      - rtsp://10.7.7.${ip_suffix}:554/media/live/1/2
EOF
    done
    
    # Add cameras section
    echo "" >> "$CONFIG_FILE"
    echo "cameras:" >> "$CONFIG_FILE"
    
    for ((i=0; i<POS_COUNT; i++)); do
        local cam_name="${POS_CAMERA_NAMES[$i]}"
        local ip_suffix=$((101 + i))
        cat >> "$CONFIG_FILE" << EOF
  ${cam_name}:
    enabled: true
    live:
      streams:
        Main Stream: ${cam_name}_sub
        High Stream: ${cam_name}
    ffmpeg:
      inputs:
        - path: rtsp://10.7.7.${ip_suffix}:554/media/live/1/1
          roles: [record]
        - path: rtsp://10.7.7.${ip_suffix}:554/media/live/1/2
          roles: [detect]
      hwaccel_args: preset-rpi-64-h264
    detect:
      width: 704
      height: 480
      fps: 5
    motion:
      enabled: true
EOF
    done
    
    echo "" >> "$CONFIG_FILE"
    echo "version: 0.16-0" >> "$CONFIG_FILE"
    
    log_success "Frigate config created: $CONFIG_FILE"
    echo -e "${YELLOW}NOTE: Edit camera IP addresses in $CONFIG_FILE to match your setup${NC}"
}

# ============================================================================
# Generate Docker Compose with Dynamic Serial Ports
# ============================================================================
generate_compose_with_pos() {
    local COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
    
    # Build devices list for serial ports
    local DEVICES_YAML=""
    for ((i=0; i<POS_COUNT; i++)); do
        local port="${POS_SERIAL_PORTS[$i]}"
        DEVICES_YAML+="      - ${port}:${port}"$'\n'
    done
    
    cat > "$COMPOSE_FILE" << EOF
# Micromanager Production Configuration
# Generated by install.sh - $POS_COUNT POS register(s)

networks:
  nvrnet:
    name: nvrnet

services:
  micromanager:
    image: ffty50/micromanager-app:latest
    container_name: micromanager-app
    restart: unless-stopped
    networks: [nvrnet]
    devices:
${DEVICES_YAML}    volumes:
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
    image: ghcr.io/blakeblackshear/frigate:0.16.2
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
      - \${FRIGATE_MEDIA_PATH}:/media/frigate
      - \${FRIGATE_DB_PATH}:/db
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
    command: tunnel --no-autoupdate run --token "\${CLOUDFLARE_TUNNEL_TOKEN}"
    depends_on:
      - frigate
    extra_hosts:
      - "host.docker.internal:host-gateway"

volumes:
  micromanager-data:
EOF
    
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
    
    # Multi-POS Configuration
    configure_multi_pos
    
    # Write POS config to env file
    write_pos_config_to_env "$ENV_FILE"
    
    # Generate Frigate config based on POS setup
    generate_frigate_config
    
    # Generate Docker Compose with proper serial port mappings
    generate_compose_with_pos
    
    # n8n Webhook URLs
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}                    Webhook Configuration                          ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
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
    read -p "Frigate public URL (for video links in UI): " FRIGATE_URL
    if [[ -n "$FRIGATE_URL" ]]; then
        sed -i "s|^FRIGATE_URL=.*|FRIGATE_URL=$FRIGATE_URL|" "$ENV_FILE"
    fi
    
    # Cloudflare Tunnel Token
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}                  Cloudflare Tunnel Setup                          ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}Get token from: https://one.dash.cloudflare.com/${NC}"
    echo "  → Zero Trust → Networks → Tunnels → Create tunnel"
    echo ""
    read -p "Tunnel token (leave blank to skip): " CF_TOKEN
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
    
    # Check if services are already running and stop them gracefully
    if docker compose ps --services 2>/dev/null | grep -q .; then
        log_info "Stopping existing containers..."
        docker compose down --remove-orphans 2>/dev/null || true
        sleep 2
    fi
    
    # Pull latest images
    log_info "Pulling latest images..."
    docker compose pull
    
    # Start services with orphan removal
    log_info "Starting containers..."
    docker compose up -d --remove-orphans
    
    # Wait for services to start
    sleep 5
    
    log_success "Services started successfully"
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
        
        # Show POS configuration summary
        if [[ ${#POS_SERIAL_PORTS[@]} -gt 0 ]]; then
            echo -e "${CYAN}POS Configuration:${NC}"
            for ((i=0; i<${#POS_SERIAL_PORTS[@]}; i++)); do
                echo -e "  Position $i: ${POS_SERIAL_PORTS[$i]} → ${POS_CAMERA_NAMES[$i]}"
            done
            echo ""
        fi
        
        echo "Next Steps:"
        echo ""
        echo -e "  ${YELLOW}IMPORTANT: Edit camera IP addresses in Frigate config:${NC}"
        echo -e "     ${CYAN}nano $INSTALL_DIR/config/frigate.yml${NC}"
        echo "     (Replace 10.7.7.10X with your actual camera IPs)"
        echo -e "     ${CYAN}docker compose -f $INSTALL_DIR/docker-compose.yml restart frigate${NC}"
        echo ""
        echo "  2. Access Frigate UI to verify cameras:"
        echo -e "     ${CYAN}http://localhost:8971${NC}"
        echo ""
        echo "  3. Test POS connection:"
        echo -e "     ${CYAN}docker logs -f micromanager-app${NC}"
        echo ""
        echo "  4. Edit configuration if needed:"
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

