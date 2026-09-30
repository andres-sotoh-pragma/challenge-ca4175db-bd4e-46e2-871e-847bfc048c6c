-- =============================================================================
-- Pruebas del modelo lógico
--
-- Verifica que las reglas de negocio R1..R7 se hacen cumplir en la base.
-- Los casos marcados DEBE FALLAR son exitosos si producen un ERROR.
--
-- Ejecutar sobre una base con logico/modelo_logico.sql ya aplicado.
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

-- -----------------------------------------------------------------------------
\warn ''
\warn '=== CASO 1: transferencia balanceada de 100 (DEBE PASAR) ==='
BEGIN;
INSERT INTO transactions (transaction_type, status, description, idempotency_key)
VALUES ('TRANSFER', 'CONFIRMED', 'Transferencia de Ana a Beto', 'idem-0001');

INSERT INTO ledger_entries (transaction_id, account_id, amount) VALUES
    ((SELECT transaction_id FROM transactions WHERE idempotency_key = 'idem-0001'),
     (SELECT a.account_id FROM accounts a JOIN customers c USING (customer_id)
       WHERE c.email = 'ana@ejemplo.com'), -100.0000),
    ((SELECT transaction_id FROM transactions WHERE idempotency_key = 'idem-0001'),
     (SELECT a.account_id FROM accounts a JOIN customers c USING (customer_id)
       WHERE c.email = 'beto@ejemplo.com'), 100.0000);
COMMIT;

-- -----------------------------------------------------------------------------
\warn ''
\warn '=== CASO 2: R1 — transferencia descuadrada -100 / +90 (DEBE FALLAR) ==='
BEGIN;
INSERT INTO transactions (transaction_type, status, description, idempotency_key)
VALUES ('TRANSFER', 'CONFIRMED', 'Descuadrada a proposito', 'idem-0002');

INSERT INTO ledger_entries (transaction_id, account_id, amount) VALUES
    ((SELECT transaction_id FROM transactions WHERE idempotency_key = 'idem-0002'),
     (SELECT a.account_id FROM accounts a JOIN customers c USING (customer_id)
       WHERE c.email = 'ana@ejemplo.com'), -100.0000),
    ((SELECT transaction_id FROM transactions WHERE idempotency_key = 'idem-0002'),
     (SELECT a.account_id FROM accounts a JOIN customers c USING (customer_id)
       WHERE c.email = 'beto@ejemplo.com'), 90.0000);
COMMIT;

-- -----------------------------------------------------------------------------
\warn ''
\warn '=== CASO 3: R2 — transaccion con un solo asiento (DEBE FALLAR) ==='
BEGIN;
INSERT INTO transactions (transaction_type, status, description, idempotency_key)
VALUES ('DEPOSIT', 'CONFIRMED', 'Deposito sin contrapartida', 'idem-0003');

INSERT INTO ledger_entries (transaction_id, account_id, amount) VALUES
    ((SELECT transaction_id FROM transactions WHERE idempotency_key = 'idem-0003'),
     (SELECT a.account_id FROM accounts a JOIN customers c USING (customer_id)
       WHERE c.email = 'ana@ejemplo.com'), 500.0000);
COMMIT;

-- -----------------------------------------------------------------------------
\warn ''
\warn '=== CASO 4: transferencia con comision, 3 asientos (DEBE PASAR) ==='
\warn '    Ana -100, Beto +98, cuenta de ingresos del banco +2'
BEGIN;
INSERT INTO customers (full_name, email) VALUES ('Banco Ingresos', 'ingresos@banco.com');
INSERT INTO accounts (customer_id)
SELECT customer_id FROM customers WHERE email = 'ingresos@banco.com';

INSERT INTO transactions (transaction_type, status, description, idempotency_key)
VALUES ('TRANSFER', 'CONFIRMED', 'Transferencia con comision', 'idem-0004');

INSERT INTO ledger_entries (transaction_id, account_id, amount) VALUES
    ((SELECT transaction_id FROM transactions WHERE idempotency_key = 'idem-0004'),
     (SELECT a.account_id FROM accounts a JOIN customers c USING (customer_id)
       WHERE c.email = 'ana@ejemplo.com'), -100.0000),
    ((SELECT transaction_id FROM transactions WHERE idempotency_key = 'idem-0004'),
     (SELECT a.account_id FROM accounts a JOIN customers c USING (customer_id)
       WHERE c.email = 'beto@ejemplo.com'), 98.0000),
    ((SELECT transaction_id FROM transactions WHERE idempotency_key = 'idem-0004'),
     (SELECT a.account_id FROM accounts a JOIN customers c USING (customer_id)
       WHERE c.email = 'ingresos@banco.com'), 2.0000);
COMMIT;

-- -----------------------------------------------------------------------------
\warn ''
\warn '=== CASO 5: R7 — reintento con la misma clave de idempotencia (DEBE FALLAR) ==='
INSERT INTO transactions (transaction_type, status, description, idempotency_key)
VALUES ('TRANSFER', 'CONFIRMED', 'Reintento por timeout de red', 'idem-0001');

-- -----------------------------------------------------------------------------
\warn ''
\warn '=== CASO 6: asiento de importe cero (DEBE FALLAR) ==='
INSERT INTO ledger_entries (transaction_id, account_id, amount) VALUES
    ((SELECT transaction_id FROM transactions WHERE idempotency_key = 'idem-0001'),
     (SELECT a.account_id FROM accounts a JOIN customers c USING (customer_id)
       WHERE c.email = 'ana@ejemplo.com'), 0);

-- -----------------------------------------------------------------------------
\warn ''
\warn '=== CASO 7: correo duplicado (DEBE FALLAR) ==='
INSERT INTO customers (full_name, email) VALUES ('Otra Ana', 'ana@ejemplo.com');

-- -----------------------------------------------------------------------------
\warn ''
\warn '=== CASO 8: intentar asignar el ID manualmente (DEBE FALLAR) ==='
\warn '    GENERATED ALWAYS lo impide; con SERIAL esto habria pasado y roto la secuencia'
INSERT INTO customers (customer_id, full_name, email) VALUES (999, 'Impostor', 'x@y.com');

-- -----------------------------------------------------------------------------
\warn ''
\warn '=== RESULTADO: saldos derivados (solo transacciones CONFIRMED) ==='
SELECT c.email, b.account_id, b.balance, b.entry_count
  FROM account_balances b JOIN customers c USING (customer_id) ORDER BY c.email;

\warn ''
\warn '=== AUDITORIA R1: transacciones descuadradas en toda la base ==='
\warn '    (debe devolver 0 filas)'
SELECT transaction_id, SUM(amount) AS descuadre
  FROM ledger_entries GROUP BY transaction_id HAVING SUM(amount) <> 0;

\warn ''
\warn '=== El dinero total del sistema suma cero (invariante global) ==='
SELECT SUM(amount) AS total_sistema FROM ledger_entries;
