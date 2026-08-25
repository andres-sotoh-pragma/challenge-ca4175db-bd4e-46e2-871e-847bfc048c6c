# Reto de Modelamiento Físico de Bases de Datos

En el contexto de una empresa fintech, se requiere diseñar y modelar una base de datos física que soporte un sistema de gestión de transacciones financieras. El sistema debe ser capaz de manejar altas cargas de transacciones y garantizar la integridad de los datos. Se espera que el modelo de datos sea eficiente y escalable.

## Informacion General

| Campo | Valor |
|-------|-------|
| **Tema** | Modelamiento de bases de datos físico |
| **Nivel** | senior-l1 |
| **Tipo** | practical |
| **Tiempo estimado** | 4-6 horas |

## Fases del Reto

### Fase 0: Configuración del Proyecto

**Objetivo:** Obtener el proyecto base funcional enviando el Código Base a un asistente de IA, que lo analizará, corregirá errores y generará un ZIP listo para usar.

**Tiempo estimado:** 15-30 minutos

**Instrucciones:**

- Asegúrate de tener instalado para ejecutar el proyecto: Un IDE o editor de código.
- Copia todo el contenido del campo **Código Base** de este reto — incluyendo el texto de instrucciones que aparece al inicio.
- Abre un asistente de IA (Claude en claude.ai, ChatGPT o Gemini — se recomienda Claude), pega el contenido copiado en el chat y envíalo.
- El asistente analizará los archivos, corregirá errores y generará un archivo ZIP descargable. Descárgalo y extráelo en la carpeta donde quieras trabajar.
- Verifica que el proyecto arranca sin errores.

**Entregable:** El proyecto compila/arranca sin errores.

<details>
<summary>Pistas de conocimiento</summary>

- Copia el Código Base completo incluyendo el texto de instrucciones al inicio — esas instrucciones le indican al asistente exactamente qué hacer con los archivos.
- Si el asistente no genera el ZIP automáticamente al terminar el análisis, escríbele: "genera el ZIP ahora".
- Si el proyecto tiene errores al arrancar, comparte el mensaje de error con el mismo asistente para que lo corrija.

</details>

### Fase 1: Definición del modelo conceptual

**Objetivo:** Definir el modelo conceptual de la base de datos que representa los requisitos del sistema de transacciones financieras.

**Tiempo estimado:** 1 hora

**Instrucciones:**

- Identifica las entidades y relaciones necesarias para representar transacciones financieras.
- Define los atributos de cada entidad y las relaciones entre ellas.

**Entregable:** Modelo conceptual de la base de datos en formato de diagrama de entidad-relación.

<details>
<summary>Pistas de conocimiento</summary>

- Considera la necesidad de manejar grandes volúmenes de datos y transacciones concurrentes.
- Piensa en la escalabilidad y rendimiento del modelo.

</details>

### Fase 2: Diseño del modelo lógico

**Objetivo:** Transformar el modelo conceptual en un modelo lógico, definiendo las tablas y relaciones en la base de datos.

**Tiempo estimado:** 2 horas

**Instrucciones:**

- Convierte las entidades y relaciones del modelo conceptual en tablas y columnas.
- Define las claves primarias y extranjeras para establecer las relaciones entre tablas.

**Entregable:** Modelo lógico de la base de datos en formato de diagrama de tablas.

<details>
<summary>Pistas de conocimiento</summary>

- Asegúrate de que las tablas y columnas sean consistentes con el modelo conceptual.
- Considera la normalización de las tablas para evitar redundancia y mejorar el rendimiento.

</details>

### Fase 3: Optimización del modelo físico

**Objetivo:** Optimizar el modelo lógico para crear un modelo físico eficiente y escalable.

**Tiempo estimado:** 2 horas

**Instrucciones:**

- Aplica índices y particiones para mejorar el rendimiento de las consultas.
- Considera la distribución de datos y el balanceo de carga para escalar el sistema.

**Entregable:** Modelo físico de la base de datos con índices y particiones aplicadas.

<details>
<summary>Pistas de conocimiento</summary>

- Evalúa el impacto de los índices en el rendimiento de las consultas.
- Considera la distribución de datos y el balanceo de carga para escalar el sistema.

</details>

## Dimensiones Evaluadas

- **queEs**: ¿Qué es una entidad en el modelo conceptual y cómo se transforma en una tabla en el modelo lógico?
- **paraQueSirve**: ¿Para qué sirven las claves primarias y extranjeras en el modelo lógico?
- **comoSeUsa**: ¿Cómo se utilizan los índices y particiones para optimizar el modelo físico?
- **erroresComunes**: ¿Cuáles son los errores comunes al normalizar tablas en el modelo lógico?
- **queDecisionesImplica**: ¿Qué decisiones implica la distribución de datos y el balanceo de carga en el modelo físico?

## Criterios de Evaluacion

- Definir correctamente el modelo conceptual de la base de datos.
- Transformar el modelo conceptual en un modelo lógico consistente.
- Optimizar el modelo lógico para crear un modelo físico eficiente y escalable.

---

*Reto generado automaticamente por Challenge Generator - Pragma*
