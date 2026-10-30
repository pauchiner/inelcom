#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

readonly SOURCE="/etc/skel/.config/kwinrc"
readonly CONFIG_SECTION="ModifierOnlyShortcuts"
readonly CONFIG_ENTRY="Meta="

UPDATED=0
SKIPPED=0
FAILED=0

if [[ -t 1 ]]; then
    readonly GREEN='\033[0;32m'
    readonly TEAL='\033[0;36m'
    readonly YELLOW='\033[0;33m'
    readonly RED='\033[0;31m'
    readonly BLUE='\033[0;34m'
    readonly BOLD='\033[1m'
    readonly RESET='\033[0m'
else
    readonly GREEN='' TEAL='' YELLOW=''
    readonly RED='' BLUE='' BOLD='' RESET=''
fi

log_info()    { printf '%b[INFO]%b %s\n' "$BLUE" "$RESET" "$*"; }
log_success() { printf '%b[OK]%b %s\n' "$GREEN" "$RESET" "$*"; }
log_warning() { printf '%b[AVISO]%b %s\n' "$YELLOW" "$RESET" "$*" >&2; }
log_error()   { printf '%b[ERROR]%b %s\n' "$RED" "$RESET" "$*" >&2; }

log_step() {
    printf '\n%b==> %s%b\n' "$BLUE" "$*" "$RESET"
}

configure_skel() {
    log_step "1/3 - Configurando /etc/skel"

    local temp_file
    temp_file="$(mktemp "${TMPDIR:-/tmp}/kwinrc.XXXXXX")"

    mkdir -p "$(dirname "$SOURCE")"
    touch "$SOURCE"

    if ! awk '
        BEGIN {
            in_section = 0
            section_found = 0
            entry_found = 0
        }

        /^\[/ {
            if (in_section && !entry_found) {
                print "Meta="
                entry_found = 1
            }

            in_section = ($0 == "[ModifierOnlyShortcuts]")

            if (in_section)
                section_found = 1

            print
            next
        }

        {
            if (in_section && /^Meta=/) {
                if (!entry_found) {
                    print "Meta="
                    entry_found = 1
                }
                next
            }

            print
        }

        END {
            if (in_section && !entry_found)
                print "Meta="

            if (!section_found) {
                print ""
                print "[ModifierOnlyShortcuts]"
                print "Meta="
            }
        }
    ' "$SOURCE" > "$temp_file"; then
        rm -f "$temp_file"
        log_error "No se ha podido actualizar la configuración de KWin."
        return 1
    fi

    install -o root -g root -m 644 "$temp_file" "$SOURCE"
    rm -f "$temp_file"

    log_success "Configuración de KWin actualizada."
    log_info "Sección: [$CONFIG_SECTION]"
    log_info "Parámetro: $CONFIG_ENTRY"
}

update_users() {
    log_step "2/3 - Actualizando usuarios existentes"

    local home_dir config_dir target
    local uid gid username
    local count=0

    shopt -s nullglob

    for home_dir in /home/*; do
        [[ -d "$home_dir" && ! -L "$home_dir" ]] || continue

        username="$(basename "$home_dir")"

        if [[ "$username" == "guest-user" || "$username" == "estudiant" ]]; then
            log_warning "Skipping excluded account: $username"
            ((SKIPPED++))
            continue
        fi

        uid="$(stat -c '%u' "$home_dir")"
        gid="$(stat -c '%g' "$home_dir")"

        config_dir="${home_dir}/.config"
        target="${config_dir}/kwinrc"

        if [[ -L "$target" ]]; then
            log_warning "Se omite el enlace simbólico: $target"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        if ! mkdir -p "$config_dir"; then
            log_error "No se ha podido crear el directorio de configuración de $username."
            FAILED=$((FAILED + 1))
            continue
        fi

        if install -o "$uid" -g "$gid" -m 644 "$SOURCE" "$target"; then
            log_success "Configuración aplicada a $username."
            UPDATED=$((UPDATED + 1))
        else
            log_error "No se ha podido actualizar la configuración de $username."
            FAILED=$((FAILED + 1))
        fi

        count=$((count + 1))
    done


    (( count > 0 )) || log_warning "No se han encontrado directorios de usuarios en /home."
}

show_summary() {
    log_step "3/3 - Resumen de la configuración"

    printf '\n'
    printf '%b==========================================%b\n' "$GREEN" "$RESET"
    printf '  %bCONFIGURACIÓN COMPLETADA%b\n' "$BOLD" "$RESET"
    printf '%b==========================================%b\n' "$GREEN" "$RESET"

    printf '\n'
    printf '  Actualizados: %b%s%b\n' "$GREEN" "$UPDATED" "$RESET"
    printf '  Omitidos:     %b%s%b\n' "$YELLOW" "$SKIPPED" "$RESET"
    printf '  Errores:      %b%s%b\n' "$RED" "$FAILED" "$RESET"

    printf '\n'
    printf '  %bConfiguración de KWin aplicada correctamente.%b\n' "$TEAL" "$RESET"
    printf '  %bReinicia el equipo para mostrar los cambios!%b\n' "$RED" "$RESET"
    printf '\n'


    printf '\n'
    printf '  Creado por %bPau Chiner%b y %bEva Buendia%b\n' "$BLUE" "$RESET" "$BLUE" "$RESET"
    printf '\n'
    printf '  %bInelcom 2026%b\n' "$TEAL" "$RESET"
    printf '\n'
}

main() {
    printf '\n'
    printf '%b==========================================%b\n' "$BLUE" "$RESET"
    printf '  %bBLOQUEADOR DE EPOPTES - EVITA QUE LOS ALUMNOS QUITEN EL LOCK SCREEN%b\n' "$BOLD" "$RESET"
    printf '%b==========================================%b\n' "$BLUE" "$RESET"

    if [[ "$EUID" -ne 0 ]]; then
        log_error "Ejecuta este script como administrador (root)."
        exit 1
    fi

    configure_skel
    update_users
    show_summary

    (( FAILED == 0 ))
}

main "$@"
