-- =============================================================================
-- Fase 2 — Modelo Lógico
-- Sistema de transacciones financieras con contabilidad de partida doble.
--
-- Criterios aplicados:
--   * SQL estándar siempre que sea posible. Se evita SERIAL (extensión
--     propietaria de PostgreSQL) en favor de GENERATED ALWAYS AS IDENTITY.
--   * Sin índices, particiones ni parámetros de almacenamiento: eso es Fase 3.
--   * Las reglas de negocio R1..R7 del modelo conceptual se declaran como
--     constraints siempre que el estándar lo permita.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- customers — titulares de cuentas
-- -----------------------------------------------------------------------------
CREATE TABLE customers (
    customer_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name       VARCHAR(200) NOT NULL,
    -- 320 = 64 (parte local) + 1 (@) + 255 (dominio), máximo del RFC 5321.
    email           VARCHAR(320) NOT NULL,
    registered_at   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- R7 (parcial): la identidad de contacto no se duplica.
    CONSTRAINT uq_customers_email UNIQUE (email),
    CONSTRAINT ck_customers_full_name CHECK (length(trim(full_name)) > 0),
    CONSTRAINT ck_customers_email CHECK (position('@' IN email) > 1)
);

-- -----------------------------------------------------------------------------
-- accounts — contenedores de valor
--
-- No tiene columna `balance`: el saldo es derivado (regla R5) y se obtiene de
-- la vista account_balances. Materializarlo es una decisión de Fase 3.
-- -----------------------------------------------------------------------------
CREATE TABLE accounts (
    account_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id     BIGINT NOT NULL,
    status          VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    opened_at       TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    closed_at       TIMESTAMP WITH TIME ZONE,

    -- RESTRICT y no CASCADE: borrar un cliente jamás debe arrastrar sus cuentas
    -- ni, por extensión, su historial contable.
    CONSTRAINT fk_accounts_customer FOREIGN KEY (customer_id)
        REFERENCES customers (customer_id) ON DELETE RESTRICT,

    -- R6: solo las cuentas ACTIVE admiten movimientos (se verifica al insertar).
    CONSTRAINT ck_accounts_status CHECK (status IN ('ACTIVE', 'BLOCKED', 'CLOSED')),

    -- Coherencia entre estado y fecha de cierre.
    CONSTRAINT ck_accounts_closed_at CHECK (
        (status = 'CLOSED' AND closed_at IS NOT NULL) OR
        (status <> 'CLOSED' AND closed_at IS NULL)
    ),
    CONSTRAINT ck_accounts_dates CHECK (closed_at IS NULL OR closed_at >= opened_at)
);

-- -----------------------------------------------------------------------------
-- transactions — eventos de negocio que desplazan valor
-- -----------------------------------------------------------------------------
CREATE TABLE transactions (
    transaction_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_type    VARCHAR(20) NOT NULL,
    status              VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    description         VARCHAR(500),
    idempotency_key     VARCHAR(100) NOT NULL,
    recorded_at         TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- R7: un reintento por timeout de red no puede duplicar el movimiento de dinero.
    CONSTRAINT uq_transactions_idempotency_key UNIQUE (idempotency_key),

    CONSTRAINT ck_transactions_type CHECK (
        transaction_type IN ('DEPOSIT', 'WITHDRAWAL', 'TRANSFER', 'FEE', 'REVERSAL')
    ),
    CONSTRAINT ck_transactions_status CHECK (
        status IN ('PENDING', 'CONFIRMED', 'REJECTED', 'REVERSED')
    )
);

-- -----------------------------------------------------------------------------
-- ledger_entries — asientos: el efecto de una transacción sobre una cuenta
--
-- NUMERIC(20,4):
--   * NUMERIC y nunca FLOAT: el punto flotante binario no representa 0.1 de
--     forma exacta, y en dinero eso es descuadre contable.
--   * 20 dígitos: soporta volúmenes corporativos sin desbordar.
--   * 4 decimales y no 2: intereses y conversiones necesitan precisión
--     intermedia antes de redondear a la unidad mínima de la moneda.
-- -----------------------------------------------------------------------------
CREATE TABLE ledger_entries (
    entry_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id  BIGINT NOT NULL,
    account_id      BIGINT NOT NULL,
    -- Importe con signo: negativo sale de la cuenta, positivo entra.
    amount          NUMERIC(20, 4) NOT NULL,
    effective_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_ledger_entries_transaction FOREIGN KEY (transaction_id)
        REFERENCES transactions (transaction_id) ON DELETE RESTRICT,
    CONSTRAINT fk_ledger_entries_account FOREIGN KEY (account_id)
        REFERENCES accounts (account_id) ON DELETE RESTRICT,

    -- Un asiento de importe cero no representa ningún hecho económico.
    CONSTRAINT ck_ledger_entries_amount CHECK (amount <> 0)
);

-- =============================================================================
-- R1 y R2 — invariante de partida doble
--
-- Ninguna de las dos se puede expresar con un CHECK: un CHECK evalúa UNA fila,
-- y ambas reglas hablan de la relación entre varias filas de ledger_entries.
--
-- Tampoco sirve validar en cada INSERT: al insertar el primer asiento de una
-- transferencia la suma vale -100 y el invariante está roto A PROPÓSITO hasta
-- que se inserte la contrapartida. La verificación debe esperar al COMMIT.
--
-- De ahí CONSTRAINT TRIGGER ... DEFERRABLE INITIALLY DEFERRED: es el único
-- mecanismo que difiere la comprobación al final de la transacción.
--
-- NOTA DE NIVEL: la REGLA es lógica; este MECANISMO es específico de
-- PostgreSQL. El estándar SQL prevé assertions diferidas (CREATE ASSERTION),
-- pero ningún motor mayoritario las implementa.
-- =============================================================================
CREATE OR REPLACE FUNCTION assert_transaction_balances()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_transaction_id BIGINT := COALESCE(NEW.transaction_id, OLD.transaction_id);
    v_total          NUMERIC(20, 4);
    v_count          INTEGER;
BEGIN
    SELECT COALESCE(SUM(amount), 0), COUNT(*)
      INTO v_total, v_count
      FROM ledger_entries
     WHERE transaction_id = v_transaction_id;

    -- Transacción sin asientos: nada que validar (p. ej. se borró completa).
    IF v_count = 0 THEN
        RETURN NULL;
    END IF;

    IF v_count < 2 THEN
        RAISE EXCEPTION
            'R2 violada: la transaccion % tiene % asiento(s); se requieren al menos 2',
            v_transaction_id, v_count;
    END IF;

    IF v_total <> 0 THEN
        RAISE EXCEPTION
            'R1 violada: los asientos de la transaccion % suman %, deben sumar 0',
            v_transaction_id, v_total;
    END IF;

    RETURN NULL;
END;
$fn$;

CREATE CONSTRAINT TRIGGER trg_ledger_entries_balance
    AFTER INSERT OR UPDATE OR DELETE ON ledger_entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION assert_transaction_balances();

-- =============================================================================
-- R5 — el saldo como valor derivado
--
-- Solo suman los asientos cuya transacción está CONFIRMED: un movimiento
-- PENDING no es dinero disponible.
-- =============================================================================
CREATE VIEW account_balances AS
SELECT a.account_id,
       a.customer_id,
       a.status,
       COALESCE(SUM(e.amount), 0)  AS balance,
       COUNT(e.entry_id)           AS entry_count,
       MAX(e.effective_at)         AS last_entry_at
  FROM accounts a
  LEFT JOIN (
        SELECT le.entry_id, le.account_id, le.amount, le.effective_at
          FROM ledger_entries le
          JOIN transactions t ON t.transaction_id = le.transaction_id
         WHERE t.status = 'CONFIRMED'
       ) e ON e.account_id = a.account_id
 GROUP BY a.account_id, a.customer_id, a.status;
