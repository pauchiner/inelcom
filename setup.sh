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
readonly DESKTOP_TMP="/tmp/packettracer.desktop.$$"
readonly PACKETTRACER_APP="/opt/pt/packettracer.AppImage"
readonly EULA_STATE_DIR=".local/.packettracer"

readonly JAMMY_FILE="/etc/apt/sources.list.d/packettracer-jammy-temp.list"
readonly JAMMY_TMP="/tmp/packettracer-jammy-$$.list"

JAMMY_ENABLED=0

# ==================================================
# Colores y mensajes
# ==================================================

if [[ -t 1 ]]; then
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[0;33m'
    readonly RED='\033[0;31m'
    readonly BLUE='\033[0;34m'
    readonly RESET='\033[0m'
else
    readonly GREEN=''
    readonly YELLOW=''
    readonly RED=''
    readonly BLUE=''
    readonly RESET=''
fi

log_info() {
    printf '%b[INFO]%b %s\n' "$BLUE" "$RESET" "$*"
}

log_success() {
    printf '%b[OK]%b %s\n' "$GREEN" "$RESET" "$*"
}

log_warning() {
    printf '%b[AVISO]%b %s\n' "$YELLOW" "$RESET" "$*" >&2
}

log_error() {
    printf '%b[ERROR]%b %s\n' "$RED" "$RESET" "$*" >&2
}

log_step() {
    printf '\n%b==> %s%b\n' "$BLUE" "$*" "$RESET"
}

die() {
    log_error "$*"
    exit 1
}

cleanup() {
    local exit_code=$?

    # Evitar que la limpieza se invoque recursivamente.
    trap - EXIT
    trap '' INT TERM HUP

    rm -f "${DESKTOP_TMP:-}"

    if (( JAMMY_ENABLED )); then
        log_info "Desactivando los repositorios temporales de Ubuntu Jammy..."

        if sudo rm -f -- "$JAMMY_FILE"; then
            JAMMY_ENABLED=0

            if sudo apt-get update; then
                log_success "Configuración de APT restaurada."
            else
                log_error "No se han podido actualizar los índices tras retirar Jammy."
                log_warning "Los repositorios temporales se han eliminado, pero revisa APT."
                (( exit_code == 0 )) && exit_code=1
            fi
        else
            log_error "No se ha podido retirar el fichero temporal de Jammy."
            log_error "Revisa manualmente: $JAMMY_FILE"
            (( exit_code == 0 )) && exit_code=1
        fi
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
        sudo
        apt-get
        dpkg
        dpkg-deb
        curl
        install
    )

    local cmd

    for cmd in "${required_commands[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "No se encuentra el comando requerido: $cmd"
    done

    sudo -v

    mkdir -p "$DOWNLOAD_DIR"

    log_success "Requisitos comprobados."
}

# ==================================================
# Preparación del sistema
# ==================================================

prepare_system() {
    log_step "Preparando el sistema"

    log_info "Configurando paquetes pendientes..."
    if ! sudo dpkg --configure -a; then
        log_error "No se han podido configurar los paquetes pendientes."
        return 1
    fi

    log_info "Eliminando paquetes anteriores"
    sudo apt remove --purge -y packettracer packet-tracer 2>/dev/null || true

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

    log_info "Eliminando configuraciones anteriores de todos los usuarios"

    local uid_min username uid gid home users_checked=0

    uid_min="$(awk '$1 == "UID_MIN" { print $2; exit }' \
        /etc/login.defs 2>/dev/null || true)"
    [[ "$uid_min" =~ ^[0-9]+$ ]] || uid_min=1000

    while IFS=: read -r username _ uid gid _ home _; do
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        (( uid >= uid_min )) || continue
        [[ -n "$home" && "$home" != "/" && -d "$home" ]] || continue

        # Evitar directorios home que sean enlaces simbólicos.
        [[ ! -L "$home" ]] || continue

        sudo rm -rf -- \
            "${home}/.config/Cisco-PacketTracer" \
            "${home}/.config/packettracer" \
            "${home}/.local/share/PacketTracer" \
            "${home}/PacketTracer" || {
                log_error "Error eliminando configuraciones de ${username}."
                return 1
            }

        ((users_checked += 1))
        log_info "Configuraciones revisadas para ${username}"
    done < <(getent passwd)

    log_info "Usuarios revisados: ${users_checked}"

    log_info "Limpiando la caché de paquetes"
    if ! sudo apt autoclean; then
        log_error "No se ha podido limpiar la caché de APT."
        return 1
    fi

    log_success "Sistema preparado."
}

# ==================================================
# Activar repositorios de Ubuntu
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

    if ! sudo install -o root -g root -m 644 "$JAMMY_TMP" "$JAMMY_FILE"; then
        rm -f "$JAMMY_TMP"
        die "No se han podido activar los repositorios temporales."
    fi

    rm -f "$JAMMY_TMP"

    JAMMY_ENABLED=1

    log_info "Actualizando los índices de APT..."

    sudo apt-get update ||
        die "Ha fallado apt-get update. Se retirarán los repositorios temporales."

    log_success "Repositorios Ubuntu Jammy activados."
}

# ==================================================
# Descarga y validación del instalador
# ==================================================

download_package() {
    log_step "3/8 - Descargando Packet Tracer ${VERSION}"

    local temp_file="${DEB_FILE}.part"

    if [[ -s "$DEB_FILE" ]] &&
       dpkg-deb --info "$DEB_FILE" >/dev/null 2>&1; then
        log_info "Se reutilizará el paquete existente:"
        printf '       %s\n' "$DEB_FILE"
    else
        rm -f "$DEB_FILE" "$temp_file"

        log_info "Origen: ${DOWNLOAD_URL}"
        log_info "Destino: ${DEB_FILE}"

        if ! curl --fail --location --show-error \
            --retry 3 --retry-delay 2 \
            --output "$temp_file" "$DOWNLOAD_URL"; then
            rm -f "$temp_file"
            die "No se ha podido descargar Packet Tracer."
        fi

        if [[ ! -s "$temp_file" ]] ||
           ! dpkg-deb --info "$temp_file" >/dev/null 2>&1; then
            rm -f "$temp_file"
            die "El archivo descargado no es un paquete DEB válido."
        fi

        mv "$temp_file" "$DEB_FILE"
    fi

    log_success "Paquete disponible y validado."
}

# ==================================================
# Instalación
# ==================================================

install_package() {
    log_step "4/8 - Instalando Packet Tracer"

    log_info "Instalando el paquete DEB..."

    if ! sudo dpkg -i "$DEB_FILE"; then
        log_warning "dpkg ha detectado un error. Intentando resolver dependencias..."

        sudo apt-get --fix-broken install -y ||
            die "No se han podido resolver las dependencias."

        sudo dpkg -i "$DEB_FILE" ||
            die "La instalación del paquete ha fallado."
    fi

    log_info "Comprobando el estado de los paquetes..."
    sudo dpkg --configure -a

    if ! dpkg-query -W \
        -f='${Status}\n' packettracer 2>/dev/null |
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

    local uid_min username uid gid home shell user_state_dir
    local configured=0

    sudo test -x "$PACKETTRACER_APP" ||
        die "No se encuentra el ejecutable esperado: $PACKETTRACER_APP"

    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/packettracer-eula.XXXXXX")"
    eula_file="${temp_dir}/eula-"

    cat > "$eula_file" <<'EULA'
Cisco Packet Tracer Software License Agreement

DOWNLOADING, INSTALLING, OR USING THE CISCO PACKET TRACER SOFTWARE CONSTITUTES ACCEPTANCE OF THE CISCO END USER LICENSE AGREEMENT ("EULA" https://www.cisco.com/c/en/us/about/legal/cloud-and-software/end_user_license_agreement.html) AND THE SUPPLEMENTAL END USER LICENSE AGREEMENT FOR CISCO PACKET TRACER ("SEULA" https://www.cisco.com/c/dam/en_us/about/doing_business/legal/seula/cisco-packet-tracer-software.pdf). IF YOU DO NOT AGREE TO ALL OF THE TERMS OF THE EULA AND SEULA, THEN CISCO SYSTEMS, INC. ("CISCO") IS UNWILLING TO LICENSE THE SOFTWARE TO YOU AND YOU ARE NOT AUTHORIZED TO DOWNLOAD, INSTALL OR USE THE SOFTWARE.
EULA

    sudo install -d -o root -g root -m 755 "/etc/skel/${EULA_STATE_DIR}"
    sudo install -o root -g root -m 644 "$eula_file" \
        "/etc/skel/${EULA_STATE_DIR}/eula-"

    uid_min="$(awk '$1 == "UID_MIN" { print $2; exit }' /etc/login.defs 2>/dev/null || true)"
    [[ "$uid_min" =~ ^[0-9]+$ ]] || uid_min=1000

    while IFS=: read -r username _ uid gid _ home shell; do
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        (( uid >= uid_min )) || continue
        [[ -n "$home" && -d "$home" ]] || continue

        user_state_dir="${home}/${EULA_STATE_DIR}"
        sudo install -d -o "$uid" -g "$gid" -m 755 "$user_state_dir"
        sudo install -o "$uid" -g "$gid" -m 644 "$eula_file" \
            "${user_state_dir}/eula-"

        log_info "Estado de la EULA preparado para ${username}."
        ((configured += 1))
    done < <(getent passwd)

    rm -rf "$temp_dir"

    log_success "Estado de la EULA instalado en /etc/skel y preparado para ${configured} usuario(s) existente(s)."
}

# ==================================================
# Instalación del icono
# ==================================================

install_icon() {
    log_step "6/8 - Instalando el icono"

    local temp_icon
    temp_icon="$(mktemp "${TMPDIR:-/tmp}/packettracer-icon.XXXXXX")"

    if ! curl --fail --location --show-error \
        --retry 3 --retry-delay 2 \
        --output "$temp_icon" "$ICON_URL"; then
        rm -f "$temp_icon"
        die "No se ha podido descargar el icono."
    fi

    if [[ ! -s "$temp_icon" ]] ||
       ! file "$temp_icon" | grep -qi 'PNG image data'; then
        rm -f "$temp_icon"
        die "El archivo descargado no parece ser una imagen PNG válida."
    fi

    sudo install -d -m 755 "$ICON_DIR"
    sudo install -m 644 "$temp_icon" "$ICON_FILE"

    rm -f "$temp_icon"

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

    sudo install -m 644 "$DESKTOP_TMP" "$DESKTOP_FILE"

    if command -v update-desktop-database >/dev/null 2>&1; then
        sudo update-desktop-database /usr/share/applications
    fi

    log_success "Acceso directo creado."
}

# ==================================================
# Resumen final
# ==================================================

show_summary() {
    log_step "8/8 - Verificación final"

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

    log_success "Proceso finalizado sin errores."
    printf '\n'
    printf '  Creado por Pau Chiner y Eva Buendia\n'
    printf '  Inelcom 2026\n'
}

# ==================================================
# Ejecución principal
# ==================================================

main() {
    printf '\n'
    printf '%b==========================================%b\n' "$BLUE" "$RESET"
    printf '  INSTALADOR CISCO PACKET TRACER %s\n' "$VERSION"
    printf '%b==========================================%b\n' "$BLUE" "$RESET"

    check_requirements
    enable_jammy_repositories
    prepare_system
    download_package
    install_package
    provision_eula_state
    install_icon
    create_shortcut
    show_summary
}

main "$@"
