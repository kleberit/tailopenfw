# Tailscale Subnet Router Fix — OpenFW UTM

Repositório: https://github.com/kleberit/tailopenfw

Patches para permitir interligação de LANs via **Tailscale subnet routing** em
firewalls **OpenFW UTM** (base Endian Firewall Community), corrigindo dois
problemas:

1. **`netfilter-mode` do Tailscale** — por padrão o `tailscaled` insere uma
   regra `DROP` na chain `ts-forward` que bloqueia tráfego LAN-a-LAN
   roteado. Corrigido forçando `--netfilter-mode=off` sempre no
   `tailscale-wrapper`, mesmo após `--reset` no boot.
2. **Chain `ICMP_LOGDROP`** — descarta todo ICMP incondicionalmente
   (inclusive echo-request) antes mesmo da chain `INPUTTRAFFIC`/`INPUTFW`
   (onde ficam as exceções de *System Access*) ser avaliada. Isso faz o
   ping para o **próprio firewall** falhar mesmo com a exceção certa
   cadastrada na GUI. Corrigido inserindo uma regra `RETURN` para
   `icmptype 8` no topo dessa chain.

> A posição da chain `CUSTOMFORWARD` (Custom Forward Rules) também foi
> investigada durante o diagnóstico original, mas não é a causa raiz de
> nenhum problema observado — o tráfego já era avaliado por ela
> normalmente, independente da posição. Por isso não há patch para isso
> aqui.

## Requisitos antes de rodar

- `net.ipv4.ip_forward = 1` no kernel.
- Subnet routes anunciadas (`--advertise-routes`) e **aprovadas** no
  [admin console do Tailscale](https://login.tailscale.com/admin/machines).
- Regras já cadastradas pela GUI em:
  - **Firewall > Custom Rules** (Custom Forward Rules) — rede local ↔ redes remotas.
  - **Firewall > Zone-Based Rules > System Access** — se quiser ping/SSH/WebUI
    no próprio firewall a partir das redes remotas.

## Uso

```bash
git clone https://github.com/kleberit/tailopenfw.git
cd tailopenfw
chmod +x install.sh
sudo ./install.sh
```

O script:
- Faz backup do `tailscale-wrapper` original antes de sobrescrever
  (`arquivo.bak-AAAAMMDD-HHMMSS`).
- Instala o `tailscale-wrapper` patchado.
- Reinicia o Tailscale (`--restart`).
- Insere a regra `RETURN` na chain `ICMP_LOGDROP` (idempotente — não duplica
  se já existir).
- Roda uma verificação automática ao final.

### Outros modos

```bash
sudo ./install.sh --check      # só verifica o estado atual, não altera nada
sudo ./install.sh --rollback   # restaura o backup mais recente de cada arquivo
```

## Estrutura

```
.
├── install.sh              # instalador principal
├── files/
│   └── tailscale-wrapper    # com --netfilter-mode=off forçado
└── README.md
```

## Depois de rodar em cada firewall

Ainda é necessário, via GUI, em cada firewall novo:

1. **Custom Forward Rules**: cadastrar origem/destino da rede local ↔ redes
   remotas que ele precisa alcançar.
2. **System Access**: cadastrar origem das redes remotas que devem conseguir
   pingar/acessar SSH/WebUI deste firewall.
3. Confirmar a subnet route deste firewall aprovada no admin console do
   Tailscale.

## Atenção em updates do OpenFW UTM

Um update de sistema pode sobrescrever `/usr/local/bin/tailscale-wrapper` com
a versão original (sem o patch). Depois de qualquer update, rode
`sudo ./install.sh` de novo — é seguro, o script sempre faz backup antes de
reaplicar.
