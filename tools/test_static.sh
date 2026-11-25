#!/usr/bin/env bash
# Testes estaticos do projeto (nao precisam do servidor rodando).
#
# Uso:
#   tools/test_static.sh                 # todas as checagens
#   tools/test_static.sh --no-compile    # sem compilar os plugins (mais rapido)
#   tools/test_static.sh -v              # mostra tambem os avisos do upstream
#   tools/test_static.sh modes ranges    # so algumas checagens
#
# Sai com codigo 1 se houver algum FAIL (serve como pre-commit hook ou CI).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 -I "$ROOT/tools/test_static.py" "$@"
