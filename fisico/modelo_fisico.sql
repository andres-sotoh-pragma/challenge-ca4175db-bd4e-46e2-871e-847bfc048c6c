-- =============================================================================
-- Fase 3 — Modelo Físico
-- Sistema de transacciones financieras con contabilidad de partida doble.
--
-- Este archivo es AUTOCONTENIDO (igual que logico/modelo_logico.sql): no se
-- ejecuta "encima" del modelo lógico, lo reemplaza. La razón es de fondo, no
-- de estilo: PostgreSQL no permite convertir una tabla ya creada en
-- particionada (lo comprobamos en Fase 0, capa 2 del análisis de errores).
-- PARTITION BY solo puede declararse en el CREATE TABLE original.
--
-- Qué cambia respecto a logico/modelo_logico.sql (las columnas y CHECKs de
-- negocio son los mismos; lo que sigue es exclusivamente físico):
--   1. `ledger_entries` pasa a estar particionada por RANGE (effective_at).
--   2. Índices para los patrones de consulta reales (extracto por cuenta,
--      asientos de una transacción, transacciones por estado/fecha).
--   3. El saldo se materializa en `account_balance_snapshot`, sincronizado
--      por trigger — la vista `account_balances` de Fase 2 se conserva como
--      mecanismo de verificación (recomputa desde cero; debe coincidir
--      siempre con el snapshot).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- customers — sin cambios físicos respecto a Fase 2.
-- -----------------------------------------------------------------------------
CREATE TABLE customers (
    customer_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name       VARCHAR(200) NOT NULL,
    email           VARCHAR(320) NOT NULL,
    registered_at   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_customers_email UNIQUE (email),
    CONSTRAINT ck_customers_full_name CHECK (length(trim(full_name)) > 0),
    CONSTRAINT ck_customers_email CHECK (position('@' IN email) > 1)
);

-- -----------------------------------------------------------------------------
-- accounts
--
-- Índice nuevo: idx_accounts_customer. Sin él, listar las cuentas de un
-- cliente (o el ON DELETE RESTRICT al intentar borrar un customer) hace un
-- seq scan de toda la tabla. Es la contraparte de una FK: Postgres nunca crea
-- automáticamente un índice sobre la columna que referencia, solo sobre la
-- que es referenciada.
-- -----------------------------------------------------------------------------
CREATE TABLE accounts (
    account_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id     BIGINT NOT NULL,
    status          VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    opened_at       TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    closed_at       TIMESTAMP WITH TIME ZONE,

    CONSTRAINT fk_accounts_customer FOREIGN KEY (customer_id)
        REFERENCES customers (customer_id) ON DELETE RESTRICT,
    CONSTRAINT ck_accounts_status CHECK (status IN ('ACTIVE', 'BLOCKED', 'CLOSED')),
    CONSTRAINT ck_accounts_closed_at CHECK (
        (status = 'CLOSED' AND closed_at IS NOT NULL) OR
        (status <> 'CLOSED' AND closed_at IS NULL)
    ),
    CONSTRAINT ck_accounts_dates CHECK (closed_at IS NULL OR closed_at >= opened_at)
);

CREATE INDEX idx_accounts_customer ON accounts (customer_id);

-- -----------------------------------------------------------------------------
-- transactions
--
-- NO se particiona. Es la tabla más pequeña (1 fila por evento de negocio;
-- ledger_entries tiene ≥2 por transacción) y, a diferencia de ledger_entries,
-- es mutable (status cambia de PENDING a CONFIRMED/REJECTED/REVERSED).
-- Particionarla obligaría a que su PK incluyera la columna de partición, lo
-- que a su vez rompería la FK simple que hoy tiene ledger_entries hacia ella
-- (pasaría a ser compuesta) — complejidad real sin un beneficio claro todavía,
-- porque su volumen es la mitad del de ledger_entries. Si el volumen de
-- transactions se vuelve el cuello de botella, esto se revisita.
--
-- Índices nuevos: idx_transactions_status (consultas operativas: "todo lo
-- PENDING") e idx_transactions_recorded_at (reportes por fecha). El índice de
-- idempotency_key ya existe implícito en su UNIQUE constraint.
-- -----------------------------------------------------------------------------
CREATE TABLE transactions (
    transaction_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_type    VARCHAR(20) NOT NULL,
    status              VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    description         VARCHAR(500),
    idempotency_key     VARCHAR(100) NOT NULL,
    recorded_at         TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_transactions_idempotency_key UNIQUE (idempotency_key),
    CONSTRAINT ck_transactions_type CHECK (
        transaction_type IN ('DEPOSIT', 'WITHDRAWAL', 'TRANSFER', 'FEE', 'REVERSAL')
    ),
    CONSTRAINT ck_transactions_status CHECK (
        status IN ('PENDING', 'CONFIRMED', 'REJECTED', 'REVERSED')
    )
);

CREATE INDEX idx_transactions_status ON transactions (status);
CREATE INDEX idx_transactions_recorded_at ON transactions (recorded_at);

-- -----------------------------------------------------------------------------
-- ledger_entries — particionada por RANGE (effective_at)
--
-- Por qué RANGE y no HASH: el patrón de consulta dominante en un ledger es
-- temporal (extracto del mes, cierre contable, retención regulatoria "guardar
-- N años"). RANGE por fecha permite:
--   * partition pruning real en esas consultas (el planner descarta
--     particiones enteras sin abrirlas),
--   * archivar o purgar un período completo con DETACH/DROP PARTITION en
--     lugar de un DELETE masivo fila por fila.
-- HASH por account_id repartiría mejor la escritura, pero cualquier consulta
-- por fecha tendría que tocar TODAS las particiones — es el patrón que menos
-- nos sirve acá.
--
-- La PK deja de ser solo entry_id: PostgreSQL exige que toda PK/UNIQUE de una
-- tabla particionada incluya la columna de partición. Esto no debilita la
-- unicidad real: entry_id sigue viniendo de una única secuencia IDENTITY
-- compartida por todas las particiones, así que (entry_id, effective_at) es
-- unique de la misma forma que entry_id solo lo era.
--
-- Particiones: mensuales, 2024-01 a 2025-12 (24 meses, rango pensado para el
-- dataset de benchmark de Fase 3) + una partición DEFAULT de seguridad, para
-- que un INSERT con fecha fuera de rango falle por falta de partición y no
-- se pierda silenciosamente.
--
-- Nota de producción: crear una partición nueva a mano cada mes no escala
-- operativamente. La extensión estándar para esto es `pg_partman`, que las
-- crea y purga automáticamente. No se agrega acá para no sumar una
-- dependencia de extensión al entregable, pero es el paso siguiente real.
-- -----------------------------------------------------------------------------
CREATE TABLE ledger_entries (
    entry_id        BIGINT GENERATED ALWAYS AS IDENTITY,
    transaction_id  BIGINT NOT NULL,
    account_id      BIGINT NOT NULL,
    amount          NUMERIC(20, 4) NOT NULL,
    effective_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_ledger_entries PRIMARY KEY (entry_id, effective_at),
    CONSTRAINT fk_ledger_entries_transaction FOREIGN KEY (transaction_id)
        REFERENCES transactions (transaction_id) ON DELETE RESTRICT,
    CONSTRAINT fk_ledger_entries_account FOREIGN KEY (account_id)
        REFERENCES accounts (account_id) ON DELETE RESTRICT,
    CONSTRAINT ck_ledger_entries_amount CHECK (amount <> 0)
) PARTITION BY RANGE (effective_at);

-- Índices declarados sobre la tabla particionada: PostgreSQL los propaga a
-- cada partición existente y a cada una que se agregue después.
--
-- (account_id, effective_at) — soporta el extracto de una cuenta en un rango
-- de fechas: pruning por effective_at + acceso directo por account_id dentro
-- de cada partición, en un solo índice.
CREATE INDEX idx_ledger_entries_account_date ON ledger_entries (account_id, effective_at);

-- transaction_id — soporta "todos los asientos de esta transacción", que es
-- exactamente lo que hace el trigger de R1/R2 en cada COMMIT. Sin este
-- índice, verificar el balance de una transacción sería un seq scan de la
-- partición completa por cada COMMIT.
CREATE INDEX idx_ledger_entries_transaction ON ledger_entries (transaction_id);

CREATE TABLE ledger_entries_default PARTITION OF ledger_entries DEFAULT;

DO $$
DECLARE
    v_month DATE := DATE '2024-01-01';
BEGIN
    WHILE v_month < DATE '2026-01-01' LOOP
        EXECUTE format(
            'CREATE TABLE %I PARTITION OF ledger_entries FOR VALUES FROM (%L) TO (%L)',
            'ledger_entries_' || to_char(v_month, 'YYYY_MM'),
            v_month,
            v_month + INTERVAL '1 month'
        );
        v_month := v_month + INTERVAL '1 month';
    END LOOP;
END $$;

-- =============================================================================
-- R1 y R2 — invariante de partida doble (idéntico a Fase 2; ver
-- logico/modelo_logico.sql para la explicación completa de por qué es un
-- CONSTRAINT TRIGGER diferido y no un CHECK).
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
-- account_balances — vista de verificación (idéntica a Fase 2).
--
-- Recomputa el saldo desde cero recorriendo ledger_entries. Se conserva a
-- propósito: es la fuente de verdad contra la que se valida que el snapshot
-- de abajo nunca se desincronice. Cara para leer a alta frecuencia (por eso
-- nace el snapshot), pero imposible que esté "mal" — no acumula error.
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

-- =============================================================================
-- account_balance_snapshot — el saldo materializado (la decisión de Fase 3).
--
-- Una fila por cuenta, mantenida al día por trigger. Lectura O(1) por PK en
-- lugar de agregar sobre todo el historial de la cuenta. Sigue siendo
-- "seguro" en el mismo sentido que Fase 2 exigía: se actualiza dentro de la
-- misma transacción que confirma los movimientos, nunca por un proceso
-- aparte que se pueda desincronizar por un batch fallido.
-- =============================================================================
CREATE TABLE account_balance_snapshot (
    account_id      BIGINT PRIMARY KEY
                        REFERENCES accounts (account_id) ON DELETE RESTRICT,
    balance         NUMERIC(20, 4) NOT NULL DEFAULT 0,
    entry_count     INTEGER NOT NULL DEFAULT 0,
    last_entry_at   TIMESTAMP WITH TIME ZONE,
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE FUNCTION seed_account_balance_snapshot()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
BEGIN
    INSERT INTO account_balance_snapshot (account_id) VALUES (NEW.account_id);
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_accounts_seed_snapshot
    AFTER INSERT ON accounts
    FOR EACH ROW
    EXECUTE FUNCTION seed_account_balance_snapshot();

-- -----------------------------------------------------------------------------
-- Máquina de estados de `transactions.status` — necesaria para que el
-- snapshot sepa CUÁNDO sumar un movimiento.
--
-- account_balances (la vista) ya filtraba "solo CONFIRMED" desde Fase 2: un
-- movimiento PENDING no es dinero disponible todavía. El snapshot tiene que
-- respetar la misma regla, pero al ser una tabla mantenida por trigger
-- necesita un evento concreto que dispare la suma: la transición de status.
--
-- Transiciones válidas (y las únicas que disparan el sync):
--   PENDING   -> CONFIRMED   (suma los asientos al snapshot)
--   PENDING   -> REJECTED    (no afecta el snapshot: nunca fue dinero real)
--   CONFIRMED -> REVERSED    (resta los asientos del snapshot)
-- Cualquier otra transición (ej. CONFIRMED -> CONFIRMED, REJECTED -> *,
-- REVERSED -> *) se rechaza: son estados terminales. Y toda transacción nace
-- PENDING — se fuerza en el INSERT — porque el snapshot solo sabe conciliar
-- una transición, no un estado inicial arbitrario.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enforce_transaction_status_machine()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'PENDING' THEN
            RAISE EXCEPTION
                'toda transaccion nace PENDING; se intento crear con status %',
                NEW.status;
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;

    IF (OLD.status, NEW.status) NOT IN (
        ('PENDING', 'CONFIRMED'),
        ('PENDING', 'REJECTED'),
        ('CONFIRMED', 'REVERSED')
    ) THEN
        RAISE EXCEPTION
            'transicion de status invalida: % -> % (transaccion %)',
            OLD.status, NEW.status, OLD.transaction_id;
    END IF;

    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_transactions_status_machine
    BEFORE INSERT OR UPDATE OF status ON transactions
    FOR EACH ROW
    EXECUTE FUNCTION enforce_transaction_status_machine();

CREATE OR REPLACE FUNCTION sync_account_balance_snapshot()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_sign SMALLINT;
BEGIN
    IF NEW.status = 'CONFIRMED' THEN
        v_sign := 1;
    ELSIF NEW.status = 'REVERSED' THEN
        v_sign := -1;
    ELSE
        RETURN NEW;
    END IF;

    UPDATE account_balance_snapshot s
       SET balance       = s.balance + v_sign * le.amount_sum,
           entry_count   = s.entry_count + v_sign * le.entry_cnt,
           last_entry_at = GREATEST(s.last_entry_at, le.max_effective_at),
           updated_at    = CURRENT_TIMESTAMP
      FROM (
            SELECT account_id,
                   SUM(amount)      AS amount_sum,
                   COUNT(*)         AS entry_cnt,
                   MAX(effective_at) AS max_effective_at
              FROM ledger_entries
             WHERE transaction_id = NEW.transaction_id
             GROUP BY account_id
           ) le
     WHERE s.account_id = le.account_id;

    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_transactions_sync_snapshot
    AFTER UPDATE OF status ON transactions
    FOR EACH ROW
    WHEN (NEW.status IN ('CONFIRMED', 'REVERSED') AND NEW.status IS DISTINCT FROM OLD.status)
    EXECUTE FUNCTION sync_account_balance_snapshot();
