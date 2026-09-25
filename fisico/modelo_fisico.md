# Fase 3 — Modelo Físico

Optimización del modelo lógico (Fase 2) para un motor concreto: PostgreSQL 17.

> **Punto de partida.** El modelo lógico definía *qué* tablas, columnas y
> restricciones existen, sin comprometerse con rendimiento. Acá se responde
> *cómo* hacerlo eficiente a escala, sin tocar ni una regla de negocio: las
> mismas columnas, los mismos `CHECK`, el mismo trigger de R1/R2.

Entregables: `modelo_fisico.sql` (DDL autocontenido), `pruebas_modelo_fisico.sql`
(verificación de lo nuevo de esta fase) y el benchmark de esta página.

---

## Por qué es un archivo nuevo y no un `ALTER` sobre el lógico

PostgreSQL no permite convertir una tabla ya creada en particionada — se
comprobó en Fase 0, capa 2 del análisis de errores del código base
(`is not partitioned`). `PARTITION BY` solo puede declararse en el
`CREATE TABLE` original. Por eso `modelo_fisico.sql` es autocontenido, igual
que `modelo_logico.sql`: no se ejecuta "encima" de la Fase 2, la reemplaza.

---

## Decisión 1 — Particionar `ledger_entries` por `RANGE (effective_at)`

Es la única tabla particionada. Candidatos considerados:

| Estrategia | A favor | En contra |
|---|---|---|
| **RANGE por `effective_at`** (elegida) | El patrón de consulta dominante en un ledger es temporal: extractos, cierres contables, retención regulatoria. Permite *partition pruning* real y archivar/purgar un período completo con `DETACH`/`DROP PARTITION` en vez de un `DELETE` masivo. | Consultas que no filtran por fecha (ver Query 3 más abajo) no podan nada. |
| HASH por `account_id` | Reparte la escritura de forma pareja. | Cualquier consulta por rango de fechas tendría que tocar TODAS las particiones — es el patrón que menos nos sirve. |
| Particionar `transactions` también | Consistencia con `ledger_entries`. | Es la tabla más pequeña (1 fila por evento vs. ≥2 en `ledger_entries`) y es mutable (`status` cambia). Particionarla obligaría a una FK compuesta desde `ledger_entries`. Complejidad real sin beneficio claro todavía — se revisita si su volumen se vuelve el cuello de botella. |

**Consecuencia en la PK:** PostgreSQL exige que toda `PRIMARY KEY`/`UNIQUE` de
una tabla particionada incluya la columna de partición. `ledger_entries` pasa
de `PRIMARY KEY (entry_id)` a `PRIMARY KEY (entry_id, effective_at)`. No
debilita la unicidad real: `entry_id` sigue viniendo de una única secuencia
`IDENTITY` compartida por todas las particiones.

**Rango de particiones:** mensuales, `2024-01` a `2025-12` (24 particiones) +
una partición `DEFAULT` de seguridad, para que una fecha fuera de rango caiga
ahí en vez de fallar el `INSERT` o perderse silenciosamente. Verificado en el
caso 8 de `pruebas_modelo_fisico.sql`.

**Nota de producción:** crear una partición nueva a mano cada mes no escala
operativamente. `pg_partman` es la extensión estándar para automatizar esto
(creación y retención). No se agrega acá para no sumar una dependencia de
extensión al entregable — es el paso siguiente real, en la misma línea que
"multi-moneda" quedó señalado sin implementar en Fase 1.

---

## Decisión 2 — Materializar el saldo en `account_balance_snapshot`

En Fase 2 el saldo era 100 % derivado (`account_balances`, una `VIEW`). Correcto
por diseño — cero riesgo de desincronización — pero cada lectura recorre todo
el historial de la cuenta. A escala, es inviable para algo tan frecuente como
"¿cuánto tiene disponible esta cuenta?".

`account_balance_snapshot`: una fila por cuenta, actualizada por trigger
**dentro de la misma transacción** que confirma los movimientos. Es una
caché, no un reemplazo: `ledger_entries` sigue siendo la fuente de verdad
auditable, y la vista `account_balances` de Fase 2 se conserva íntegra como
mecanismo de verificación independiente — si alguna vez el snapshot se
desincroniza, comparar contra la vista lo detecta.

### La pieza que hizo falta: una máquina de estados sobre `transactions.status`

La vista de Fase 2 ya filtraba "solo `CONFIRMED`": un movimiento `PENDING` no
es dinero disponible. Una vista puede aplicar ese filtro en cada lectura sin
esfuerzo. Un snapshot mantenido por trigger no — necesita un **evento
concreto** que le diga cuándo sumar. Ese evento es la transición de estado:

```
PENDING   -> CONFIRMED   [suma los asientos al snapshot]
PENDING   -> REJECTED    [no afecta el snapshot: nunca fue dinero real]
CONFIRMED -> REVERSED    [resta los asientos del snapshot]
```

Cualquier otra transición se rechaza (`REJECTED -> CONFIRMED`,
`REVERSED -> CONFIRMED`, etc. — son estados terminales), y toda transacción
**nace `PENDING`** por trigger `BEFORE INSERT`: el snapshot solo sabe conciliar
una transición, no un estado inicial arbitrario. Esto es nuevo respecto a
Fase 2 — ahí las pruebas insertaban transacciones directamente como
`CONFIRMED`, y eso ahora está prohibido a propósito.

Verificado en los casos 1 a 5 de `pruebas_modelo_fisico.sql`: `INSERT` directo
en `CONFIRMED` falla, el ciclo `PENDING -> CONFIRMED` deja el snapshot igual a
la vista, `REJECTED -> CONFIRMED` falla, `CONFIRMED -> REVERSED` funciona y
devuelve el snapshot a cero, y `REVERSED -> CONFIRMED` falla.

---

## Índices

| Índice | Tabla | Para qué |
|---|---|---|
| `(account_id, effective_at)` | `ledger_entries` (por partición) | Extracto de una cuenta en un rango de fechas: pruning por fecha + acceso directo por cuenta en un solo índice. |
| `(transaction_id)` | `ledger_entries` (por partición) | Asientos de una transacción — exactamente lo que el trigger de R1/R2 consulta en cada `COMMIT`. |
| `(customer_id)` | `accounts` | Sin él, listar las cuentas de un cliente (o el `ON DELETE RESTRICT` al borrar un `customer`) es un seq scan completo. Una FK nunca crea automáticamente el índice sobre la columna que referencia, solo sobre la que es referenciada. |
| `(status)`, `(recorded_at)` | `transactions` | Consultas operativas ("todo lo `PENDING`") y reportes por fecha. `idempotency_key` ya tenía su índice implícito por el `UNIQUE`. |

---

## Benchmark: antes/después con datos idénticos

**Metodología.** `scripts/generar_volumen.py` genera con Faker (nunca con un
LLM: para volumen puro, un LLM fila por fila es lento y no aporta nada que
`random`/`Faker` no den) 5.000 clientes, 8.000 cuentas, 200.000 transacciones
y ≈440.000 asientos, con el mismo `--seed` para dos bases:

- `bench_before` — esquema de **Fase 2** (`modelo_logico.sql`): sin índices,
  sin particiones.
- `bench_after` — esquema de **Fase 3** (`modelo_fisico.sql`): particionado e
  indexado.

Se verificó que ambas bases tienen exactamente los mismos datos (mismo
`md5` sobre los montos, mismo total del sistema en 0). Evidencia completa en
`evidencias/03-fisico/03-benchmark-explain-analyze.txt`, generada con
`scripts/benchmark_fisico.sh`.

Nota sobre la carga: el trigger de R1/R2 y el de sincronización del snapshot
se desactivan durante la carga masiva y se reactivan después (el generador ya
garantiza el invariante; volver a verificarlo fila por fila 440.000 veces no
prueba nada que los 8 casos de `pruebas_modelo_fisico.sql` no hayan probado
ya). Es la misma práctica que aplicaría un ETL de producción.

| # | Consulta | `bench_before` | `bench_after` | Mejora |
|---|---|---|---|---|
| 1 | Extracto de una cuenta en un mes | 28,8 ms / 3.720 buffers (seq scan paralelo) | 1,4 ms / 163 buffers (bitmap scan, 1 partición) | **~21×** más rápido, ~23× menos buffers |
| 2 | Saldo actual de una cuenta | 69,1 ms / 9.761 buffers (`JOIN` + `GROUP BY` sobre todo el historial) | 0,13 ms / 6 buffers (lectura directa por PK) | **~544×** más rápido, ~1.600× menos buffers |
| 3 | Todos los asientos de una transacción | 10,3 ms / 3.720 buffers (seq scan, sin índice) | 0,88 ms / 52 buffers (índice, pero recorre las 25 particiones) | **~12×** más rápido, ~71× menos buffers |

### La consulta 3 es la que matiza la decisión de particionar

`transaction_id` no es la columna de partición, así que esta consulta **no
puede podar** ninguna partición: el plan es un `Append` con un `Index Scan`
por cada una de las 25 (24 mensuales + `DEFAULT`). Sigue ganando frente al seq
scan de `bench_before` porque cada sondeo indexado es barato, pero el
`Planning Time` sube de 0,26 ms a 10,5 ms — el optimizador tiene que
considerar las 25 particiones antes de ejecutar nada. Es el costo real y
documentado de particionar: **toda consulta que no filtra por la columna de
partición paga un impuesto de planificación proporcional al número de
particiones.** Si "traer los asientos de una transacción" fuera una consulta
crítica y muy frecuente (no lo es: es operativa, de soporte, no del camino
caliente de negocio), valdría la pena revisarlo — por ejemplo acotando primero
por `transactions.recorded_at` antes de tocar `ledger_entries`.

---

## Lo que se evaluó y no se implementó

- **Volumen de datos y `EXPLAIN ANALYZE` real** en vez de justificación
  teórica — sí se hizo (ver benchmark arriba), fue la decisión tomada con el
  usuario.
- **`pg_partman`** para automatizar la creación/retención de particiones —
  mencionado, no implementado (dependencia de extensión fuera del alcance del
  entregable).
- **R4 (inmutabilidad de `ledger_entries`)** seguía pendiente desde Fase 2;
  sigue pendiente. Un `REVOKE UPDATE, DELETE` a los roles de aplicación sería
  el mecanismo más barato (no cuesta nada en tiempo de ejecución), pero
  depende de que los permisos estén bien administrados.
