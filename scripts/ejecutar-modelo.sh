#!/usr/bin/env bash
# Ejecuta un modelo SQL contra una base RECIEN CREADA, para que el resultado
# no este contaminado por lo que haya dejado una ejecucion anterior.
#
# Uso:  ./scripts/ejecutar-modelo.sh conceptual|logico|fisico [--stop-on-error]
#
# Por defecto psql NO se detiene en el primer error: asi vemos todos los
# problemas del script de una sola pasada. Con --stop-on-error se detiene
# en el primero, util para aislar una falla puntual.

set -uo pipefail

# Siempre operar desde la raiz del repo, para que docker compose encuentre el yml
cd "$(dirname "$0")/.." || exit 1

MODELO="${1:-}"
STOP="${2:-}"

case "$MODELO" in
  conceptual) ARCHIVO=/sql/conceptual/modelo_conceptual.sql ;;
  logico)     ARCHIVO=/sql/logico/modelo_logico.sql ;;
  fisico)     ARCHIVO=/sql/fisico/modelo_fisico.sql ;;
  *) echo "Uso: $0 conceptual|logico|fisico [--stop-on-error]" >&2; exit 2 ;;
esac

DB="eval_${MODELO}"
PSQL=(docker compose exec -T postgres psql -U fintech -v ON_ERROR_STOP=0)
[ "$STOP" = "--stop-on-error" ] && PSQL=(docker compose exec -T postgres psql -U fintech -v ON_ERROR_STOP=1)

echo "==> Recreando base limpia: $DB"
"${PSQL[@]}" -d postgres -q \
  -c "DROP DATABASE IF EXISTS $DB WITH (FORCE);" \
  -c "CREATE DATABASE $DB;"

echo "==> Ejecutando $ARCHIVO"
echo "----------------------------------------------------------------------"
"${PSQL[@]}" -d "$DB" -f "$ARCHIVO"
CODIGO=$?
echo "----------------------------------------------------------------------"

echo "==> Tablas que quedaron creadas en $DB:"
"${PSQL[@]}" -d "$DB" -c "\dt"

echo "==> psql salio con codigo $CODIGO"
exit $CODIGO
