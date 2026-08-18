# Identificadores en inglés — cheat-sheet (canónico en docs)

Regla completa: `docs/.claude/rules/identificadores-en-ingles.md`. Invariante:

**Todo identificador va en inglés** —clases, funciones, métodos, argumentos,
variables, nombres de test y de archivo—; **docstrings y comentarios van en
español**.

**Traducir NO es rebautizar.** El trabajo es traducir la palabra, no buscarle un
sinónimo mejor: `_Modelo` → `_Model` (no `_Probe`), y `_Base` **se queda
`_Base`** porque ya estaba en inglés. Si la palabra ya está en inglés, no se
toca — la regla ataca el español, no la falta de imaginación.

**Gate:** `api: scripts/check_identifier_language.py`, cableado como gate 4 del
`.githooks/pre-commit` sobre los `.py` en staging. Decide por morfología
exclusiva (`-ción`, `-dad`, `-mente`, `-ando`, `-ador`…) y por partículas
(`el`, `del`, `que`, `con`, `por`, `de`, `en`…) en identificadores de 2+
palabras. Cota inferior declarada: ciego a palabras que existen en ambos
idiomas.

**Deuda heredada congelada**, no barrida: 1140 identificadores en 1652 archivos,
en `scripts/identifier_language_baseline.txt`. Uno listado no bloquea; uno nuevo
sí. Se paga al tocar (barrido: tarea #147).
