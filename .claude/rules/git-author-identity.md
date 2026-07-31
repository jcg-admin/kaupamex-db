# Git Author Identity

Creado: 2026-06-20T07:57:20
Actualizado: 2026-07-04 (committer → jcg-admin, nunca Claude — directiva ejecutor)

## Identidades correctas

| Campo      | Valor                                              | Cómo se fija           |
|------------|----------------------------------------------------|------------------------|
| Author     | `Nestor Monroy <46802445+NestorMonroy@users.noreply.github.com>` | `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` |
| Committer  | `jcg-admin <169318663+jcg-admin@users.noreply.github.com>`       | `git config user.name/email`           |

El entorno remoto de Claude Code fija automáticamente las variables
`GIT_AUTHOR_NAME` y `GIT_AUTHOR_EMAIL` para preservar la identidad del
usuario humano (autor). No sobreescribir esas variables ni forzar un autor
distinto en ningún commit o amend.

**El committer se fija con `git config user.name/user.email` a `jcg-admin`**
(no al valor por defecto del entorno). Aplica a **todos** los repos
(api, ui, docs, db) por igual.

## Prohibición absoluta — el committer NUNCA es Claude

`Claude <noreply@anthropic.com>` **no debe aparecer como committer** en
ningún commit. Antes de commitear, `git config user.email` debe ser
`169318663+jcg-admin@users.noreply.github.com`.

```bash
# Fijar la identidad correcta en el repo (una vez por clon):
git config user.name  "jcg-admin"
git config user.email "169318663+jcg-admin@users.noreply.github.com"
```

```bash
# NUNCA — reset-author iguala author = committer (pierde al autor humano)
git commit --amend --no-edit --reset-author

# NUNCA — pone al agente como autor o committer
git commit --amend --no-edit --author="Claude <noreply@anthropic.com>"
GIT_AUTHOR_EMAIL="noreply@anthropic.com" git commit ...

# NUNCA — dejar el committer en Claude
#   (si git config user.email = noreply@anthropic.com → corregir ANTES de commitear)
```

## Fix correcto al enmendar un commit

Preservar el autor humano explícitamente; el committer sale de `git config`
(ya fijado a `jcg-admin`):

```bash
git commit --amend --no-edit \
  --author="Nestor Monroy <46802445+NestorMonroy@users.noreply.github.com>"
```

## Reescribir el committer de commits ya hechos (Claude → jcg-admin)

Cuando commits ya existentes tengan `committer: Claude`, reescribir **solo el
committer** (preservando autor, mensaje, árbol, fechas y estructura de merges)
con `filter-branch` sobre el rango no mergeado, y `push --force-with-lease`:

```bash
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --env-filter '
if [ "$GIT_COMMITTER_EMAIL" = "noreply@anthropic.com" ]; then
  export GIT_COMMITTER_NAME="jcg-admin"
  export GIT_COMMITTER_EMAIL="169318663+jcg-admin@users.noreply.github.com"
fi
' origin/develop..HEAD
git push --force-with-lease origin <rama>
```

`--force-with-lease` es aceptable en ramas `feature/*` y `claude/*` (nunca
en `develop`/`main`). Solo cambia el committer donde era Claude; los commits
con committer humano (Nestor) quedan intactos.

## Respuesta al stop-hook

El hook `~/.claude/stop-hook-git-check.sh` puede sugerir `--reset-author`.
**Ignorar esa sugerencia** — `--reset-author` iguala author = committer y
borra al autor humano. La corrección válida:

1. `git config user.email` debe ser `169318663+jcg-admin@users.noreply.github.com`.
2. Enmendar con `--author="Nestor Monroy <...>"` si hace falta corregir el autor.
3. Push con `--force-with-lease` si el commit ya estaba publicado.

## Verificación

```bash
git log -1 --format="%h%n  author:    %an <%ae>%n  committer: %cn <%ce>"
```

Salida esperada:

```
<hash>
  author:    Nestor Monroy <46802445+NestorMonroy@users.noreply.github.com>
  committer: jcg-admin <169318663+jcg-admin@users.noreply.github.com>
```
