#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# ==================================================
# Configuración de escáner - Samba
# ==================================================

readonly SMB_CONF="/etc/samba/smb.conf"
readonly SCAN_DIR="/escaner"
readonly SHARE_NAME="escaner"
readonly DESKTOP_NAME="Escaner.desktop"

BACKUP_FILE=""
TEMP_FILE=""
DESKTOP_TMP=""
LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/escaner.XXXXXX.log")"

chmod 600 "$LOG_FILE"

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

    trap - EXIT

    [[ -z "${TEMP_FILE:-}" ]] || rm -f -- "$TEMP_FILE"
    [[ -z "${DESKTOP_TMP:-}" ]] || rm -f -- "$DESKTOP_TMP"

    if (( exit_code == 0 )); then
        rm -f -- "$LOG_FILE"
    else
        log_warning "Log técnico: $LOG_FILE"
    fi

    exit "$exit_code"
}

trap cleanup EXIT

# ==================================================
# 1. Comprobación de requisitos
# ==================================================

check_requirements() {
    log_step "1/5 - Comprobando requisitos"

    [[ "$EUID" -ne 0 ]] ||
        die "Ejecuta el script con tu usuario habitual, no como root."

    command -v sudo >/dev/null 2>&1 ||
        die "No se encuentra el comando sudo."

    command -v awk >/dev/null 2>&1 ||
        die "No se encuentra el comando awk."

    command -v mktemp >/dev/null 2>&1 ||
        die "No se encuentra el comando mktemp."

    command -v systemctl >/dev/null 2>&1 ||
        die "No se encuentra el comando systemctl."

    sudo -v

    sudo test -f "$SMB_CONF" ||
        die "No se encuentra $SMB_CONF."

    log_success "Requisitos comprobados."
}

# ==================================================
# 2. Instalación de Samba
# ==================================================

install_samba() {
    log_step "2/5 - Comprobando instalación de Samba"

    if command -v smbd >/dev/null 2>&1; then
        log_info "Samba ya está instalado."
        return
    fi

    log_info "Instalando Samba..."

    sudo apt-get install -y samba >> "$LOG_FILE" 2>&1 ||
        die "No se ha podido instalar Samba."

    command -v smbd >/dev/null 2>&1 ||
        die "Samba no se ha instalado correctamente."

    log_success "Samba instalado correctamente."
}

# ==================================================
# 3. Configuración de Samba
# ==================================================

configure_samba() {
    log_step "3/5 - Configurando el recurso compartido"

    BACKUP_FILE="${SMB_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
    TEMP_FILE="$(mktemp "${TMPDIR:-/tmp}/smb-conf.XXXXXX")"

    sudo cp -p -- "$SMB_CONF" "$BACKUP_FILE" ||
        die "No se ha podido crear la copia de seguridad."

    sudo cat "$SMB_CONF" > "$TEMP_FILE" ||
        die "No se ha podido leer smb.conf."

    # Evitar duplicar el recurso compartido.

    if grep -qE "^[[:space:]]*\[$SHARE_NAME\][[:space:]]*$" "$TEMP_FILE"; then
        die "Ya existe el recurso [$SHARE_NAME] en smb.conf. Revisa su configuración."
    fi

    # Añadir map to guest dentro de [global], si no existe.

    local global_tmp
    global_tmp="$(mktemp "${TMPDIR:-/tmp}/smb-global.XXXXXX")"

    awk '
        BEGIN {
            in_global = 0
            global_found = 0
            global_section = 0
        }

        /^[[:space:]]*\[global\][[:space:]]*$/ {
            in_global = 1
            global_section = 1
        }

        /^[[:space:]]*\[[^]]+\]/ && $0 !~ /^[[:space:]]*\[global\][[:space:]]*$/ {
            if (in_global && !global_found) {
                print "   map to guest = Bad User"
            }
            in_global = 0
        }

        in_global && /^[[:space:]]*map[[:space:]]+to[[:space:]]+guest[[:space:]]*=/ {
            global_found = 1
        }

        { print }

        END {
            if (in_global && !global_found) {
                print "   map to guest = Bad User"
            }

            if (!global_section) {
                exit 10
            }
        }
    ' "$TEMP_FILE" > "$global_tmp" ||
        {
            rm -f "$global_tmp"
            die "No se ha encontrado la sección [global]."
        }

    cat "$global_tmp" > "$TEMP_FILE"
    rm -f "$global_tmp"

    # Añadir el recurso compartido.

    cat >> "$TEMP_FILE" <<EOF

[$SHARE_NAME]
comment = Carpeta para escanear por Samba
path = $SCAN_DIR
browseable = yes
writable = yes
guest ok = yes

EOF

    # Validar antes de aplicar los cambios.

    sudo testparm -s "$TEMP_FILE" >> "$LOG_FILE" 2>&1 ||
        die "La configuración de Samba no es válida."

    sudo install -o root -g root -m 0644 \
        "$TEMP_FILE" "${SMB_CONF}.new" ||
        die "No se ha podido preparar smb.conf."

    sudo mv -f -- "${SMB_CONF}.new" "$SMB_CONF" ||
        die "No se ha podido actualizar smb.conf."

    log_success "Configuración de Samba actualizada."
    log_info "Copia de seguridad: $BACKUP_FILE"
}

# ==================================================
# 4. Creación de carpeta y accesos directos
# ==================================================

configure_scan_directory() {
    log_step "4/5 - Creando carpeta de escaneo"

    sudo mkdir -p "$SCAN_DIR" ||
        die "No se ha podido crear $SCAN_DIR."

    sudo chmod 777 "$SCAN_DIR" ||
        die "No se han podido asignar los permisos 777."

    log_success "Carpeta $SCAN_DIR creada con permisos 777."
}

create_desktop_shortcuts() {
    log_step "5/5 - Preparando accesos directos para todos los usuarios"

    local uid_min username uid gid home shell
    local user_desktop desktop_setting desktop_count=0
    local skeleton_count=0

    DESKTOP_TMP="$(mktemp "${TMPDIR:-/tmp}/escaner-desktop.XXXXXX")"

    # Crear el archivo .desktop.

    cat > "$DESKTOP_TMP" <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Carpeta de escáner
Comment=Acceso a la carpeta compartida de escaneo
Icon=scanner
Exec=xdg-open /escaner
Terminal=false
Categories=Utility;
EOF

    # --------------------------------------------------
    # Preparar /etc/skel para futuros usuarios.
    # --------------------------------------------------

    log_info "Preparando acceso directo para nuevos usuarios..."

    for user_desktop in Desktop Escritorio; do

        sudo install -d -o root -g root -m 755 \
            "/etc/skel/$user_desktop" ||
            die "No se ha podido preparar /etc/skel/$user_desktop."

        sudo install -o root -g root -m 755 \
            "$DESKTOP_TMP" "/etc/skel/$user_desktop/$DESKTOP_NAME" ||
            die "No se ha podido instalar el acceso directo en /etc/skel."

    done

    skeleton_count=1

    log_success "Acceso directo preparado en /etc/skel para futuros usuarios."

    # --------------------------------------------------
    # Detectar usuarios existentes.
    # --------------------------------------------------

    uid_min="$(awk '$1 == "UID_MIN" { print $2; exit }' \
        /etc/login.defs 2>/dev/null || true)"

    [[ "$uid_min" =~ ^[0-9]+$ ]] || uid_min=1000

    log_info "Buscando usuarios existentes (UID_MIN=$uid_min)..."

    while IFS=: read -r username _ uid gid _ home shell; do

        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        (( uid >= uid_min )) || continue

        [[ -n "$home" && "$home" != "/" && -d "$home" ]] || continue

        if [[ -L "$home" ]]; then
            log_warning "Se omite el home enlazado simbólicamente de $username."
            continue
        fi

        # --------------------------------------------------
        # Detectar el escritorio configurado.
        # --------------------------------------------------

        desktop_setting=""

        if [[ -f "$home/.config/user-dirs.dirs" ]]; then
            desktop_setting="$(
                sed -n 's/^XDG_DESKTOP_DIR="\([^"]*\)"/\1/p' \
                    "$home/.config/user-dirs.dirs" |
                    head -n 1
            )"
        fi

        if [[ -n "$desktop_setting" ]]; then

            case "$desktop_setting" in
                '$HOME/'*)
                    user_desktop="$home/${desktop_setting#'$HOME/'}"
                    ;;
                '${HOME}/'*)
                    user_desktop="$home/${desktop_setting#'${HOME}/'}"
                    ;;
                /*)
                    user_desktop="$desktop_setting"
                    ;;
                *)
                    user_desktop="$home/$desktop_setting"
                    ;;
            esac

        elif [[ -d "$home/Escritorio" ]]; then
            user_desktop="$home/Escritorio"

        elif [[ -d "$home/Desktop" ]]; then
            user_desktop="$home/Desktop"

        else
            user_desktop="$home/Escritorio"
        fi

        # --------------------------------------------------
        # Comprobar y crear el acceso directo.
        # --------------------------------------------------

        if sudo test -L "$user_desktop"; then
            log_warning "Se omite el escritorio enlazado de $username."
            continue
        fi

        sudo install -d -o "$uid" -g "$gid" -m 755 \
            "$user_desktop" ||
            die "No se ha podido preparar el escritorio de $username."

        sudo install -o "$uid" -g "$gid" -m 755 \
            "$DESKTOP_TMP" "$user_desktop/$DESKTOP_NAME" ||
            die "No se ha podido crear el acceso directo de $username."

        log_success "Acceso directo instalado para $username."

        (( desktop_count += 1 ))

    done < <(getent passwd)

    log_success "Accesos directos preparados para $desktop_count usuario(s) existente(s)."
    log_success "Plantilla preparada para futuros usuarios."
}

# ==================================================
# Verificación y reinicio de Samba
# ==================================================

verify_configuration() {
    log_step "Verificando configuración"

    sudo testparm -s "$SMB_CONF" >> "$LOG_FILE" 2>&1 ||
        die "La configuración final de Samba no es válida."

    sudo test -d "$SCAN_DIR" ||
        die "No se encuentra la carpeta de escaneo."

    local permissions
    permissions="$(stat -c '%a' "$SCAN_DIR")"

    [[ "$permissions" == "777" ]] ||
        die "Los permisos de $SCAN_DIR no son 777."

    sudo systemctl restart smbd ||
        die "No se ha podido reiniciar el servicio Samba."

    sudo systemctl is-active --quiet smbd ||
        die "El servicio Samba no está activo."

    log_success "Configuración verificada."
    log_success "Servicio Samba reiniciado correctamente."
}

# ==================================================
# MAIN
# ==================================================

main() {
    printf '\n'
    printf '%b==========================================%b\n' "$BLUE" "$RESET"
    printf '       CONFIGURACIÓN DE ESCÁNER - SAMBA\n'
    printf '%b==========================================%b\n' "$BLUE" "$RESET"

    check_requirements
    install_samba
    configure_samba
    configure_scan_directory
    create_desktop_shortcuts
    verify_configuration

    local hostname
    hostname="$(hostname -f 2>/dev/null || hostname)"

    printf '\n'
    printf '%b==========================================%b\n' "$GREEN" "$RESET"
    printf '%b       PROCESO FINALIZADO CORRECTAMENTE%b\n' "$GREEN" "$RESET"
    printf '%b==========================================%b\n' "$GREEN" "$RESET"

    printf '\n'
    printf '%b  CONFIGURACIÓN DEL ESCÁNER%b\n' "$BLUE" "$RESET"
    printf '\n'

    printf '  %bHost:%b        %b%s%b\n' \
        "$YELLOW" "$RESET" "$GREEN" "$hostname" "$RESET"

    printf '  %bCarpeta:%b     %b%s%b\n' \
        "$YELLOW" "$RESET" "$GREEN" "escaner" "$RESET"

    printf '  %bUsuario:%b     %b%s%b\n' \
        "$YELLOW" "$RESET" "$GREEN" " " "$RESET"

    printf '  %bContraseña:%b  %b%s%b\n' \
        "$YELLOW" "$RESET" "$GREEN" "" "$RESET"


    printf '\n'
    log_info "Copia de seguridad: $BACKUP_FILE"
    printf '\n'
    log_success "Ya puedes configurar el escáner de red."
    printf '\n'
}

main "$@"
