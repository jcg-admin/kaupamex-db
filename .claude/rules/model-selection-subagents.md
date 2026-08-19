```yml
type: Convención de Proyecto
category: Operación del agente — selección de modelo para subagentes
version: 1.0.0
created_at: 2026-07-05T00:56:41
applies_to: kaupamex v1.0.0+
origen: directiva ejecutor 2026-07-05 ("no es necesario que ejecutes solo
  agentes del modelo Opus; usa Fable 5 / Sonnet 5 / Haiku 4.5 para
  equilibrar el gasto de tokens")
```

# Selección de modelo para subagentes — balance de tokens

> Cargado automáticamente en cada sesión (I-009).
> Regla de operación: NO despachar todos los subagentes en Opus por
> defecto. Elegir el modelo por la **naturaleza de la tarea** para
> equilibrar el gasto de tokens.

## El problema que esta regla resuelve

Opus 4.8 es el modelo más caro. Usarlo para toda tarea de subagente
(research documental, drafting, greps dirigidos, transformaciones
mecánicas) quema tokens sin ganancia de calidad proporcional. Evidencia
del defecto (2026-07-05): un agente de **análisis documental** corrió en
Opus y consumió ~410k tokens para una tarea que Sonnet 5 o Fable 5
habrían hecho a una fracción del costo.

## Antes de elegir modelo: ¿despachar o no? — el costo lo domina lo que RELEE

Medido 2026-08-18 sobre **216 agentes** del store (`agent_sessions`), el gasto
no está donde se supone:

| Componente | tokens | % |
|---|---|---|
| `cache_read` | 4 150 264 618 | **97.8 %** |
| `cache_creation` | 93 214 449 | 2.2 % |
| `output` | 746 110 | 0.0 % |
| `input` | 106 405 | 0.0 % |

Acortar el prompt o pedir menos salida **no ahorra nada**: los dos son 0.0 %.
Lo que se paga es el contexto que el agente **relee en cada turno**, y por eso
escala con los turnos:

| turnos | n | `cache_read` medio | `equiv_cost` medio |
|---|---|---|---|
| 1-3 | 12 | 246 k | 338 k |
| 4-8 | 7 | 1 451 k | 502 k |
| 9-20 | 45 | 4 238 k | 861 k |
| **21+** | **152** | **25 963 k** | **3 218 k** |

Un agente de 21+ turnos cuesta **~9.5×** uno de 1-3 — y **152 de 216 (70 %)**
cayeron en ese tramo.

**La regla:** antes de despachar, preguntar si el trabajo es *ancho* o sólo
*largo*.

- **Ancho y paralelo** — N lotes independientes, cada uno con su propio árbol de
  archivos → **despachar**. Es donde el agente rinde.
- **Conocido y acotado** — una lista de archivos que ya se nombró → **lo hace el
  orquestador**. Su contexto ya está caliente; el agente paga **en frío** el
  piso siempre-cargado (medido: **126 029 tokens**, H-DOCS-99) más todo lo que
  lea, y lo paga **por turno**.

**El prompt no acota el gasto: acota los turnos, que es lo que lo causa.** Un
agente con los archivos nombrados y la condición de cierre fijada da pocos
turnos; uno al que se le da un objetivo y que descubra el alcance da sesenta.
Mismo entregable, ~10×.

**Corolario para el propio orquestador.** Un comando sin acotar cuesta lo mismo
por la vía del tiempo. Un `grep` recursivo sobre `odoo-tools` —**566 917
archivos**— agota el timeout de 2 min y devuelve nada. Acotar con `--include`,
`-maxdepth` o una raíz concreta es la misma disciplina que acotar el prompt.

Ver :ref:`h-docs-177` para la serie completa y :ref:`h-docs-169` para por qué el
titular del harness no sirve para medir esto.

## Regla principal

Al invocar `Agent`, pasar `model:` explícito según la tarea. **Reservar
Opus para el razonamiento más difícil**; el resto va a modelos más
económicos.

| Modelo (`model:`) | Cuándo usarlo |
|---|---|
| `opus` (Opus 4.8) | Razonamiento complejo o adversarial de alto riesgo, síntesis crítica, decisiones arquitectónicas, verificación que sella un gate, orquestación de varias fuentes en conflicto. **No** es el default. |
| `sonnet` (Sonnet 5) | Análisis y documentación sustanciales, research multi-archivo, drafting de artefactos RST con citas PROVEN. **Default recomendado** para el grueso de los subagentes de análisis/redacción. |
| `fable` (Fable 5) | Alternativa económica para análisis/redacción cuando está disponible (ver caveat abajo). Útil para equilibrar el gasto en tandas grandes. |
| `haiku` (Haiku 4.5) | **NO DESPACHABLE HOY** — medido 2026-08-07: con los cinco repos en scope el contexto siempre-cargado es de **126 029 tokens de piso**, y Haiku 4.5 falla con `Prompt is too long` incluso con un prompt propio de 450 caracteres (tres intentos; Sonnet 5 arrancó). Ver H-DOCS-99. La fila se reabre cuando se mida un scope en el que Haiku arranque — decisión de alcance #200. Hasta entonces, para tareas mecánicas usar `sonnet`. |

**Regla de oro:** si la tarea es "leer N archivos y redactar un análisis
con citas", el default es `sonnet` o `fable`, **no** `opus`. Si es
"decidir entre opciones en conflicto con trade-offs finos" o "verificar
adversarialmente un claim de alto riesgo", entonces `opus`.

## Obligatorio: cada subagente entrega su documento en la iniciativa

**El modelo económico NO relaja el entregable.** Sea cual sea el modelo
asignado, **todo subagente de análisis DEBE producir y persistir un
documento de análisis** (`analisis-<slug>.rst` o `reporte-<slug>.rst`)
**en la iniciativa correspondiente** antes de devolver su resumen. El
resumen al orquestador **no sustituye** al documento: es el principio
"**el productor persiste**" de `registro-reportes-agentes.md` — el padre
solo ve el resumen; el análisis completo se pierde si el propio subagente
no lo escribe en `docs/`.

Reglas (aplican a cualquier modelo, incluido Haiku/Fable):

- El documento va en la iniciativa que motivó el trabajo
  (`docs/source/gestion/pm/<submodulo>/iniciativas/<slug>/`), con la
  metadata Template A y citas **PROVEN** `file:line`.
- El subagente **verifica que el archivo aterrizó** (`test -f` /
  `git ls-files`) antes de declarar hecho (`react-verification-gate.md`
  punto 5).
- **Aislamiento de working tree**: en una tanda paralela cada subagente
  escribe **SU** archivo distinto y **NO** ejecuta `git add`/`commit`; el
  orquestador consolida, valida (docutils) e integra en un solo commit
  (evita carreras de `git add`; ver `bash-background-tasks.md`).
- El prompt del subagente debe **nombrar explícitamente** la ruta del
  archivo a escribir y la estructura mínima esperada (Contexto,
  Evidencia PROVEN, Opciones, Trade-offs, Recomendación preliminar,
  Preguntas abiertas) — no dejarlo a criterio del agente.

Elegir un modelo más barato optimiza el **costo**, nunca el **entregable**:
el documento que aterriza en la iniciativa es idéntico en exigencia.

## Subagentes que modifican código (api / ui / db)

Cuando un subagente **modifica código** (no solo análisis) en `api`, `ui`
o `db`, el cambio queda documentado en **DOS lugares**, no uno:

1. **En el repo de código** (`api`/`ui`/`db`): el commit del cambio, con
   mensaje Tim Pope que explica QUÉ y POR QUÉ (author Nestor, committer
   jcg-admin); y, si el cambio lo amerita, la doc de código del propio
   repo (docstring / README / CHANGELOG del submódulo).
2. **En la iniciativa que lanzó al agente** (docs): el hallazgo o reporte
   en `docs/source/gestion/pm/<submodulo>/iniciativas/<slug>/` — o en
   `audits/hallazgos-<slug>.rst` según
   `hallazgos-documentacion-obligatoria.md` — **enlazando `repo@hash`** del
   commit de código.

Es la **secuencia de dos commits** de
`hallazgos-documentacion-obligatoria.md`: (1) commit en el repo de código,
(2) commit en docs con la traza `repo@hash`. El resumen del agente al
orquestador **no sustituye** ninguno de los dos. La iniciativa en docs es
el **hogar de trazabilidad**: desde ahí se ve qué tocó cada agente, en qué
repo y en qué commit. Sin ese enlace, el trabajo del agente desaparece del
historial cuando el agente termina.

Esta regla vive en `.claude/rules/` de **los cuatro repos** (docs, api, ui,
db) porque los subagentes se despachan desde cualquiera de ellos; el
contenido es idéntico y la iniciativa de destino siempre está en `docs`.

## Caveat de disponibilidad — Fable 5

Fable 5 **está disponible por ahora** (directiva ejecutor 2026-07-05) y
puede usarse. Sin embargo, **de forma intermitente el harness puede
indicar que Fable 5 no está disponible**. Manejo:

1. Intentar `model: "fable"` cuando aplique.
2. Si el harness reporta que Fable 5 no está disponible → **degradar** a
   `sonnet` (o `haiku` si la tarea es mecánica). No bloquear el trabajo
   por la indisponibilidad de un modelo.
3. No afirmar "Fable 5 no está disponible" de memoria — es un hecho de
   estado del entorno; derivarlo de la respuesta real del harness
   (`react-verification-gate.md`).

## Tandas paralelas — mezclar modelos

En una tanda de N agentes independientes (Clausula 6 de
`principio-rector-rup-arquitectura.md`), asignar el modelo por agente:

```python
# Ejemplo: 6 análisis documentales independientes
Agent(description="análisis d-1 ...", model="sonnet", ...)
Agent(description="análisis d-2 ...", model="fable",  ...)
Agent(description="análisis d-3 ...", model="sonnet", ...)   # el más denso
Agent(description="análisis d-4 ...", model="haiku",  ...)   # inventario/tabla
Agent(description="análisis d-5 ...", model="fable",  ...)
Agent(description="análisis d-6 ...", model="sonnet", ...)
# Reservar opus solo si una de las decisiones es de alto riesgo.
```

Criterio: la densidad de razonamiento del ítem manda, no la comodidad de
poner todo igual.

**Los seis NO corren a la vez.** Añadido 2026-08-19 (:ref:`h-docs-211`): el
ejemplo de arriba se leía como un fan-out de seis, y no lo es. Medido en el
ejecutable de esta sesión (`/opt/claude-code/bin/claude`, 2.1.235):

- la **anchura** del tool `Agent` la acota su propio guard
  (`hip(){return K.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS??K5b}`, `K5b=20`);
- la **anchura de `parallel()`** dentro de `Workflow` es **otro** mecanismo:
  `min(16, CPUs−2)` — con `nproc` = 4 aquí, **2**;
- la **profundidad** es un tercer cap (`MW()`), y en este entorno vale **1**,
  así que un subagente **no puede lanzar subagentes**.

Consecuencia para el gasto, que es lo que esta regla gobierna: una tanda de N
con el cap en C **es una cola**, no un fan-out. El reloj de pared es ≈ Σtᵢ/C.
Repartir modelos entre seis agentes no compra seis veces menos tiempo; compra
lo que el cap deje pasar. El desglose y los comandos para re-medirlo están en
`bash-background-tasks.md`, sección «ANCHURA y PROFUNDIDAD».

## Qué NO cambia

- La **calidad de la evidencia** no depende del modelo: todo subagente,
  sea cual sea el modelo, sigue `calibration-verified-numbers.md`,
  `react-verification-gate.md` y `auto-audit-before-writing.md` (citas
  PROVEN `file:line`, no inventar cifras).
- El **identificador del modelo** (`claude-opus-4-8`, etc.) NO se escribe
  en commits, PRs, ni artefactos versionados — solo en chat/configuración.
- El orquestador principal conserva su modelo de sesión; esta regla
  aplica a los **subagentes** que despacha.

## Verificación

El parámetro se pasa en la llamada `Agent(..., model="sonnet")`. No hay
gate automático; es una decisión de operación consciente por tanda.

## Severidad

**MEDIA** — sin esta regla se reincide en despachar todo en Opus,
disparando el gasto de tokens sin ganancia de calidad. No bloquea el
flujo, pero su ausencia reintroduce el sobrecosto observado el
2026-07-05.

## Relación con otras reglas

- `principio-rector-rup-arquitectura.md` (Clausula 6): despacho paralelo
  de agentes independientes — esta regla fija **qué modelo** por agente.
- `react-verification-gate.md`: la disponibilidad de Fable 5 es un hecho
  de estado — no se afirma de memoria.
- `calibration-verified-numbers.md` / `auto-audit-before-writing.md`:
  aplican por igual a cualquier modelo de subagente.
