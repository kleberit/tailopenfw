#!/bin/bash
#
# install.sh — Aplica os patches de interligação de redes via Tailscale
#              (subnet routing) nos firewalls OpenFW UTM.
#
#              1) Corrige o tailscale-wrapper para sempre subir com
#                 --netfilter-mode=off (evita que o Tailscale insira uma
#                 regra DROP que bloqueia o forwarding LAN-a-LAN).
#              2) Corrige a chain ICMP_LOGDROP para não descartar ping
#                 destinado ao próprio firewall antes da exceção de
#                 System Access ser avaliada.
#
# Uso:
#   ./install.sh                → aplica os patches
#   ./install.sh --check        → só verifica o estado atual, não altera nada
#   ./install.sh --rollback     → restaura o tailscale-wrapper original (.bak mais recente)
#
# Idempotente: pode rodar quantas vezes quiser, sempre faz backup antes de sobrescrever.

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$REPO_DIR/files"
TS_WRAPPER="/usr/local/bin/tailscale-wrapper"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✔${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
err()  { echo -e "${RED}✘${NC} $1"; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "Rode como root (sudo ./install.sh)."
        exit 1
    fi
}

backup_and_install() {
    local src="$1"
    local dst="$2"
    local label="$3"

    if [ ! -f "$src" ]; then
        err "$label: arquivo fonte não encontrado em $src"
        return 1
    fi

    if [ -f "$dst" ]; then
        cp "$dst" "${dst}.bak-${TIMESTAMP}"
        ok "$label: backup salvo em ${dst}.bak-${TIMESTAMP}"
    else
        warn "$label: $dst não existia ainda, seguindo sem backup."
    fi

    cp "$src" "$dst"
    chmod +x "$dst"
    ok "$label: instalado em $dst"
}

fix_icmp_logdrop() {
    # A chain ICMP_LOGDROP do sistema (Endian/OpenFW) descarta todo ICMP
    # incondicionalmente, inclusive echo-request (type 8), antes mesmo da
    # chain INPUTTRAFFIC/INPUTFW (onde ficam as exceções de System Access)
    # ser avaliada. Sem essa regra RETURN na frente, ping para o próprio
    # firewall nunca funciona, mesmo com a exceção certa cadastrada na GUI.
    if ! iptables -C ICMP_LOGDROP -p icmp --icmp-type 8 -j RETURN 2>/dev/null; then
        iptables -I ICMP_LOGDROP 1 -p icmp --icmp-type 8 -j RETURN
        ok "ICMP_LOGDROP: regra RETURN para icmptype 8 inserida."
    else
        ok "ICMP_LOGDROP: regra RETURN para icmptype 8 já presente."
    fi
}

apply_patches() {
    echo "== Aplicando patches em $(hostname) =="
    echo

    backup_and_install "$FILES_DIR/tailscale-wrapper" "$TS_WRAPPER" "tailscale-wrapper"

    echo
    echo "== Reiniciando Tailscale com netfilter-mode=off =="
    "$TS_WRAPPER" --restart
    sleep 2

    echo
    echo "== Corrigindo ICMP_LOGDROP (permite ping ao próprio firewall) =="
    fix_icmp_logdrop

    echo
    verify
}

verify() {
    echo "== Verificação =="

    if iptables -L ts-forward -n >/dev/null 2>&1; then
        err "Chain ts-forward ainda existe — netfilter-mode NÃO está off. Verifique 'tailscale status' e o log do wrapper."
    else
        ok "Chain ts-forward ausente — netfilter-mode está off, como esperado."
    fi

    local ipfwd
    ipfwd="$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
    if [ "$ipfwd" = "1" ]; then
        ok "net.ipv4.ip_forward = 1"
    else
        err "net.ipv4.ip_forward = ${ipfwd:-desconhecido} (esperado: 1). Habilite antes de continuar."
    fi

    if iptables -C ICMP_LOGDROP -p icmp --icmp-type 8 -j RETURN 2>/dev/null; then
        ok "ICMP_LOGDROP: ping ao próprio firewall liberado (regra RETURN presente)."
    else
        err "ICMP_LOGDROP: regra RETURN para icmptype 8 ausente — ping ao firewall vai falhar. Rode ./install.sh sem --check para corrigir."
    fi

    echo
    echo "Status atual do Tailscale:"
    tailscale status 2>/dev/null || warn "Não foi possível rodar 'tailscale status'."

    echo
    echo "Lembre-se de confirmar manualmente:"
    echo "  - Regras em Firewall > Custom Rules (Custom Forward Rules) cadastradas para esta rede"
    echo "  - Regras em Firewall > Zone-Based Rules > System Access (ping/SSH/WebUI) cadastradas"
    echo "  - Subnet route desta rede aprovada em https://login.tailscale.com/admin/machines"
}

rollback() {
    echo "== Rollback em $(hostname) =="

    local latest_wrapper
    latest_wrapper="$(ls -t ${TS_WRAPPER}.bak-* 2>/dev/null | head -n1)"
    if [ -n "$latest_wrapper" ]; then
        cp "$latest_wrapper" "$TS_WRAPPER"
        chmod +x "$TS_WRAPPER"
        ok "tailscale-wrapper restaurado a partir de $latest_wrapper"
        "$TS_WRAPPER" --restart
    else
        warn "Nenhum backup de tailscale-wrapper encontrado."
    fi
}

main() {
    require_root
    case "${1:-}" in
        --check)
            verify
            ;;
        --rollback)
            rollback
            ;;
        "")
            apply_patches
            ;;
        *)
            echo "Uso: $0 [--check|--rollback]"
            exit 1
            ;;
    esac
}

main "$@"
