#!/usr/bin/env python3
"""
Genera un dataset sintetico de volumen (customers, accounts, transactions,
ledger_entries) y lo carga en una base de datos, luego de aplicar sobre ella
el esquema `logico` o `fisico` indicado.

Con el mismo --seed, dos corridas con distinto --schema generan EXACTAMENTE
los mismos datos de negocio (mismos clientes, mismas transferencias, mismos
montos y fechas). Es lo que permite comparar bench_before (logico, sin
indices/particiones) contra bench_after (fisico) de forma justa: la unica
variable que cambia es el esquema fisico, no los datos.

No se usa ningun LLM para generar filas: Faker + COPY es lo estandar para
poblar datos de prueba de volumen (ver decision registrada con el usuario).

Uso:
    .venv/bin/python scripts/generar_volumen.py --schema logico --db bench_before
    .venv/bin/python scripts/generar_volumen.py --schema fisico --db bench_after
"""
import argparse
import csv
import io
import random
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg2
from faker import Faker

REPO_ROOT = Path(__file__).resolve().parent.parent
SCHEMA_FILES = {
    "logico": REPO_ROOT / "logico" / "modelo_logico.sql",
    "fisico": REPO_ROOT / "fisico" / "modelo_fisico.sql",
}
RANGO_INICIO = datetime(2024, 1, 1, tzinfo=timezone.utc)
RANGO_FIN = datetime(2025, 12, 31, 23, 59, 59, tzinfo=timezone.utc)


def cargar_env() -> dict:
    env = {}
    for linea in (REPO_ROOT / ".env").read_text().splitlines():
        linea = linea.strip()
        if not linea or linea.startswith("#") or "=" not in linea:
            continue
        k, v = linea.split("=", 1)
        env[k] = v
    return env


def conectar(env: dict, dbname: str):
    return psycopg2.connect(
        host="localhost",
        port=env["POSTGRES_PORT"],
        user=env["POSTGRES_USER"],
        password=env["POSTGRES_PASSWORD"],
        dbname=dbname,
    )


def recrear_base(env: dict, db: str) -> None:
    conn = conectar(env, "postgres")
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute(f'DROP DATABASE IF EXISTS "{db}" WITH (FORCE);')
        cur.execute(f'CREATE DATABASE "{db}";')
    conn.close()


def aplicar_schema(env: dict, db: str, schema: str) -> None:
    sql = SCHEMA_FILES[schema].read_text()
    conn = conectar(env, db)
    with conn, conn.cursor() as cur:
        cur.execute(sql)
    conn.close()


def fecha_aleatoria(rng: random.Random) -> datetime:
    delta = RANGO_FIN - RANGO_INICIO
    segundos = rng.randint(0, int(delta.total_seconds()))
    return RANGO_INICIO + timedelta(seconds=segundos)


def generar_dataset(seed: int, n_customers: int, n_accounts: int, n_transactions: int):
    """Genera todo en memoria con un RNG sembrado: mismo seed => mismos datos."""
    fake = Faker()
    Faker.seed(seed)
    rng = random.Random(seed)

    t0 = time.time()
    print(f"[generar] {n_customers} clientes...", file=sys.stderr)
    customers = []  # (full_name, email)
    vistos = set()
    while len(customers) < n_customers:
        email = fake.unique.email()
        if email in vistos:
            continue
        vistos.add(email)
        customers.append((fake.name(), email))
    # cuenta reservada para comisiones, igual que en las pruebas de Fase 2
    customers.append(("Banco - Ingresos por Comisiones", "ingresos@banco.bench"))

    print(f"[generar] {n_accounts} cuentas...", file=sys.stderr)
    # indices 0..n_customers-1 son clientes normales; el ultimo es el banco
    accounts = []  # (customer_idx,)
    accounts.append((n_customers,))  # cuenta del banco: siempre indice de cuenta 0
    for _ in range(n_accounts - 1):
        accounts.append((rng.randrange(0, n_customers),))

    print(f"[generar] {n_transactions} transacciones + asientos...", file=sys.stderr)
    transactions = []   # (transaction_type, description, idempotency_key, recorded_at)
    ledger_entries = [] # (idem_key, account_idx, amount, effective_at)
    n_accounts_total = len(accounts)
    cuenta_banco_idx = 0

    for i in range(n_transactions):
        idem = f"bench-{i:08d}"
        fecha = fecha_aleatoria(rng)
        monto = round(rng.uniform(5, 5000), 2)
        origen = rng.randrange(1, n_accounts_total)
        destino = rng.randrange(1, n_accounts_total)
        while destino == origen:
            destino = rng.randrange(1, n_accounts_total)

        con_comision = rng.random() < 0.2
        if con_comision:
            comision = round(monto * rng.uniform(0.005, 0.02), 2)
            neto = round(monto - comision, 2)
            entradas = [(origen, -monto), (destino, neto), (cuenta_banco_idx, comision)]
            desc = "Transferencia con comision (dataset de benchmark)"
        else:
            entradas = [(origen, -monto), (destino, monto)]
            desc = "Transferencia (dataset de benchmark)"

        transactions.append(("TRANSFER", desc, idem, fecha))
        for cuenta_idx, importe in entradas:
            ledger_entries.append((idem, cuenta_idx, importe, fecha))

        if (i + 1) % 50000 == 0:
            print(f"[generar]   {i + 1}/{n_transactions}", file=sys.stderr)

    print(f"[generar] listo en {time.time() - t0:.1f}s: "
          f"{len(customers)} clientes, {len(accounts)} cuentas, "
          f"{len(transactions)} transacciones, {len(ledger_entries)} asientos",
          file=sys.stderr)
    return customers, accounts, transactions, ledger_entries


def buffer_csv(filas) -> io.StringIO:
    buf = io.StringIO()
    w = csv.writer(buf)
    for fila in filas:
        w.writerow(fila)
    buf.seek(0)
    return buf


def cargar_datos(env: dict, db: str, schema: str, customers, accounts, transactions, ledger_entries):
    conn = conectar(env, db)
    conn.autocommit = False
    cur = conn.cursor()
    t0 = time.time()

    print("[cargar] customers...", file=sys.stderr)
    buf = buffer_csv([(nombre, email) for nombre, email in customers])
    cur.copy_expert("COPY customers (full_name, email) FROM STDIN WITH (FORMAT csv)", buf)

    cur.execute("SELECT customer_id FROM customers ORDER BY customer_id")
    customer_ids = [r[0] for r in cur.fetchall()]  # indice de la lista -> id real

    print("[cargar] accounts...", file=sys.stderr)
    buf = buffer_csv([(customer_ids[c_idx],) for (c_idx,) in accounts])
    cur.copy_expert("COPY accounts (customer_id) FROM STDIN WITH (FORMAT csv)", buf)

    cur.execute("SELECT account_id FROM accounts ORDER BY account_id")
    account_ids = [r[0] for r in cur.fetchall()]

    print("[cargar] transactions...", file=sys.stderr)
    buf = buffer_csv([(t, d, k, f.isoformat()) for (t, d, k, f) in transactions])
    cur.copy_expert(
        "COPY transactions (transaction_type, description, idempotency_key, recorded_at) "
        "FROM STDIN WITH (FORMAT csv)",
        buf,
    )

    cur.execute("SELECT idempotency_key, transaction_id FROM transactions")
    idem_a_txid = dict(cur.fetchall())

    print("[cargar] ledger_entries (trigger R1/R2 desactivado durante la carga)...", file=sys.stderr)
    # Desactivamos el CONSTRAINT TRIGGER de R1/R2 solo para esta carga masiva:
    # el generador YA garantiza que cada transaccion suma cero (ver
    # generar_dataset), y volver a verificarlo fila por fila para ~cientos de
    # miles de asientos sinteticos no prueba nada que las 8 pruebas de
    # fisico/pruebas_modelo_fisico.sql no hayan probado ya con casos
    # controlados. Es la misma logica que un ETL de produccion aplicaria.
    cur.execute("ALTER TABLE ledger_entries DISABLE TRIGGER trg_ledger_entries_balance")
    buf = buffer_csv([
        (idem_a_txid[idem], account_ids[c_idx], f"{monto:.4f}", fecha.isoformat())
        for (idem, c_idx, monto, fecha) in ledger_entries
    ])
    cur.copy_expert(
        "COPY ledger_entries (transaction_id, account_id, amount, effective_at) "
        "FROM STDIN WITH (FORMAT csv)",
        buf,
    )
    cur.execute("ALTER TABLE ledger_entries ENABLE TRIGGER trg_ledger_entries_balance")

    print("[cargar] confirmando transacciones...", file=sys.stderr)
    if schema == "fisico":
        # Igual razon que arriba: el trigger de sincronizacion hace un UPDATE
        # correlacionado por transaccion; a granel es mas rapido desactivarlo
        # y recalcular el snapshot completo con una sola agregacion al final.
        cur.execute("ALTER TABLE transactions DISABLE TRIGGER trg_transactions_sync_snapshot")
    cur.execute("UPDATE transactions SET status = 'CONFIRMED'")
    if schema == "fisico":
        cur.execute("ALTER TABLE transactions ENABLE TRIGGER trg_transactions_sync_snapshot")
        print("[cargar] recalculando account_balance_snapshot...", file=sys.stderr)
        cur.execute("""
            UPDATE account_balance_snapshot s
               SET balance = agg.total,
                   entry_count = agg.cnt,
                   last_entry_at = agg.ultima,
                   updated_at = CURRENT_TIMESTAMP
              FROM (
                    SELECT le.account_id,
                           SUM(le.amount)       AS total,
                           COUNT(*)             AS cnt,
                           MAX(le.effective_at) AS ultima
                      FROM ledger_entries le
                      JOIN transactions t USING (transaction_id)
                     WHERE t.status = 'CONFIRMED'
                     GROUP BY le.account_id
                   ) agg
             WHERE s.account_id = agg.account_id
        """)

    conn.commit()
    print(f"[cargar] listo en {time.time() - t0:.1f}s", file=sys.stderr)

    print("[cargar] ANALYZE...", file=sys.stderr)
    conn.autocommit = True
    cur.execute("ANALYZE")
    conn.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--schema", choices=["logico", "fisico"], required=True)
    ap.add_argument("--db", required=True)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--n-customers", type=int, default=5000)
    ap.add_argument("--n-accounts", type=int, default=8000)
    ap.add_argument("--n-transactions", type=int, default=200000)
    args = ap.parse_args()

    env = cargar_env()

    print(f"[schema] recreando {args.db} y aplicando {args.schema}...", file=sys.stderr)
    recrear_base(env, args.db)
    aplicar_schema(env, args.db, args.schema)

    customers, accounts, transactions, ledger_entries = generar_dataset(
        args.seed, args.n_customers, args.n_accounts, args.n_transactions
    )
    cargar_datos(env, args.db, args.schema, customers, accounts, transactions, ledger_entries)
    print(f"[fin] {args.db} listo con esquema {args.schema}", file=sys.stderr)


if __name__ == "__main__":
    main()
