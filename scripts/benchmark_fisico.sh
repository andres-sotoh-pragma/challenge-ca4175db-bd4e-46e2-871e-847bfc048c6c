#!/usr/bin/env bash
# Compara con EXPLAIN (ANALYZE, BUFFERS) el esquema logico (bench_before, sin
# indices ni particiones) contra el fisico (bench_after) sobre datos IDENTICOS.
#
# Requiere que ambas bases ya existan, generadas con el mismo --seed:
#   .venv/bin/python scripts/generar_volumen.py --schema logico --db bench_before --seed 42
#   .venv/bin/python scripts/generar_volumen.py --schema fisico --db bench_after  --seed 42
#
# Uso: ./scripts/benchmark_fisico.sh [account_id] [transaction_id] [mes YYYY-MM]

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

ACCOUNT_ID="${1:-1}"
TRANSACTION_ID="${2:-99944}"
MES="${3:-2024-06}"
MES_SIG=$(python3 -c "
y,m = map(int, '$MES'.split('-'))
m += 1
if m > 12: m, y = 1, y+1
print(f'{y:04d}-{m:02d}')
")

PSQL_BEFORE=(docker compose exec -T postgres psql -U fintech -d bench_before)
PSQL_AFTER=(docker compose exec -T postgres psql -U fintech -d bench_after)

correr() {
    local titulo="$1" nota_before="$2" sql_before="$3" nota_after="$4" sql_after="$5"
    echo "============================================================"
    echo "# $titulo"
    echo "============================================================"
    echo "--- bench_before: $nota_before ---"
    "${PSQL_BEFORE[@]}" -c "$sql_before"
    echo
    echo "--- bench_after: $nota_after ---"
    "${PSQL_AFTER[@]}" -c "$sql_after"
    echo
}

Q1="EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) SELECT * FROM ledger_entries
  WHERE account_id = $ACCOUNT_ID
    AND effective_at >= '${MES}-01' AND effective_at < '${MES_SIG}-01';"

correr "QUERY 1 -- Extracto de una cuenta en un mes (account_id=$ACCOUNT_ID, $MES)" \
    "sin particiones ni indices (logico)" "$Q1" \
    "particionado por RANGE(effective_at) + indice (account_id, effective_at)" "$Q1"

correr "QUERY 2 -- Saldo actual de una cuenta (account_id=$ACCOUNT_ID)" \
    "vista account_balances (recomputa SUM sobre todo el historial)" \
    "EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) SELECT balance FROM account_balances WHERE account_id = $ACCOUNT_ID;" \
    "tabla account_balance_snapshot (materializado, sincronizado por trigger)" \
    "EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) SELECT balance FROM account_balance_snapshot WHERE account_id = $ACCOUNT_ID;"

Q3="EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) SELECT * FROM ledger_entries WHERE transaction_id = $TRANSACTION_ID;"

correr "QUERY 3 -- Todos los asientos de una transaccion (transaction_id=$TRANSACTION_ID)" \
    "sin indice sobre transaction_id: seq scan" "$Q3" \
    "indice (transaction_id) por particion, sin filtro de fecha: recorre las 24+1" "$Q3"
