#!/usr/bin/env bash
#
# install-sysreptor-kali.sh - automated SysReptor (self-hosted) install for Kali Linux
#
# Follows the manual installation steps from
#   https://docs.sysreptor.com/setup/installation#manual-installation
# with the Kali-specific parts handled for you:
#   * Docker comes from Kali's own "docker.io" package (get.docker.com does not support Kali)
#   * Docker Compose v2 is installed and checked (SysReptor needs v2.20+)
#   * no "newgrp docker" - the script uses sudo for Docker until you log in again
#   * secrets, volumes, first start, admin user and demo data are all done in one go
#
# Usage:
#   chmod +x install-sysreptor-kali.sh
#   ./install-sysreptor-kali.sh            # run as your normal user, NOT with sudo
#
# Options:
#   --dir DIR        parent folder for the "sysreptor" directory   (default: $HOME)
#   --port PORT      local port for the web UI                     (default: 8000)
#   --bind ADDR      address to listen on                          (default: 127.0.0.1)
#   --username NAME  name of the first admin user                  (default: reptor)
#   --encrypt        encrypt database content and uploads at rest
#   --no-demo        do not import the demo projects/designs/templates
#   --reset          wipe a previous/failed SysReptor install first (DELETES its data)
#   -y, --yes        do not ask for confirmation
#   -h, --help       show this help
#
set -Eeuo pipefail

# ----------------------------------------------------------------------------- settings
PARENT_DIR="${HOME}"
PORT="8000"
BIND_ADDR="127.0.0.1"
ADMIN_USER="reptor"
ENCRYPT=0
DEMO_DATA=1
RESET=0
ASSUME_YES=0
BIND_EXPLICIT=0

SETUP_URL="https://github.com/syslifters/sysreptor/releases/latest/download/setup.tar.gz"
DEMO_BASE_URL="https://docs.sysreptor.com/assets"
COMPOSE_MIN_VERSION="2.20.0"      # first version that supports "include:" in compose files
POSTGRES_VERSION="18"             # same value the official install.sh sets for new installs
VOLUMES=(sysreptor-db-data sysreptor-app-data)
START_TIMEOUT=900                 # seconds to wait for the app after "docker compose up"

# ----------------------------------------------------------------------------- output helpers
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'; C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi
STEP=0
step() { STEP=$((STEP + 1)); printf '\n%s[%d] %s%s\n' "${C_BLD}${C_BLU}" "$STEP" "$*" "$C_RST"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s[ok]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '    %s[warn]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '\n%s[error]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

on_error() {
  local code=$1 line=$2 cmd=$3
  if [[ "$BASHPID" != "$$" ]]; then exit "$code"; fi     # inside $(...): let the main shell report it
  printf '\n%s[error]%s line %s: "%s" exited with status %s\n' "$C_RED" "$C_RST" "$line" "$cmd" "$code" >&2
  printf '        Fix the problem shown above and run the script again - it continues\n' >&2
  printf '        from where it stopped.\n' >&2
  exit "$code"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

usage() { sed -n '2,/^set -Eeuo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

confirm() {   # confirm "question" -> 0 = yes
  local answer
  (( ASSUME_YES )) && return 0
  [[ -t 0 ]] || return 1
  read -r -p "    $* [y/N] " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ----------------------------------------------------------------------------- arguments
while (( $# )); do
  case "$1" in
    --dir)       PARENT_DIR="${2:?--dir needs a value}"; shift 2 ;;
    --port)      PORT="${2:?--port needs a value}"; BIND_EXPLICIT=1; shift 2 ;;
    --bind)      BIND_ADDR="${2:?--bind needs a value}"; BIND_EXPLICIT=1; shift 2 ;;
    --username)  ADMIN_USER="${2:?--username needs a value}"; shift 2 ;;
    --encrypt)   ENCRYPT=1; shift ;;
    --no-demo)   DEMO_DATA=0; shift ;;
    --reset)     RESET=1; shift ;;
    -y|--yes)    ASSUME_YES=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "Unknown option: $1 (see --help)" ;;
  esac
done

[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "--port must be a number between 1 and 65535"
[[ "$BIND_ADDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "--bind must be an IPv4 address, e.g. 127.0.0.1 or 0.0.0.0"
[[ "$ADMIN_USER" =~ ^[A-Za-z0-9._@+-]+$ ]] || die "--username may only contain letters, digits and . _ @ + -"

PARENT_DIR="${PARENT_DIR%/}"
INSTALL_DIR="${PARENT_DIR}/sysreptor"
DEPLOY_DIR="${INSTALL_DIR}/deploy"
PENDING_MARKER="${DEPLOY_DIR}/.first-run-pending"   # exists until the admin user was created

# ----------------------------------------------------------------------------- privilege helpers
if (( EUID == 0 )) && [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  die "Run this script as your normal user (without sudo). It asks for sudo itself when needed."
fi

as_root() { if (( EUID == 0 )); then "$@"; else sudo "$@"; fi; }

DOCKER_NEEDS_SUDO=0
dk() { if (( DOCKER_NEEDS_SUDO )); then as_root docker "$@"; else docker "$@"; fi; }
dc() { dk compose "$@"; }                 # always called from inside $DEPLOY_DIR
sudo_hint() { if (( DOCKER_NEEDS_SUDO && EUID != 0 )); then printf 'sudo '; fi; }

version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

compose_version() { dk compose version --short 2>/dev/null | sed 's/^v//; s/[^0-9.].*$//'; }

set_env_var() {   # set_env_var FILE NAME VALUE  - replaces "NAME=", "# NAME=" or appends
  local file=$1 name=$2 value=$3
  if grep -Eq "^[[:space:]]*(#[[:space:]]*)?${name}=" "$file"; then
    sed -i -E "s|^[[:space:]]*(#[[:space:]]*)?${name}=.*|${name}=${value}|" "$file"
  else
    printf '%s=%s\n' "$name" "$value" >> "$file"
  fi
}

# ----------------------------------------------------------------------------- 1. checks
preflight() {
  step "Checking the system"

  command -v apt-get >/dev/null || die "apt-get not found - this script is for Kali/Debian based systems."

  OS_ID="unknown"; OS_NAME="unknown"
  if [[ -r /etc/os-release ]]; then
    OS_ID=$(. /etc/os-release && echo "${ID:-unknown}")
    OS_NAME=$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")
  fi
  if [[ "$OS_ID" == "kali" ]]; then ok "$OS_NAME"; else warn "This is '$OS_NAME', not Kali - continuing, it should work on Debian based systems."; fi

  ARCH=$(dpkg --print-architecture)
  case "$ARCH" in
    amd64|arm64) ok "Architecture: $ARCH" ;;
    *) die "Architecture '$ARCH' is not supported - the SysReptor images exist for amd64 and arm64 only." ;;
  esac

  local mem_mb
  mem_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  if (( mem_mb < 7400 )); then
    warn "Only ${mem_mb} MB RAM - SysReptor recommends 8 GB. If this is a VM, give it more memory when PDF rendering is slow or fails."
  else
    ok "Memory: ${mem_mb} MB"
  fi

  local docker_root=/var/lib/docker free_mb
  [[ -d "$docker_root" ]] || docker_root=/var/lib
  free_mb=$(df -Pm "$docker_root" | awk 'NR == 2 {print $4}')
  if (( free_mb < 6000 )); then
    warn "Only ${free_mb} MB free under ${docker_root} - the images need about 5 GB. The download may fail with 'no space left on device'."
  else
    ok "Free disk space for Docker: ${free_mb} MB"
  fi

  [[ -d "$PARENT_DIR" ]] || die "Folder '$PARENT_DIR' does not exist (see --dir)."
  [[ -w "$PARENT_DIR" ]] || die "Folder '$PARENT_DIR' is not writable for user '$(id -un)' (see --dir)."

  if (( EUID != 0 )); then
    command -v sudo >/dev/null || die "sudo is not installed. Install it or run this script as root."
    info "sudo is needed to install packages and to talk to Docker:"
    sudo -v || die "Could not get sudo rights."
    # keep the sudo session alive while the images download
    ( while sleep 60; do sudo -n true 2>/dev/null || exit 0; done ) &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
  fi
}

# ----------------------------------------------------------------------------- 2. packages
apt_update() {
  local out rc=0
  out=$(as_root apt-get update 2>&1) || rc=$?
  if grep -Eqi 'NO_PUBKEY|EXPKEYSIG|is not signed|invalid signature|Missing key' <<<"$out"; then
    if [[ "$OS_ID" == "kali" ]]; then
      warn "apt reports a repository signing-key problem (Kali rotated its archive key in 2025)."
      info "Installing the current Kali archive keyring and retrying ..."
      local tmp_key
      tmp_key=$(mktemp)
      if command -v curl >/dev/null; then
        curl -fsSL -o "$tmp_key" https://archive.kali.org/archive-keyring.gpg
      else
        wget -q -O "$tmp_key" https://archive.kali.org/archive-keyring.gpg
      fi
      as_root install -m 0644 "$tmp_key" /usr/share/keyrings/kali-archive-keyring.gpg
      rm -f "$tmp_key"
      rc=0
      out=$(as_root apt-get update 2>&1) || rc=$?
    fi
  fi
  if (( rc != 0 )); then
    printf '%s\n' "$out" | tail -n 15 >&2
    die "'apt-get update' failed - fix the repository problem shown above and run the script again."
  fi
}

APT_UPDATED=0
apt_install() {
  if (( ! APT_UPDATED )); then
    info "Refreshing the package lists ..."
    apt_update
    APT_UPDATED=1
  fi
  info "Installing: $*"
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null
}

install_requirements() {
  step "Installing the required tools"
  local missing=() pkg
  local -A tool_pkg=( [curl]=curl [openssl]=openssl [uuidgen]=uuid-runtime [sed]=sed [tar]=tar [gzip]=gzip [ss]=iproute2 )
  for pkg in "${!tool_pkg[@]}"; do
    command -v "$pkg" >/dev/null || missing+=("${tool_pkg[$pkg]}")
  done
  [[ -e /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)
  if (( ${#missing[@]} )); then apt_install "${missing[@]}"; fi
  for pkg in curl openssl uuidgen sed tar; do
    command -v "$pkg" >/dev/null || die "'$pkg' is still missing after the package install - run: sudo apt install -y ${tool_pkg[$pkg]}"
  done
  ok "curl, openssl, uuidgen, sed and tar are available"
}

# ----------------------------------------------------------------------------- 3. docker
start_docker_daemon() {
  if [[ -d /run/systemd/system ]]; then
    as_root systemctl enable --now docker >/dev/null 2>&1 || true
  else
    # no systemd (e.g. Kali in WSL 1 or in a container)
    as_root service docker start >/dev/null 2>&1 || true
  fi
  local _
  for _ in $(seq 1 30); do
    as_root docker info >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

install_compose_binary() {
  local machine url dest=/usr/local/lib/docker/cli-plugins/docker-compose tmp
  machine=$(uname -m)                       # x86_64 or aarch64 - matches the release file names
  url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${machine}"
  info "Downloading the Docker Compose plugin from GitHub ..."
  tmp=$(mktemp)
  curl -fsSL --retry 3 -o "$tmp" "$url"
  as_root install -D -m 0755 "$tmp" "$dest"
  rm -f "$tmp"
}

install_docker() {
  step "Setting up Docker"

  if command -v docker >/dev/null; then
    if docker --version 2>/dev/null | grep -qi podman; then
      die "'docker' on this system is Podman. SysReptor needs real Docker: sudo apt remove podman-docker && run this script again."
    fi
    ok "Docker is already installed: $(docker --version)"
  else
    # get.docker.com (used in the SysReptor docs) aborts on Kali, so use Kali's own package.
    apt_install docker.io
    ok "Installed $(docker --version)"
  fi

  if start_docker_daemon; then
    ok "Docker daemon is running"
  else
    if [[ -d /run/systemd/system ]]; then
      as_root journalctl -u docker --no-pager -n 25 >&2 || true
    fi
    die "The Docker daemon does not start. See the log lines above (try: sudo systemctl status docker)."
  fi

  # Can the current user talk to Docker directly, or do we need sudo for now?
  if docker info >/dev/null 2>&1; then
    DOCKER_NEEDS_SUDO=0
  else
    DOCKER_NEEDS_SUDO=1
    if (( EUID != 0 )); then
      getent group docker >/dev/null || as_root groupadd docker
      if ! id -nG "$(id -un)" | tr ' ' '\n' | grep -qx docker; then
        as_root usermod -aG docker "$(id -un)"
        ok "Added '$(id -un)' to the docker group (active after your next login)"
      fi
      info "Using sudo for Docker during this run."
    fi
  fi

  # Docker Compose v2 (the old python "docker-compose" v1 cannot read SysReptor's compose files)
  local cv
  cv=$(compose_version || true)
  if [[ -z "$cv" ]] || ! version_ge "$cv" "$COMPOSE_MIN_VERSION"; then
    if [[ -n "$cv" ]]; then warn "Docker Compose $cv is too old (need >= $COMPOSE_MIN_VERSION)."; fi
    # docker-compose-plugin exists when Docker's own repository is configured, docker-compose is Kali's package
    apt_install docker-compose-plugin 2>/dev/null || apt_install docker-compose 2>/dev/null || true
    cv=$(compose_version || true)
    if [[ -z "$cv" ]] || ! version_ge "$cv" "$COMPOSE_MIN_VERSION"; then
      install_compose_binary
      cv=$(compose_version || true)
    fi
  fi
  [[ -n "$cv" ]] && version_ge "$cv" "$COMPOSE_MIN_VERSION" \
    || die "Could not get a working 'docker compose' >= $COMPOSE_MIN_VERSION (found: '${cv:-none}')."
  ok "Docker Compose $cv"
}

# ----------------------------------------------------------------------------- 4. existing installs
existing_volumes() {
  local v found=()
  for v in "${VOLUMES[@]}"; do
    dk volume inspect "$v" >/dev/null 2>&1 && found+=("$v")
  done
  printf '%s\n' "${found[@]}"
}

wipe_previous_install() {
  local ids backup v
  mapfile -t ids < <(dk ps -aq --filter "label=com.docker.compose.project=sysreptor")
  if (( ${#ids[@]} )); then
    dk rm -f "${ids[@]}" >/dev/null
    ok "Removed the old SysReptor containers"
  fi
  for v in "${VOLUMES[@]}"; do
    if dk volume inspect "$v" >/dev/null 2>&1; then
      dk volume rm "$v" >/dev/null
      ok "Removed volume $v"
    fi
  done
  if [[ -d "$INSTALL_DIR" ]]; then
    backup="${INSTALL_DIR}.old-$(date +%Y%m%d-%H%M%S)"
    mv "$INSTALL_DIR" "$backup"
    ok "Moved the old folder to $backup"
  fi
}

FRESH_INSTALL=1
check_existing() {
  step "Looking for an earlier SysReptor install"
  local vols
  vols=$(existing_volumes)

  if (( RESET )); then
    if [[ -n "$vols" || -d "$INSTALL_DIR" ]]; then
      warn "--reset: this deletes the SysReptor database and uploaded files on this machine."
      confirm "Really delete the existing SysReptor data?" || die "Aborted - nothing was changed."
      wipe_previous_install
    else
      ok "Nothing to reset"
    fi
    return 0
  fi

  if [[ -f "${DEPLOY_DIR}/app.env" ]]; then
    # A configured install (finished or half-finished): never touch its secrets, just (re)start it.
    FRESH_INSTALL=0
    ok "Found a configured install in $INSTALL_DIR - keeping its settings and data"
    [[ -f "${DEPLOY_DIR}/.env" ]] || : > "${DEPLOY_DIR}/.env"
    if ! grep -Eq '^POSTGRES_PASSWORD=.+' "${DEPLOY_DIR}/.env" && ! grep -qx sysreptor-db-data <<<"$vols"; then
      # the database does not exist yet, so it is still safe to give it proper passwords
      generate_service_passwords "${DEPLOY_DIR}/.env"
    fi
    if (( BIND_EXPLICIT )); then
      set_env_var "${DEPLOY_DIR}/.env" BIND_PORT "\"${BIND_ADDR}:${PORT}:8000\""
    else
      local current
      current=$(sed -n -E 's/^BIND_PORT="?([0-9.]+):([0-9]+):8000"?[[:space:]]*$/\1 \2/p' "${DEPLOY_DIR}/.env" | tail -n1)
      if [[ -n "$current" ]]; then read -r BIND_ADDR PORT <<<"$current"; fi
    fi
    return 0
  fi

  if [[ -n "$vols" ]]; then
    warn "Docker volumes from an earlier attempt exist ($(tr '\n' ' ' <<<"$vols")) but no config in $DEPLOY_DIR."
    info "Their database was created with a password this new setup does not know,"
    info "so the app could not log in to it ('password authentication failed')."
    if confirm "Delete these volumes and start clean? (removes any SysReptor data in them)"; then
      wipe_previous_install
    else
      die "Stopped. Run again with --reset to wipe the old attempt, or restore your old sysreptor/deploy folder."
    fi
    return 0
  fi

  ok "No earlier install found"
}

check_port() {
  command -v ss >/dev/null || return 0
  # our own running app container legitimately holds the port
  if [[ -n "$(dk ps -q --filter name=sysreptor-app 2>/dev/null)" ]]; then return 0; fi
  if [[ -n "$(ss -Hltn "sport = :${PORT}" 2>/dev/null)" ]]; then
    die "Port ${PORT} is already in use by another program (see: sudo ss -ltnp 'sport = :${PORT}'). Stop it or pick another port, e.g. --port 8001"
  fi
}

# ----------------------------------------------------------------------------- 5. download + config
download_setup() {
  step "Downloading the SysReptor setup files"
  local tmp
  tmp=$(mktemp --suffix=.tar.gz)
  curl -fsSL --retry 3 --retry-delay 2 -o "$tmp" "$SETUP_URL" \
    || die "Download failed: $SETUP_URL - check your internet connection / proxy / VPN."
  tar tzf "$tmp" >/dev/null 2>&1 || die "The downloaded file is not a valid archive (a proxy or captive portal may have answered instead of GitHub)."
  tar xzf "$tmp" -C "$PARENT_DIR"
  rm -f "$tmp"
  [[ -f "${DEPLOY_DIR}/app.env.example" ]] || die "Unexpected archive layout: ${DEPLOY_DIR}/app.env.example is missing."
  ok "Extracted to $INSTALL_DIR"
}

generate_service_passwords() {   # generate_service_passwords ENV_FILE
  local file=$1
  chmod 600 "$file"
  set_env_var "$file" POSTGRES_PASSWORD "$(openssl rand -hex 32 | tr -d '\r\n')"
  set_env_var "$file" REDIS_PASSWORD "$(openssl rand -hex 32 | tr -d '\r\n')"
  ok "Generated database and Redis passwords"
}

ENCRYPTION_KEY_LINE=""
configure() {
  step "Creating the configuration and secrets"
  cd "$DEPLOY_DIR"

  # --- app.env: Django secret key (+ optional encryption keys)
  # Built as app.env.new and renamed at the very end, so "app.env exists" always means
  # "configuration is complete" when the script is run again.
  local app_env=app.env.new
  cp app.env.example "$app_env"
  chmod 600 "$app_env"
  local secret_key
  secret_key=$(openssl rand -base64 64 | tr -d '\r\n=')
  sed -i -e "s#.*SECRET_KEY=.*#SECRET_KEY=\"${secret_key}\"#" "$app_env"
  ok "Generated SECRET_KEY"

  if (( ENCRYPT )); then
    local key_id key
    key_id=$(uuidgen | tr -d '\r\n')
    key=$(openssl rand -base64 32 | tr -d '\r\n')
    ENCRYPTION_KEY_LINE="ENCRYPTION_KEYS=[{\"id\": \"${key_id}\", \"key\": \"${key}\", \"cipher\": \"AES-GCM\", \"revoked\": false}]"
    sed -i -e "s#.*DEFAULT_ENCRYPTION_KEY_ID=.*#DEFAULT_ENCRYPTION_KEY_ID=\"${key_id}\"#" \
           -e "s#.*ENCRYPTION_KEYS=.*#${ENCRYPTION_KEY_LINE}#" "$app_env"
    ok "Generated encryption keys (data at rest will be encrypted)"
  fi

  # --- .env: database + redis passwords, postgres version, port
  if [[ ! -f .env ]]; then
    if [[ -f .env.example ]]; then cp .env.example .env; else : > .env; fi
  fi
  generate_service_passwords .env
  if ! grep -Eq '^[[:space:]]*SYSREPTOR_POSTGRES_VERSION=.+' .env; then
    set_env_var .env SYSREPTOR_POSTGRES_VERSION "$POSTGRES_VERSION"
  fi
  if [[ "$BIND_ADDR" != "127.0.0.1" || "$PORT" != "8000" ]]; then
    set_env_var .env BIND_PORT "\"${BIND_ADDR}:${PORT}:8000\""
    ok "Web UI will listen on ${BIND_ADDR}:${PORT}"
  fi

  : > "$PENDING_MARKER"      # admin user + demo data still have to be created
  mv "$app_env" app.env
}

# ----------------------------------------------------------------------------- 6. start
show_app_logs() {
  printf '\n----- last log lines of the containers -----\n' >&2
  dc ps -a >&2 || true
  dc logs --no-color --tail 40 app db >&2 || true
  printf -- '--------------------------------------------\n' >&2
}

launch() {
  step "Downloading the images and starting SysReptor (this takes a few minutes the first time)"
  cd "$DEPLOY_DIR"

  local v
  for v in "${VOLUMES[@]}"; do
    dk volume inspect "$v" >/dev/null 2>&1 || dk volume create "$v" >/dev/null
  done
  ok "Docker volumes are ready"

  local attempt pulled=0
  for attempt in 1 2 3; do
    if dc pull; then pulled=1; break; fi
    if (( attempt < 3 )); then
      warn "Image download failed (attempt ${attempt}/3) - retrying in 10 s ..."
      sleep 10
    fi
  done
  (( pulled )) || die "Could not download the Docker images. Check your connection/VPN/proxy; Docker Hub may also be rate-limiting your IP (try again later or run 'sudo docker login')."

  if ! dc up -d; then
    show_app_logs
    die "'docker compose up -d' failed - see the output above."
  fi

  info "Waiting for the database migrations to finish ..."
  local waited=0
  until dc exec -T app python3 manage.py migrate --check >/dev/null 2>&1 </dev/null; do
    sleep 3
    waited=$((waited + 3))
    if (( waited >= START_TIMEOUT )); then
      show_app_logs
      die "SysReptor did not become ready within ${START_TIMEOUT} s - see the log lines above. If the log shows 'password authentication failed', run the script again with --reset."
    fi
    if (( waited % 30 == 0 )); then info "... still starting (${waited} s)"; fi
  done
  ok "SysReptor is up"
}

ADMIN_PASSWORD=""
create_admin() {
  step "Creating the first admin user"
  cd "$DEPLOY_DIR"
  local password
  password=$(openssl rand -base64 20 | tr -d '\r\n=')
  if dc exec -T -e DJANGO_SUPERUSER_USERNAME="$ADMIN_USER" -e DJANGO_SUPERUSER_PASSWORD="$password" \
        app python3 manage.py createsuperuser --noinput </dev/null >/dev/null 2>&1; then
    ADMIN_PASSWORD="$password"
    ok "Created user '$ADMIN_USER'"
  else
    warn "Could not create user '$ADMIN_USER' (it probably exists already)."
    info "Set a new password with:  cd $DEPLOY_DIR && $(sudo_hint)docker compose exec app python3 manage.py changepassword $ADMIN_USER"
  fi
}

import_demo_data() {
  step "Importing the demo projects, designs and finding templates"
  cd "$DEPLOY_DIR"
  local kind name extra tmp
  tmp=$(mktemp)
  for kind in project design template; do
    name="demo-${kind}s.tar.gz"
    extra=()
    if [[ "$kind" == "project" && -n "$ADMIN_PASSWORD" ]]; then extra=(--add-member="$ADMIN_USER"); fi
    if curl -fsSL --retry 2 -o "$tmp" "${DEMO_BASE_URL}/${name}" \
       && dc exec -T app python3 manage.py importdemodata --type="$kind" "${extra[@]}" <"$tmp" >/dev/null 2>&1; then
      ok "Imported ${name}"
    else
      warn "Could not import ${name} - not critical, SysReptor works without the demo data."
    fi
  done
  rm -f "$tmp"
}

# ----------------------------------------------------------------------------- 7. summary
summary() {
  local host="$BIND_ADDR" sudo_hint
  if [[ "$host" == "0.0.0.0" ]]; then host="<this-machine-ip>"; fi
  sudo_hint=$(sudo_hint)

  printf '\n%s============================================================%s\n' "$C_GRN" "$C_RST"
  printf '%s SysReptor is running%s\n' "$C_BLD" "$C_RST"
  printf '%s============================================================%s\n' "$C_GRN" "$C_RST"
  printf '  URL:        http://%s:%s/\n' "$host" "$PORT"
  if [[ -n "$ADMIN_PASSWORD" ]]; then
    printf '  Username:   %s\n' "$ADMIN_USER"
    printf '  Password:   %s%s%s   <- save it now, it is not stored anywhere\n' "$C_BLD" "$ADMIN_PASSWORD" "$C_RST"
  fi
  printf '  Folder:     %s\n' "$INSTALL_DIR"
  printf '  Settings:   %s/app.env\n' "$DEPLOY_DIR"
  if [[ -n "$ENCRYPTION_KEY_LINE" ]]; then
    printf '\n  %sBack up %s/app.env%s - it holds the encryption key.\n' "$C_YEL" "$DEPLOY_DIR" "$C_RST"
    printf '  Without that key the encrypted data cannot be read again.\n'
  fi
  printf '\n  Stop:       cd %s && %sdocker compose stop\n' "$DEPLOY_DIR" "$sudo_hint"
  printf '  Start:      cd %s && %sdocker compose up -d\n' "$DEPLOY_DIR" "$sudo_hint"
  printf '  Logs:       cd %s && %sdocker compose logs -f app\n' "$DEPLOY_DIR" "$sudo_hint"
  printf '  Update:     cd %s && %sbash update.sh\n' "$INSTALL_DIR" "$sudo_hint"
  if [[ -n "$sudo_hint" ]]; then
    printf '\n  Log out and back in (or reboot) once - after that docker works without sudo.\n'
  fi
  if [[ "$BIND_ADDR" != "127.0.0.1" ]]; then
    printf '\n  %sSysReptor is reachable from the network over plain HTTP.%s Put a web server\n' "$C_YEL" "$C_RST"
    printf '  with HTTPS in front of it: https://docs.sysreptor.com/setup/webserver\n'
  fi
  printf '\n'
}

# ----------------------------------------------------------------------------- main
main() {
  preflight
  install_requirements
  install_docker
  check_existing
  check_port
  if (( FRESH_INSTALL )); then
    download_setup
    configure
  fi
  launch
  if [[ -f "$PENDING_MARKER" ]]; then      # first successful start of an install made by this script
    create_admin
    if (( DEMO_DATA )); then import_demo_data; fi
    rm -f "$PENDING_MARKER"
  fi
  summary
}

main
