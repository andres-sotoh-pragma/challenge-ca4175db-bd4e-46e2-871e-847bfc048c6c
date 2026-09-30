-- =============================================================================
-- Pruebas del modelo físico
--
-- No repite R1/R2/R6/R7 (ya probadas en logico/pruebas_modelo_logico.sql y el
-- mecanismo no cambió). Se enfoca en lo que SÍ es nuevo en Fase 3:
--   * la maquina de estados de transactions.status,
--   * que account_balance_snapshot quede sincronizado con account_balances
--     (la vista que recomputa desde cero) en cada transicion,
--   * que el particionamiento de ledger_entries funcione (pruning visible
--     en EXPLAIN).
--
-- Una diferencia de flujo importante frente a Fase 2: ahi las pruebas
-- insertaban las transacciones ya como 'CONFIRMED'. Aca eso esta prohibido
-- a proposito (toda transaccion nace PENDING) — por eso el flujo es
-- INSERT (PENDING por defecto) -> INSERT ledger_entries -> UPDATE a CONFIRMED.
--
-- Ejecutar sobre una base con fisico/modelo_fisico.sql ya aplicado.
-- =============================================================================

\warn ''
\warn '=== SETUP: dos clientes con una cuenta cada uno ==='
INSERT INTO customers (full_name, email) VALUES
    ('Ana Restrepo',  'ana@ejemplo.com'),
    ('Beto Gutierrez', 'beto@ejemplo.com');

INSERT INTO accounts (customer_id)
SELECT customer_id FROM customers ORDER BY email;

SELECT c.email, a.account_id, a.status
  FROM accounts a JOIN customers c USING (customer_id) ORDER BY c.email;

\warn ''
\warn '=== snapshot recien sembrado: ambas cuentas en 0 ==='
SELECT account_id, balance, entry_count FROM account_balance_snapshot ORDER BY account_id;

-- -----------------------------------------------------------------------------
\warn ''
\warn '=== CASO 1: INSERT con status explicito CONFIRMED (DEBE FALLAR) ==='
\warn '    toda transaccion tiene que nacer PENDING'
INSERT INTO transactions (transaction_type, status, description, idempotency_key)
VALUES ('TRANSFER', 'CONFIRMED', 'Intento de saltarse el estado inicial', 'idem-bad-001');

-- -----------------------------------------------------------------------------
\warn ''
\warn '=== CASO 2: transferencia 100, ciclo de vida completo (DEBE PASAR) ==='
BEGIN;
INSERT INTO transactions (transaction_type, description, idempotency_key)
VALUES ('TRANSFER', 'Transferencia de Ana a Beto', 'idem-0001');

INSERT INTO ledger_entries (transaction_id, account_id, amount, effective_at) VALUES
    ((SELECT transaction_id FROM transactions WHERE idempotency_key = 'idem-0001'),
     (SELECT a.account_id FROM accounts a JOIN customers c USING (customer_id)
       WHERE c.email = 'ana@ejemplo.com'), -100.0000, '2024-03-15 10:00:00-05'),
    ((SELECT transaction_id FROM transactions WHERE idempotency_key = 'idem-0001'),
     (SELECT a.account_id FROM accounts a JOIN customers c USING (customer_id)
       WHERE c.email = 'beto@ejemplo.com'), 100.0000, '2024-03-15 10:00:00-05');
COMMIT;

\warn ''
\warn '--- todavia PENDING: snapshot y vista deben seguir en 0 ---'
SELECT c.email, s.balance AS snapshot, COALESCE(v.balance, 0) AS vista
  FROM account_balance_snapshot s
  JOIN accounts a USING (account_id)
  JOIN customers c USING (customer_id)
  LEFT JOIN account_balances v USING (account_id)
 ORDER BY c.email;

UPDATE transactions SET status = 'CONFIRMED' WHERE idempotency_key = 'idem-0001';

\warn ''
\warn '--- confirmada: snapshot debe coincidir con la vista recomputada ---'
SELECT c.email, s.balance AS snapshot, v.balance AS vista,
       (s.balance = v.balance) AS coinciden
  FROM account_balance_snapshot s
  JOIN accounts a USING (account_id)
  JOIN customers c USING (customer_id)
  JOIN account_balances v USING (account_id)
 ORDER BY c.email;

-- -----------------------------------------------------------------------------
\warn ''
\warn '=== CASO 3: transicion invalida REJECTED -> CONFIRMED (DEBE FALLAR) ==='
BEGIN;
INSERT INTO transactions (transaction_type, description, idempotency_key)
VALUES ('DEPOSIT', 'Deposito que se va a rechazar', 'idem-0002');
INSERT INTO ledger_entries (transaction_id, account_id, amount, effective_at) VALUES
    ((SELECT transaction_id FROM transactions WHERE idempotency_key = 'idem-0002'),
     (SELECT a.account_id FROM accounts a JOIN customers c USING (customer_id)
       WHERE c.email = 'ana@ejemplo.com'), 500.0000, '2024-04-01 09:00:00-05'),
    ((SELECT transaction_id FROM transactions WHERE idempotency_key = 'idem-0002'),
     (SELECT a.account_id FROM accounts a JOIN customers c USING (customer_id)
       WHERE c.email = 'beto@ejemplo.com'), -500.0000, '2024-04-01 09:00:00-05');
UPDATE transactions SET status = 'REJECTED' WHERE idempotency_key = 'idem-0002';
COMMIT;

UPDATE transactions SET status = 'CONFIRMED' WHERE idempotency_key = 'idem-0002';

-- -----------------------------------------------------------------------------
\warn ''
\warn '=== CASO 4: reversa CONFIRMED -> REVERSED (DEBE PASAR, snapshot vuelve a 0) ==='
UPDATE transactions SET status = 'REVERSED' WHERE idempotency_key = 'idem-0001';

\warn ''
\warn '--- revertida: snapshot y vista deben coincidir, ambos en 0 ---'
SELECT c.email, s.balance AS snapshot, COALESCE(v.balance, 0) AS vista
  FROM account_balance_snapshot s
  JOIN accounts a USING (account_id)
  JOIN customers c USING (customer_id)
  LEFT JOIN account_balances v USING (account_id)
 ORDER BY c.email;

-- -----------------------------------------------------------------------------
\warn ''
\warn '=== CASO 5: transicion invalida REVERSED -> CONFIRMED (DEBE FALLAR) ==='
UPDATE transactions SET status = 'CONFIRMED' WHERE idempotency_key = 'idem-0001';

-- -----------------------------------------------------------------------------
\warn ''
\warn '=== CASO 6: particionamiento — el asiento cae en la particion de su mes ==='
SELECT tableoid::regclass AS particion, entry_id, effective_at
  FROM ledger_entries
 WHERE effective_at = '2024-03-15 10:00:00-05';

\warn ''
\warn '=== CASO 7: partition pruning visible en EXPLAIN ==='
\warn '    debe listar SOLO ledger_entries_2024_03 entre los Subplans/Scans'
EXPLAIN (COSTS OFF)
SELECT * FROM ledger_entries
 WHERE effective_at >= '2024-03-01' AND effective_at < '2024-04-01';

-- -----------------------------------------------------------------------------
\warn ''
\warn '=== CASO 8: fecha fuera del rango 2024-2025 cae en la particion DEFAULT ==='
BEGIN;
INSERT INTO transactions (transaction_type, description, idempotency_key)
VALUES ('DEPOSIT', 'Fuera de rango de particiones', 'idem-0003');
INSERT INTO ledger_entries (transaction_id, account_id, amount, effective_at) VALUES
    ((SELECT transaction_id FROM transactions WHERE idempotency_key = 'idem-0003'),
     (SELECT a.account_id FROM accounts a JOIN customers c USING (customer_id)
       WHERE c.email = 'ana@ejemplo.com'), 10.0000, '2026-06-01 00:00:00-05'),
    ((SELECT transaction_id FROM transactions WHERE idempotency_key = 'idem-0003'),
     (SELECT a.account_id FROM accounts a JOIN customers c USING (customer_id)
       WHERE c.email = 'beto@ejemplo.com'), -10.0000, '2026-06-01 00:00:00-05');
COMMIT;

SELECT tableoid::regclass AS particion, entry_id, effective_at
  FROM ledger_entries
 WHERE effective_at = '2026-06-01 00:00:00-05';
