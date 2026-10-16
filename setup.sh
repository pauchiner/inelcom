#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# ==================================================
# Cisco Packet Tracer - Instalador
# ==================================================

readonly VERSION="9.0.0"
readonly APP_NAME="Cisco Packet Tracer"
readonly DOWNLOAD_URL="https://github.com/pauchiner/packet-tracer/releases/download/${VERSION}/CiscoPacketTracer.deb"
readonly ICON_URL="https://raw.githubusercontent.com/pauchiner/cisco-packet-tracer-script-test/refs/heads/main/pkt.png"

readonly DOWNLOAD_DIR="${HOME}/packettracer-install"
readonly DEB_FILE="${DOWNLOAD_DIR}/CiscoPacketTracer.deb"
readonly ICON_DIR="/opt/pt/art"
readonly ICON_FILE="${ICON_DIR}/app.png"
readonly DESKTOP_FILE="/usr/share/applications/packettracer.desktop"
readonly PACKETTRACER_APP="/opt/pt/packettracer.AppImage"
readonly EULA_STATE_DIR=".local/.packettracer"

readonly JAMMY_FILE="/etc/apt/sources.list.d/packettracer-jammy-temp.list"
readonly JAMMY_TMP="/tmp/packettracer-jammy-$$.list"

JAMMY_ENABLED=0
DESKTOP_TMP=""
TEMP_DIR=""
TEMP_ICON=""
TEMP_DEB=""
LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/packettracer-install.XXXXXX.log")"
chmod 600 "$LOG_FILE"

# ==================================================
# Colores y mensajes
# ==================================================

if [[ -t 1 ]]; then
    readonly GREEN='\033[0;32m'
    readonly TEAL='\033[0;36m'
    readonly YELLOW='\033[0;33m'
    readonly RED='\033[0;31m'
    readonly BLUE='\033[0;34m'
    readonly RESET='\033[0m'
else
    readonly GREEN=''
    readonly TEAL=''
    readonly YELLOW=''
    readonly RED=''
    readonly BLUE=''
    readonly RESET=''
fi

log_info()    { printf '%b[INFO]%b %s\n' "$BLUE" "$RESET" "$*"; }
log_success() { printf '%b[OK]%b %s\n' "$GREEN" "$RESET" "$*"; }
log_warning() { printf '%b[AVISO]%b %s\n' "$YELLOW" "$RESET" "$*" >&2; }
log_error()   { printf '%b[ERROR]%b %s\n' "$RED" "$RESET" "$*" >&2; }
log_step()    { printf '\n%b==> %s%b\n' "$BLUE" "$*" "$RESET"; }

log_task() {
    local message="$1"
    shift

    if [[ ! -t 1 ]]; then
        "$@" >>"$LOG_FILE" 2>&1
        return $?
    fi

    local frames='|/-\' frame_index=0 pid status
    "$@" >>"$LOG_FILE" 2>&1 &
    pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        printf '\r\033[K%b[%s]%b %s' "$TEAL" "${frames:frame_index%4:1}" "$RESET" "$message"
        frame_index=$((frame_index + 1))
        sleep 0.12
    done

    if wait "$pid"; then
        printf '\r\033[K%b[OK]%b %s\n' "$GREEN" "$RESET" "$message"
    else
        status=$?
        printf '\r\033[K%b[ERROR]%b %s\n' "$RED" "$RESET" "$message" >&2
        return "$status"
    fi
}

show_command_log() {
    if [[ -s "${LOG_FILE:-}" ]]; then
        printf '\n%b--- Detalles técnicos (últimas 60 líneas) ---%b\n' "$YELLOW" "$RESET" >&2
        tail -n 60 -- "$LOG_FILE" >&2 || true
        printf '%b--- Fin de los detalles técnicos ---%b\n' "$YELLOW" "$RESET" >&2
        printf 'Log completo: %s\n' "$LOG_FILE" >&2
    fi
}

die() {
    log_error "$*"
    show_command_log
    exit 1
}

# ==================================================
# Limpieza y gestión de errores
# ==================================================

cleanup() {
    local exit_code=$?

    trap - EXIT
    trap '' INT TERM HUP

    [[ -z "${DESKTOP_TMP:-}" ]] || rm -f -- "$DESKTOP_TMP"
    [[ -z "${TEMP_ICON:-}" ]] || rm -f -- "$TEMP_ICON"
    [[ -z "${TEMP_DEB:-}" ]] || rm -f -- "$TEMP_DEB"
    [[ -z "${TEMP_DIR:-}" ]] || rm -rf -- "$TEMP_DIR"
    rm -f -- "$JAMMY_TMP"

    if (( JAMMY_ENABLED )); then
        if sudo rm -f -- "$JAMMY_FILE" >>"$LOG_FILE" 2>&1; then
            JAMMY_ENABLED=0

            if ! sudo apt-get update -qq >>"$LOG_FILE" 2>&1; then
                (( exit_code == 0 )) && exit_code=1
            fi
        else
            (( exit_code == 0 )) && exit_code=1
        fi
    fi

    if (( exit_code == 0 )); then
        rm -f -- "$LOG_FILE"
    elif [[ -s "$LOG_FILE" ]]; then
        log_warning "Se conserva el log técnico en: $LOG_FILE"
    fi

    exit "$exit_code"
}

on_error() {
    local exit_code=$?
    local line="${1:-?}"
    local command="${2:-desconocido}"

    log_error "El proceso ha fallado en la línea ${line}."
    log_error "Comando: ${command}"
    log_error "Código de salida: ${exit_code}"
    log_error "Consulta los mensajes anteriores para identificar la causa."
    show_command_log

    exit "$exit_code"
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
trap cleanup EXIT

# ==================================================
# Comprobaciones iniciales
# ==================================================

check_requirements() {
    log_step "1/8 - Comprobando requisitos"

    [[ "$EUID" -ne 0 ]] ||
        die "Ejecuta el script con tu usuario habitual, no como root."

    local required_commands=(
        sudo apt-get dpkg dpkg-deb dpkg-query curl install
        file awk getent grep mktemp
    )
    local cmd

    for cmd in "${required_commands[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "No se encuentra el comando requerido: $cmd"
    done

    sudo -v
    mkdir -p -- "$DOWNLOAD_DIR"

    log_success "Requisitos comprobados."
}

# ==================================================
# Preparación del sistema
# ==================================================

prepare_system() {
    log_step "Preparando el sistema"

    log_task "Configurando paquetes pendientes" sudo dpkg --configure -a ||
        die "No se han podido configurar los paquetes pendientes."

    log_info "Eliminando paquetes anteriores"
    local old_package found_old_package=0
    for old_package in packettracer packet-tracer; do
        if dpkg-query -W -f='${Status}\n' "$old_package" 2>/dev/null |
            grep -qx 'install ok installed'; then
            found_old_package=1
            log_task "Eliminando paquete anterior: ${old_package}" \
                sudo apt-get remove --purge -y -qq "$old_package" ||
                die "No se ha podido eliminar el paquete ${old_package}."
        fi
    done

    if (( found_old_package == 0 )); then
        log_info "No se han encontrado paquetes anteriores instalados."
    fi

    log_info "Eliminando accesos directos anteriores"
    sudo rm -f -- \
        /usr/share/applications/packettracer.desktop \
        /usr/share/applications/cisco-ptsa821.desktop \
        /usr/share/applications/cisco-pt821.desktop \
        /usr/share/icons/packettracer.png

    log_info "Eliminando instalaciones anteriores"
    sudo rm -rf -- \
        /usr/local/packettracer \
        /opt/packettracer \
        /opt/pt

    log_info "Eliminando configuraciones anteriores de usuarios"

    local uid_min username uid gid home users_checked=0

    uid_min="$(awk '$1 == "UID_MIN" { print $2; exit }' \
        /etc/login.defs 2>/dev/null || true)"
    [[ "$uid_min" =~ ^[0-9]+$ ]] || uid_min=1000

    while IFS=: read -r username _ uid gid _ home _; do
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        (( uid >= uid_min )) || continue
        [[ -n "$home" && "$home" != "/" && -d "$home" ]] || continue
        [[ ! -L "$home" ]] || {
            log_warning "Se omite el home enlazado simbólicamente de ${username}: ${home}"
            continue
        }

        sudo rm -rf -- \
            "${home}/.config/Cisco-PacketTracer" \
            "${home}/.config/packettracer" \
            "${home}/.local/share/PacketTracer" \
            "${home}/PacketTracer" ||
            die "Error eliminando configuraciones de ${username}."

        users_checked=$((users_checked + 1))
        log_info "Configuraciones revisadas para ${username}"
    done < <(getent passwd)

    log_info "Usuarios revisados: ${users_checked}"

    log_task "Limpiando la caché de paquetes" sudo apt-get autoclean -qq ||
        die "No se ha podido limpiar la caché de APT."

    log_success "Sistema preparado."
}

# ==================================================
# Activar repositorios de Ubuntu temporalmente
# ==================================================

enable_jammy_repositories() {
    log_step "2/8 - Activando temporalmente los repositorios Ubuntu Jammy"

    if sudo test -e "$JAMMY_FILE"; then
        die "Ya existe $JAMMY_FILE. Revisa su contenido antes de continuar."
    fi

    cat > "$JAMMY_TMP" <<'EOF'
deb https://archive.ubuntu.com/ubuntu jammy main restricted universe multiverse
deb https://archive.ubuntu.com/ubuntu jammy-updates main restricted universe multiverse
deb https://security.ubuntu.com/ubuntu jammy-security main restricted universe multiverse
EOF

    if ! sudo install -o root -g root -m 644 "$JAMMY_TMP" "$JAMMY_FILE" >>"$LOG_FILE" 2>&1; then
        rm -f -- "$JAMMY_TMP"
        die "No se han podido activar los repositorios temporales."
    fi

    rm -f -- "$JAMMY_TMP"
    JAMMY_ENABLED=1

    log_task "Actualizando los índices de APT" sudo apt-get update -qq ||
        die "Ha fallado apt-get update. Se retirarán los repositorios temporales."

    log_success "Repositorios Ubuntu Jammy activados."
}

# ==================================================
# Descarga y validación del instalador
# ==================================================

validate_deb() {
    local deb_path="$1"
    local package_name package_version

    [[ -s "$deb_path" ]] ||
        die "El paquete DEB está vacío o no existe: $deb_path"

    dpkg-deb --info "$deb_path" >/dev/null 2>&1 ||
        die "El archivo no es un paquete DEB válido."

    package_name="$(dpkg-deb -f "$deb_path" Package)"
    package_version="$(dpkg-deb -f "$deb_path" Version)"

    [[ "$package_name" == "packettracer" ]] ||
        die "El paquete descargado tiene un nombre inesperado: ${package_name}"

    log_info "Paquete validado: ${package_name}, versión ${package_version}"
}

download_package() {
    log_step "3/8 - Descargando Packet Tracer ${VERSION}"

    TEMP_DEB="${DEB_FILE}.part"

    if [[ -s "$DEB_FILE" ]] &&
        dpkg-deb --info "$DEB_FILE" >/dev/null 2>&1 &&
        [[ "$(dpkg-deb -f "$DEB_FILE" Package 2>/dev/null || true)" == "packettracer" ]]; then
        log_info "Se reutilizará el paquete DEB existente: ${DEB_FILE}"
        log_info "Versión del paquete: $(dpkg-deb -f "$DEB_FILE" Version)"
    else
        rm -f -- "$DEB_FILE" "$TEMP_DEB"

        log_info "Origen: ${DOWNLOAD_URL}"
        log_info "Destino: ${DEB_FILE}"

        if ! log_task "Descargando Packet Tracer" \
            curl --fail --location --silent --show-error \
            --retry 3 --retry-delay 2 \
            --output "$TEMP_DEB" "$DOWNLOAD_URL"; then
            rm -f -- "$TEMP_DEB"
            die "No se ha podido descargar Packet Tracer."
        fi

        validate_deb "$TEMP_DEB"
        mv -- "$TEMP_DEB" "$DEB_FILE"
        TEMP_DEB=""
    fi

    log_success "Paquete disponible y validado."
}

# ==================================================
# Instalación
# ==================================================

install_package() {
    log_step "4/8 - Instalando Packet Tracer"

    if ! log_task "Instalando el paquete DEB" sudo dpkg -i "$DEB_FILE"; then
        log_warning "dpkg ha detectado un error. Intentando resolver dependencias..."

        log_task "Resolviendo dependencias" sudo apt-get --fix-broken install -y -qq ||
            die "No se han podido resolver las dependencias."

        log_task "Reintentando la instalación de Packet Tracer" sudo dpkg -i "$DEB_FILE" ||
            die "La instalación del paquete ha fallado."
    fi

    log_task "Configurando los paquetes instalados" sudo dpkg --configure -a ||
        die "No se han podido configurar los paquetes después de la instalación."

    if ! dpkg-query -W -f='${Status}\n' packettracer 2>/dev/null |
        grep -qx 'install ok installed'; then
        die "Packet Tracer no figura como instalado."
    fi

    log_success "Packet Tracer instalado correctamente."
}

# ==================================================
# Preparación de la EULA para usuarios existentes y futuros
# ==================================================

provision_eula_state() {
    log_step "5/8 - Preparando la EULA para todos los usuarios"

    local uid_min username uid gid home user_state_dir configured=0

    sudo test -x "$PACKETTRACER_APP" ||
        die "No se encuentra el ejecutable esperado: $PACKETTRACER_APP"

    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/packettracer-eula.XXXXXX")"
    local eula_file="${TEMP_DIR}/eula-"

    cat > "$eula_file" <<'EULA'
Cisco Packet Tracer Software License Agreement

DOWNLOADING, INSTALLING, OR USING THE CISCO PACKET TRACER SOFTWARE CONSTITUTES ACCEPTANCE OF THE CISCO END USER LICENSE AGREEMENT ("EULA" https://www.cisco.com/c/en/us/about/legal/cloud-and-software/end_user_license_agreement.html) AND THE SUPPLEMENTAL END USER LICENSE AGREEMENT FOR CISCO PACKET TRACER ("SEULA" https://www.cisco.com/c/dam/en_us/about/doing_business/legal/seula/cisco-packet-tracer-software.pdf). IF YOU DO NOT AGREE TO ALL OF THE TERMS OF THE EULA AND SEULA, THEN CISCO SYSTEMS, INC. ("CISCO") IS UNWILLING TO LICENSE THE SOFTWARE TO YOU AND YOU ARE NOT AUTHORIZED TO DOWNLOAD, INSTALL OR USE THE SOFTWARE.
EULA

    sudo install -d -o root -g root -m 755 "/etc/skel/${EULA_STATE_DIR}"
    sudo install -o root -g root -m 644 "$eula_file" \
        "/etc/skel/${EULA_STATE_DIR}/eula-"

    uid_min="$(awk '$1 == "UID_MIN" { print $2; exit }' \
        /etc/login.defs 2>/dev/null || true)"
    [[ "$uid_min" =~ ^[0-9]+$ ]] || uid_min=1000

    while IFS=: read -r username _ uid gid _ home _; do
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        (( uid >= uid_min )) || continue
        [[ -n "$home" && "$home" != "/" && -d "$home" ]] || continue
        [[ ! -L "$home" ]] || {
            log_warning "Se omite el home enlazado simbólicamente de ${username}: ${home}"
            continue
        }

        user_state_dir="${home}/${EULA_STATE_DIR}"

        if sudo test -L "$user_state_dir"; then
            log_warning "Se omite la ruta de EULA enlazada simbólicamente de ${username}."
            continue
        fi

        sudo install -d -o "$uid" -g "$gid" -m 755 "$user_state_dir"
        sudo install -o "$uid" -g "$gid" -m 644 "$eula_file" \
            "${user_state_dir}/eula-"

        log_info "Estado de la EULA preparado para ${username}."
        configured=$((configured + 1))
    done < <(getent passwd)

    log_success "Estado de la EULA instalado en /etc/skel y preparado para ${configured} usuario(s) existente(s)."
}

# ==================================================
# Instalación del icono
# ==================================================

install_icon() {
    log_step "6/8 - Instalando el icono"

    TEMP_ICON="$(mktemp "${TMPDIR:-/tmp}/packettracer-icon.XXXXXX")"

    if ! log_task "Descargando el icono" \
        curl --fail --location --silent --show-error \
        --retry 3 --retry-delay 2 \
        --output "$TEMP_ICON" "$ICON_URL"; then
        die "No se ha podido descargar el icono."
    fi

    if [[ ! -s "$TEMP_ICON" ]] ||
        ! file "$TEMP_ICON" | grep -qi 'PNG image data'; then
        die "El archivo descargado no parece ser una imagen PNG válida."
    fi

    sudo install -d -o root -g root -m 755 "$ICON_DIR"
    sudo install -o root -g root -m 644 "$TEMP_ICON" "$ICON_FILE"

    rm -f -- "$TEMP_ICON"
    TEMP_ICON=""

    log_success "Icono instalado en ${ICON_FILE}."
}

# ==================================================
# Acceso directo
# ==================================================

create_shortcut() {
    log_step "7/8 - Creando acceso directo"

    local executable="/usr/local/bin/packettracer"

    if [[ ! -x "$executable" ]]; then
        executable="$(command -v packettracer || true)"
    fi

    [[ -n "$executable" && -x "$executable" ]] ||
        die "No se encuentra el ejecutable de Packet Tracer."

    DESKTOP_TMP="$(mktemp "${TMPDIR:-/tmp}/packettracer-desktop.XXXXXX")"

    cat > "$DESKTOP_TMP" <<EOF
[Desktop Entry]
Version=${VERSION}
Type=Application
Name=${APP_NAME}
Comment=Herramienta de simulación de redes
Exec=${executable}
Icon=${ICON_FILE}
Terminal=false
Categories=Education;Network;
StartupNotify=true
EOF

    sudo install -o root -g root -m 644 "$DESKTOP_TMP" "$DESKTOP_FILE"

    if command -v update-desktop-database >/dev/null 2>&1; then
        sudo update-desktop-database /usr/share/applications >>"$LOG_FILE" 2>&1 ||
            die "No se ha podido actualizar la base de datos de aplicaciones."
    fi

    rm -f -- "$DESKTOP_TMP"
    DESKTOP_TMP=""

    log_success "Acceso directo creado."
}

# ==================================================
# Resumen final
# ==================================================

show_summary() {
    log_step "8/8 - Verificación final"

    [[ -x "$PACKETTRACER_APP" ]] ||
        die "No se encuentra el ejecutable instalado: ${PACKETTRACER_APP}"
    sudo test -s "$ICON_FILE" ||
        die "No se encuentra el icono instalado: ${ICON_FILE}"
    sudo test -s "$DESKTOP_FILE" ||
        die "No se encuentra el acceso directo: ${DESKTOP_FILE}"

    printf '\n'
    printf '%b==========================================%b\n' "$GREEN" "$RESET"
    printf '  INSTALACIÓN COMPLETADA\n'
    printf '%b==========================================%b\n' "$GREEN" "$RESET"

    printf '\n'
    printf '  Aplicación:     %s %s\n' "$APP_NAME" "$VERSION"
    printf '  Instalador:     %s\n' "$DEB_FILE"
    printf '  Acceso directo: %s\n' "$DESKTOP_FILE"
    printf '  Icono:          %s\n' "$ICON_FILE"

    printf '\n'
    printf '  Puedes abrir Packet Tracer desde el menú de aplicaciones\n'
    printf '  o ejecutando:\n\n'
    printf '      packettracer\n\n'

    printf '\n'
    printf '  Creado por %bPau Chiner%b y %bEva Buendia%b\n' "$BLUE" "$RESET" "$BLUE" "$RESET"
    printf '\n'
    printf '  %bInelcom 2026%b\n' "$TEAL" "$RESET"
    printf '\n'
}

# ==================================================
# Ejecución principal
# ==================================================

main() {
    printf '\n'
    printf '%b==========================================%b\n' "$BLUE" "$RESET"
    printf '  INSTALADOR CISCO PACKET TRACER %s\n'     |"$VERSION"
    printf '%b==========================================%b\n' "$BLUE" "$RESET"

    check_requirements
    prepare_system
    enable_jammy_repositories
    download_package
    install_package
    provision_eula_state
    install_icon
    create_shortcut
    show_summary
    cleanup
}

main "$@"
