# Evidencias

Registro visual y textual de la ejecución de los modelos contra PostgreSQL 17.

| Carpeta | Contenido |
|---------|-----------|
| `00-errores-iniciales/` | Errores de los scripts **tal como vinieron** en el código base, antes de cualquier corrección. Línea base del reto. |
| `01-conceptual/` | Validación del modelo conceptual (Fase 1). |
| `02-logico/` | Validación del modelo lógico (Fase 2). |
| `03-fisico/` | Particionado, índices y `EXPLAIN` de consultas (Fase 3). |

## Convención de nombres

`<orden>-<script>-<resultado>.<ext>` — por ejemplo:

- `01-modelo-logico-error-fk.png`
- `01-modelo-logico-error-fk.txt` (salida cruda de psql)

Cada pantallazo debería tener su `.txt` con la salida de `psql` copiada, para que el error sea buscable y no solo una imagen.
