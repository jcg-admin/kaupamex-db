# Hallazgo con alcance abierto genera sucesor — cheat-sheet (canónico en docs)

Regla completa: `docs/.claude/rules/hallazgo-abierto-genera-sucesor.md` — se carga en
sesiones con `docs` en scope. Aquí sólo el invariante operativo:

Todo hallazgo que declare alcance abierto —sección "Lo que este hallazgo no cierra",
"queda abierto/pendiente", o un `Estado:` que no sea RESUELTO/CORREGIDO— **registra su
sucesor en el MISMO pase**: una tarea con su ID citado en el hallazgo, una sub-iniciativa
explícita, o un DESCONOCIDO con su condición de cierre escrita. Nunca ninguna.

Y luego **se cierra**: analizar → documentar → aplicar. Sólo se difiere por decisión del
ejecutor, bloqueo real nombrado, o commit en vuelo que no debe mezclarse. "No es urgente",
"el código funciona" y "lo hago en la siguiente iniciativa" NO son bloqueos.

Origen: directiva del ejecutor 2026-08-06. Precedentes: H-API-312→#106, H-API-313→#107.
