set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# ==================================================
# Google Chrome - Activar WebGL en Lliurex
# ==================================================

readonly DESKTOP_FILE="/usr/share/applications/google-chrome.desktop"
readonly PARAMETER="--ignore-gpu-blocklist"

BACKUP_FILE=""
TEMP_FILE=""
LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/chrome-gpu.XXXXXX.log")"
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

    if [[ -n "${TEMP_FILE:-}" ]]; then
        rm -f -- "$TEMP_FILE"
    fi

    if (( exit_code == 0 )); then
        rm -f -- "$LOG_FILE"
    else
        log_warning "Log técnico: $LOG_FILE"
    fi

    exit "$exit_code"
}

trap cleanup EXIT

check_requirements() {
    log_step "1/3 - Comprobando requisitos"

    [[ "$EUID" -ne 0 ]] ||
        die "Ejecuta el script con tu usuario habitual, no como root."

    command -v sudo >/dev/null 2>&1 ||
        die "No se encuentra el comando sudo."

    command -v awk >/dev/null 2>&1 ||
        die "No se encuentra el comando awk."

    command -v mktemp >/dev/null 2>&1 ||
        die "No se encuentra el comando mktemp."

    sudo -v

    sudo test -f "$DESKTOP_FILE" ||
        die "No se encuentra el archivo $DESKTOP_FILE."

    log_success "Requisitos comprobados."
}

configure_chrome() {
    log_step "2/3 - Configurando los parámetros de Chrome"

    BACKUP_FILE="${DESKTOP_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    TEMP_FILE="$(mktemp "${TMPDIR:-/tmp}/chrome-desktop.XXXXXX")"

    sudo cp -p -- "$DESKTOP_FILE" "$BACKUP_FILE" ||
        die "No se ha podido crear la copia de seguridad."

    sudo cat -- "$DESKTOP_FILE" |
        sed 's/\r$//' |
        awk -v parameter="$PARAMETER" '
            /^[[:space:]]*Exec[[:space:]]*=/ {
                count++

                if ($0 !~ ("(^|[[:space:]])" parameter "([[:space:]]|$)")) {
                    sub(/[[:space:]]*$/, "")
                    $0 = $0 " " parameter
                    changed++
                }
            }

            { print }

            END {
                if (count == 0) {
                    exit 10
                }

                printf "%d %d\n", count, changed > "/dev/stderr"
            }
        ' > "$TEMP_FILE" 2>"${TEMP_FILE}.info" ||
        die "No se han encontrado líneas Exec= o ha fallado el procesamiento."

    read -r exec_count changed_count < "${TEMP_FILE}.info"
    rm -f -- "${TEMP_FILE}.info"

    if (( changed_count == 0 )); then
        log_info "Todas las líneas Exec ya contienen el parámetro."
        rm -f -- "$TEMP_FILE"
        TEMP_FILE=""
        return
    fi

    sudo install -o root -g root \
        --reference="$DESKTOP_FILE" "$TEMP_FILE" "${DESKTOP_FILE}.new" ||
        die "No se ha podido preparar el archivo modificado."

    sudo mv -f -- "${DESKTOP_FILE}.new" "$DESKTOP_FILE" ||
        die "No se ha podido actualizar Chrome."

    rm -f -- "$TEMP_FILE"
    TEMP_FILE=""

    log_success "Se han actualizado $changed_count de $exec_count líneas Exec."
}

verify_configuration() {
    log_step "3/3 - Verificando la configuración"

    local total missing

    total="$(grep -cE '^[[:space:]]*Exec=' "$DESKTOP_FILE" || true)"
    missing="$(grep -cE '^[[:space:]]*Exec=.*' "$DESKTOP_FILE" |
        grep -vcE '(^|[[:space:]])--ignore-gpu-blocklist([[:space:]]|$)' || true)"

    (( total > 0 )) ||
        die "No se han encontrado líneas Exec para verificar."

    if (( missing > 0 )); then
        die "Hay líneas Exec que no contienen $PARAMETER."
    fi

    log_success "Las $total líneas Exec contienen $PARAMETER."
    log_info "Copia de seguridad: $BACKUP_FILE"
}

main() {
    printf '\n'
    printf '%b==========================================%b\n' "$BLUE" "$RESET"
    printf '  CONFIGURACIÓN GOOGLE CHROME - GPU\n'
    printf '%b==========================================%b\n' "$BLUE" "$RESET"

    check_requirements
    configure_chrome
    verify_configuration

    printf '\n'
    log_success "Configuración completada correctamente."
    log_info "Cierra y vuelve a abrir Chrome para aplicar el cambio."
}

main "$@"
