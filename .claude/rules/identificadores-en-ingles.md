# Identificadores en inglés — cheat-sheet (canónico en docs)

Regla completa: `docs/.claude/rules/identificadores-en-ingles.md`. Invariante:

**Todo identificador va en inglés** —clases, funciones, métodos, **firmas de
función** (el nombre de cada parámetro), variables, nombres de test y **nombres
de archivo**—; **docstrings y comentarios van en español**.

> Reiterado y ampliado por el ejecutor 2026-08-28: *«en este momento ya nuestros
> archivos, clases, funciones, firmas de funciones, van a ir en inglés, los
> comentarios tienen que ir en español»*. Las **firmas** ya se medían sin
> decirlo (el recorrido AST visita `ast.arg`); el **nombre de archivo** no se
> medía en absoluto, y es el eje que se añadió.

**Traducir NO es rebautizar.** El trabajo es traducir la palabra, no buscarle un
sinónimo mejor: `_Modelo` → `_Model` (no `_Probe`), y `_Base` **se queda
`_Base`** porque ya estaba en inglés. Si la palabra ya está en inglés, no se
toca — la regla ataca el español, no la falta de imaginación.

## Dos ejes, dos gates

| Eje | Qué mide | Gate |
|---|---|---|
| **Identificador** | los símbolos declarados **dentro** del archivo, por AST | `api: scripts/check_identifier_language.py` (gate 4 del `.githooks/pre-commit` sobre los `.py` en staging) |
| **Nombre de archivo** | el *stem* del `.py` y del `.sh` | `docs: .claude/scripts/gates/check_script_naming.py --idioma` (gate de `thyrox-audit.sh`) |

El nombre de un archivo no se declara dentro del archivo: por eso hacen falta
los dos. El **separador** (snake_case en `.py`, porque el nombre *es* el módulo
que se importa) es un tercer eje, del mismo guion sin `--idioma`.

El gate de nombres **reusa** `spanish_words_in` del gate de `api` en vez de
copiar el léxico, y sin él **rehúsa con exit 2 sin emitir conteo** — un 0 ahí
sería un verde falso.

**Deuda heredada congelada**, no barrida: 1140 identificadores en 1652 archivos
(`api: scripts/identifier_language_baseline.txt`) y 38 nombres de archivo sobre
215 medidos (`docs: .claude/scripts/gates/script_naming_language_baseline.txt`).
Uno listado no bloquea; uno nuevo sí. Se paga al tocar (barrido: tarea #147).
