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

Despachar todo subagente al modelo más caro —research documental, drafting,
greps dirigidos, transformaciones mecánicas— quema tokens sin ganancia de
calidad proporcional. Evidencia del defecto (2026-07-05): un agente de
**análisis documental** corrió en un opus y consumió ~410k tokens para una
tarea que `claude-sonnet-5` habría hecho a una fracción del costo.

> Corregido 2026-08-20: este párrafo decía *«Opus 4.8 es el modelo más caro»*
> y proponía `fable` como el ahorro. Las dos afirmaciones son falsas contra el
> `pricing` medido: el más caro por token es `claude-fable-5` (10/50), el
> doble que `claude-opus-4-8`/`claude-opus-5` (5/25). Ver la tabla de
> registros abajo.

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

| `model:` (alias) | Identificador que resuelve aquí | Cuándo usarlo |
|---|---|---|
| `opus` | `claude-opus-5` | Razonamiento complejo o adversarial de alto riesgo, síntesis crítica, decisiones arquitectónicas, verificación que sella un gate, orquestación de varias fuentes en conflicto. **No** es el default. |
| `sonnet` | `claude-sonnet-5` | Análisis y documentación sustanciales, research multi-archivo, drafting de artefactos RST con citas PROVEN. **Default recomendado** para el grueso de los subagentes de análisis/redacción. |
| `fable` | `claude-fable-5` | **NO es la opción económica** — corregido 2026-08-20: cuesta **10/50 $/Mtok**, el doble que opus, y declara el `advisor_rank` más alto (5). Es el tope de capacidad del catálogo, no un ahorro. Se elige cuando el ítem lo justifique, nunca «para equilibrar el gasto». Ver caveat de disponibilidad abajo. |
| `haiku` | `claude-haiku-4-5` | **NO DESPACHABLE HOY** — medido 2026-08-07: con los cinco repos en scope el contexto siempre-cargado es de **126 029 tokens de piso**, y falla con `Prompt is too long` incluso con un prompt propio de 450 caracteres (tres intentos; `claude-sonnet-5` arrancó). Ver H-DOCS-99. La fila se reabre cuando se mida un scope en el que arranque — decisión de alcance #200. Hasta entonces, para tareas mecánicas usar `sonnet`. |

> Corregido 2026-08-20: la columna decía «`opus` (Opus 4.8)». El alias
> **no** resuelve a 4.8 — resuelve a `claude-opus-5`, medido abajo. Y la
> resolución **no es constante**, así que la columna del medio vale para el
> proveedor por defecto y no es una propiedad del alias.

### El alias NO es el modelo: resuelve distinto según el proveedor

Directiva del ejecutor 2026-08-20: *"para que no existan problemas, guárdala
como en su referencia: `claude-sonnet-5`, `claude-opus-5`, `claude-haiku-4-5`,
`claude-mythos-5`, etc."*. El motivo está en el propio binario — el bloque
`aliases` declara un `default` **y un mapa por proveedor**:

| alias | `default` | `bedrock` · `vertex` · `foundry` · `mantle` | `anthropic_aws` · `gateway` |
|---|---|---|---|
| `opus` | `claude-opus-5` | 5 · 5 · **4-6** · 5 | 5 · **4-7** |
| `sonnet` | `claude-sonnet-5` | **4-5** en los cuatro | **4-6** en los dos |
| `haiku` | `claude-haiku-4-5` | — (sin mapa por proveedor) | — |
| `fable` | `claude-fable-5` | — | — |

**Consecuencia:** `model: "sonnet"` no determina la versión, y por tanto **no
determina el tier de precio ni la ventana**. Un agente despachado con `sonnet`
puede haber corrido en `claude-sonnet-4-5` (ventana 200 k) o en
`claude-sonnet-5` (1 M). Por eso el store guarda el identificador que el
**transcript** declara (`message.model`), no el alias con que se despachó ni la
familia que trae el sidecar — ver :ref:`h-docs-219`.

El binario también declara `best:"fable"` y un `latest_per_family`
(`fable → claude-fable-5`, `opus → claude-opus-5`, `sonnet → claude-sonnet-5`,
`haiku → claude-haiku-4-5`).

*Métrica:* el bloque `aliases` del ejecutable 2.1.236.
*Ciega a:* qué proveedor sirve **esta** sesión — el mapa dice cómo resolvería
cada uno, no cuál está en uso. Para saber el modelo real de un agente hay que
leer su transcript, que es exactamente lo que el hook hace ahora.

**Criterio de corte:** si la tarea es "leer N archivos y redactar un análisis
con citas", el default es **`sonnet`**, no `opus` **ni `fable`**. Si es "decidir
entre opciones en conflicto con trade-offs finos" o "verificar adversarialmente
un claim de alto riesgo", entonces `opus`. `fable` queda para lo que ninguno de
los dos resuelve — es el más caro por token de los cuatro.

> Corregido 2026-08-20: esta frase decía *«el default es `sonnet` o `fable`»* y
> se llamaba «regla de oro» —un cliché que `redaccion-tecnica-es.md` prohíbe—.
> Ofrecer `fable` como default equivalente a `sonnet` cuesta **3.3×** por token.

## El segundo eje: `effort` — y NO es simétrico con `model`

> Añadido 2026-08-20 (:ref:`h-docs-217`, tarea #38). La regla gobernaba un
> solo eje —qué modelo— cuando el cliente expone dos. El segundo tiene una
> asimetría que hay que conocer antes de planear una tanda.

**Dónde se puede fijar, medido en el ejecutable 2.1.236 y en este proceso:**

| Superficie | Alcance | Estado aquí |
|---|---|---|
| `CLAUDE_EFFORT` | la **sesión** entera | **`high`** — asignada en este proceso |
| `CLAUDE_CODE_EFFORT_LEVEL` | la sesión; `unset`/`auto` la anulan | sin asignar |
| **`opts.effort` de `Workflow`** | **por llamada a `agent()`** | la única vía por-agente |

**La asimetría:** el tool `Agent` **no tiene parámetro `effort`**. Su esquema
declara `description`, `isolation`, `model`, `prompt`, `run_in_background` y
`subagent_type` — nada más. Por tanto un `Agent` suelto **hereda el effort de
la sesión y no se puede cambiar**; el esfuerzo por subagente existe **sólo
dentro de un `Workflow`**, vía `opts.effort` con los cinco niveles
`low · medium · high · xhigh · max`.

Consecuencia de planificación: si una tanda necesita **esfuerzos distintos por
ítem**, el canal es `Workflow`, no una serie de `Agent`. Con `Agent` la única
palanca es `model`.

### El coste de subir el nivel NO es el mismo entre familias

Cada registro de modelo declara su `default_effort` y un `effort_cost_index`:
el coste relativo de cada nivel tomando `high` = 1. Las cuatro familias que
declaran la capacidad `effort`:

| Modelo | `default_effort` | low | medium | high | xhigh | max | rango |
|---|---|---|---|---|---|---|---|
| `claude-sonnet-5` | `high` | 0.47 | 0.74 | 1 | 2.41 | **5.59** | **11.9×** |
| `claude-opus-4-8` | `high` | 0.72 | 0.90 | 1 | 1.65 | **1.88** | 2.6× |
| `claude-opus-5` | `high` | 0.67 | 0.76 | 1 | 1.60 | **1.70** | 2.5× |
| `claude-fable-5` | `high` | 0.60 | 0.77 | 1 | 1.74 | **1.91** | 3.2× |

**Lo que esto corrige.** La intuición *«sonnet es el barato; si hace falta más,
súbele el esfuerzo»* es correcta hacia abajo —`low` en sonnet es el punto más
barato de la tabla, 0.47— y **falsa en el extremo**: llevarlo a `max` cuesta
**5.59×** su `high`, mientras que el mismo salto vale 1.70×–1.91× en las otras
tres. Un `sonnet` a `max` deja de tener el perfil de coste de su familia.

Criterio operativo que se desprende:

- **Bajar el esfuerzo rinde más en sonnet** (0.47) que en opus (0.72) o fable
  (0.60). Para etapas mecánicas dentro de un `Workflow`, `sonnet` + `low` es el
  punto más barato disponible.
- **Subir el esfuerzo rinde más en opus** — su curva es casi plana. Si el ítem
  necesita `xhigh`/`max`, el salto se paga mejor donde el índice es 1.60–1.65
  que donde es 2.41.
- **`haiku` no declara `effort`** — su arreglo de capacidades es
  `["context_management"]` y nada más. Pasarle un nivel no tiene receptor. Es
  dato para la decisión de alcance **#200**, que hoy lo excluye por el piso de
  contexto y no por su superficie.

### El registro declara seis ejes más, y tres cambian una decisión de tanda

Medido sobre los **17** registros del ejecutable 2.1.236, con el identificador
que cada uno declara. Las columnas de coste salen del `pricing` de cada uno
cruzado con la tabla de tiers (:ref:`h-docs-218`).

| Modelo | in/out $/Mtok | ventana | salida def/máx | 1M | `advisor_rank` | `default_effort` | capac. | corte |
|---|---|---|---|---|---|---|---|---|
| `claude-3-5-haiku` | 0.8 / 4 | — | 8 192 / 8 192 | — | — | — | 0 | — |
| `claude-haiku-4-5` | 1 / 5 | 200 k | 32 000 / 64 000 | — | 1 | — | 1 | feb 2025 |
| `claude-3-5-sonnet` | 3 / 15 | — | 8 192 / 8 192 | — | — | — | 0 | — |
| `claude-3-7-sonnet` | 3 / 15 | — | 32 000 / 64 000 | — | — | — | 0 | — |
| `claude-sonnet-4-0` | 3 / 15 | 200 k | 32 000 / 64 000 | beta | — | — | 1 | ene 2025 |
| `claude-sonnet-4-5` | 3 / 15 | 200 k | 32 000 / 64 000 | beta | — | — | 1 | ene 2025 |
| `claude-sonnet-4-6` | 3 / 15 | 200 k | 32 000 / 128 000 | beta | 2 | — | 4 | ago 2025 |
| **`claude-sonnet-5`** | **3 / 15** | **1 M** | **64 000 / 128 000** | **nativa** | **3** | `high` | **6** | ene 2026 |
| `claude-opus-4-0` | **15 / 75** | 200 k | 32 000 / 32 000 | — | — | — | 1 | ene 2025 |
| `claude-opus-4-1` | **15 / 75** | 200 k | 32 000 / 32 000 | — | — | — | 1 | ene 2025 |
| `claude-opus-4-5` | 5 / 25 | 200 k | 32 000 / 64 000 | — | — | — | 1 | may 2025 |
| `claude-opus-4-6` | 5 / 25 | 200 k | 64 000 / 128 000 | beta | 3 | — | 4 | may 2025 |
| `claude-opus-4-7` | 5 / 25 | 1 M | 64 000 / 128 000 | nativa | 4 | `xhigh` | 5 | ene 2026 |
| **`claude-opus-4-8`** | **5 / 25** | **1 M** | **64 000 / 128 000** | **nativa** | **4** | `high` | **8** | ene 2026 |
| **`claude-opus-5`** | **5 / 25** | **1 M** | **64 000 / 128 000** | **nativa** | **4** | `high` | **10** | may 2026 |
| **`claude-fable-5`** | **10 / 50** | **1 M** | **64 000 / 128 000** | **nativa** | **5** | `high` | **10** | ene 2026 |
| `claude-mythos-5` | 10 / 50 | 1 M | 64 000 / 128 000 | nativa | 5 | — | 0 | ene 2026 |

En negrita, los que un alias del `enum` de `model` alcanza. **`claude-mythos-5`
ya se nombra** — antes figuraba como «la quinta familia» por la discreción de
:ref:`h-docs-217`; el ejecutor lo nombró él mismo en la directiva del
2026-08-20, así que la reserva ya no protege nada. No es despachable: ningún
alias lo resuelve.

**El identificador no tiene una sola forma.** Los tres anteriores a la 4
ponen la versión delante (`claude-3-5-sonnet`) y del 4 en adelante va detrás
(`claude-sonnet-4-0`). Un patrón que asuma `claude-<familia>-<version>` es
ciego a tres de los diecisiete — por eso la columna `model` del store guarda
la cadena **verbatim** y el discriminador de «¿es un identificador?» es el
prefijo `claude-`, no una gramática de partes.

Tres columnas cambian una decisión que esta regla ya tomaba a ciegas:

- **`in/out $/Mtok` desmonta el orden de precio que se supone.**
  `claude-fable-5` cuesta **2×** lo que `claude-opus-4-8`/`claude-opus-5` por
  token, no menos: la tabla de arriba de esta regla lo llamaba *«alternativa
  económica»* y **eso es falso frente a opus**. Es barato frente a
  `claude-opus-4-0`/`4-1` y frente a nada más. El orden real de precio por
  token es `claude-haiku-4-5` 1× → `claude-sonnet-5` 3× → `claude-opus-5` 5×
  → `claude-fable-5` 10×.
- **`advisor_rank` es el orden de capacidad que el propio cliente declara** —
  1 `claude-haiku-4-5`, 2–3 los sonnet, 3–4 los opus, 5 `claude-fable-5` y
  `claude-mythos-5`. Cruzado con el precio: `claude-fable-5` es a la vez el de
  mayor rango declarado **y** el más caro por token, así que la fila
  *«alternativa económica para análisis/redacción»* no se sostiene por ninguno
  de los dos ejes.
- **La ventana y la salida acotan el trabajo, no sólo el gasto.** Con el piso
  siempre-cargado en **126 029 tokens** (:ref:`h-docs-99`), una ventana de
  200 k deja ~74 k para el trabajo; una de 1 M deja ~874 k. Un agente que deba
  leer un árbol grande **no cabe** en las familias de 200 k, y eso es una
  restricción de viabilidad anterior a cualquier cálculo de coste.

Y dos precisiones que la tabla del `effort` de arriba necesita:

- **Siete modelos declaran la capacidad `effort`; sólo cuatro declaran su
  índice de coste.** opus 4.7 declara `default_effort: xhigh` y **ningún**
  `effort_cost_index`; sonnet 4.6 y opus 4.6 declaran `effort` sin índice. La
  tabla de cuatro filas de arriba está completa — no le faltan filas.
- **`context_management` es la única capacidad universal** entre los que
  declaran alguna (13 de 17). El resto —`fast_mode`, `lean_prompt`,
  `refusal_fallback`, `mid_conv_system`— se concentra en los de rango 4–5.

*Métrica:* `capabilities`, `default_effort`, `effort_cost_index`, `pricing`,
`context.window`, `max_output_tokens`, `advisor_rank` y `knowledge_cutoff`
declarados en los 17 registros del ejecutable 2.1.236, más las variables
presentes en el entorno de este proceso.
*Ciega a:* el precio **efectivo** bajo contrato o plan — la tabla de tiers es la
de lista, y no consta que el gasto de esta sesión se facture con ella. Y ciega a
toda capacidad que el cliente resuelva por identificador en vez de por arreglo
(`adaptive_thinking` tiene una rama así). Cruzar el índice de esfuerzo con el
precio por token sigue siendo la tarea **#286**.

**Se re-mide, no se cita de memoria** — la tabla cambia entre builds. El
recorrido **se delimita por registro**, nunca con un `.{0,N}?` no codicioso: un
N distinto captura un registro distinto, y ése fue el instrumento que publicó un
`tier_15_75` sin modelos en :ref:`h-docs-218`.

```bash
B=$(readlink -f "$(command -v claude)"); strings -n 4 "$B" > /tmp/cc.txt
python3 - <<'PY'
import re
t = open('/tmp/cc.txt', errors='ignore').read()
ini = [m.start() for m in re.finditer(r'\{id:"claude-[a-z0-9-]+",family:"', t)] + [len(t)]
for a, b in zip(ini, ini[1:]):
    seg = t[a:b][:4000]
    g = lambda p, d='—': (re.search(p, seg).group(1) if re.search(p, seg) else d)
    print(g(r'\{id:"(claude-[a-z0-9-]+)"'), g(r'pricing:"([a-z0-9_]+)"'),
          g(r'context:\{window:([0-9e.]+)'), g(r'advisor_rank:(\d+)'),
          g(r'default_effort:"([a-z]+)"'), g(r'effort_cost_index:\{([^}]*)\}'))
PY
echo "${CLAUDE_EFFORT:-(sin asignar)}"   # el nivel de la sesión
```

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

## Caveat de disponibilidad — `claude-fable-5`

`claude-fable-5` **está disponible por ahora** (directiva ejecutor 2026-07-05) y
puede usarse. Sin embargo, **de forma intermitente el harness puede
indicar que `claude-fable-5` no está disponible**. Manejo:

1. Intentar `model: "fable"` cuando aplique.
2. Si el harness reporta que no está disponible → **degradar** a `sonnet`.
   No bloquear el trabajo por la indisponibilidad de un modelo. (Decía
   *«o `haiku` si la tarea es mecánica»*; se retira — `claude-haiku-4-5` no
   arranca con el piso de contexto de esta sesión, ver #200.)
3. No afirmar «`claude-fable-5` no está disponible» de memoria — es un hecho de
   estado del entorno; derivarlo de la respuesta real del harness
   (`react-verification-gate.md`).

## Tandas paralelas — mezclar modelos

En una tanda de N agentes independientes (Clausula 6 de
`principio-rector-rup-arquitectura.md`), asignar el modelo por agente:

```python
# Ejemplo: 6 análisis documentales independientes
Agent(description="análisis d-1 ...", model="sonnet", ...)
Agent(description="análisis d-2 ...", model="sonnet", ...)
Agent(description="análisis d-3 ...", model="opus",   ...)   # el más denso
Agent(description="análisis d-4 ...", model="sonnet", ...)   # inventario/tabla
Agent(description="análisis d-5 ...", model="sonnet", ...)
Agent(description="análisis d-6 ...", model="sonnet", ...)
# fable sólo si el ítem lo justifica: cuesta 2x opus y 3.3x sonnet por token.
```

> Corregido 2026-08-20: el ejemplo repartía dos ítems a `fable` **para abaratar**
> —cuando es el más caro— y uno a `haiku`, que hoy **no arranca** con el piso de
> contexto de esta sesión (#200). Un ejemplo que contradice a su propia tabla
> enseña la conducta equivocada, que es el modo de fallo que
> `react-verification-gate.md` §1-bis ya registró para los ejemplos negativos.

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
- El **identificador del modelo** se rige por una frontera, no por una lista de
  sitios: **prohibido en lo que se lee como autoría del cambio; obligatorio en
  lo que se mide.**

  **PROHIBIDO — el cuerpo y el título de un PR, y sólo ahí.** Un PR es la
  superficie que se lee como autoría del cambio ante quien revisa; el
  identificador no informa nada de la revisión y se lee como firma.

  **SE CITA, Y COMPLETO, EN TODO LO DEMÁS** — mensajes de commit, comentarios
  de código, docstrings, la columna `model` de `agent_sessions`, las tablas de
  telemetría de `source/**`, un hallazgo que publique un cruce por modelo.
  Verbatim: `claude-sonnet-5`, `claude-opus-4-8`, `claude-opus-5`,
  `claude-haiku-4-5`, `claude-mythos-5`. Sin la versión, #286 no puede ponderar
  el gasto —opus 4.0/4.1 facturan 15/75 y de 4.5 en adelante 5/25, un factor de
  3— y **el alias no la determina** (:ref:`h-docs-220`): el mismo `sonnet`
  resuelve a 4-5 o a 5 según el proveedor, con ventanas de 200 k y 1 M
  respectivamente.

  > **Historia de esta frontera, en un día.** El 2026-08-20 se abrió como
  > excepción para la columna `model` de `agent_sessions`. Al medir que **12
  > archivos `.rst` de `source/`** ya citaban el identificador completo —todos
  > en tablas de medición— el ejecutor la amplió: *"está bien que citen el ID
  > completo; lo que sí sigue prohibido es el cuerpo de un PR"*. Una primera
  > redacción conservó commits y comentarios en la prohibición por analogía con
  > el PR; el ejecutor lo corrigió en el mismo turno —*"quítalos también, sólo
  > el PR queda prohibido"*—. La regla queda como criterio y no como lista,
  > que es lo que sobrevive a un sitio nuevo.
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
- `react-verification-gate.md`: la disponibilidad de `claude-fable-5` es un hecho
  de estado — no se afirma de memoria.
- `calibration-verified-numbers.md` / `auto-audit-before-writing.md`:
  aplican por igual a cualquier modelo de subagente.
