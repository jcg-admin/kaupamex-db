# scripts/mapping/ — Mapeo de tablas por flujo funcional

Este directorio contiene scripts que, contra la base
`kaupamex_db`, inspeccionan las tablas reales involucradas en
flujos funcionales claves del e-commerce. No modifica datos: solo
lee schema (`SHOW CREATE TABLE`, `INFORMATION_SCHEMA`) y conteos.

Cada script SQL incluye en comentarios:

- La cadena ordenada de operaciones del flujo (INSERT/UPDATE/SELECT).
- El caso de uso (UC-*) que dispara cada paso, cuando aplica.
- Las FKs relevantes entre tablas.

## Flujos cubiertos

### Flujo A — Compra como invitado (sin registro)

> **DEPRECADO A NIVEL UI** (a partir de `ui@e4889bd2`, 2026-05-23).
> `/checkout` y `/checkout/payment/:orderId` requieren sesión activa
> (`ProtectedRoute`). El flujo de compra como invitado ya no es
> alcanzable desde la UI (directiva: "forzamos login antes, no podemos
> comprar si no está registrado").
>
> El schema de BD (`orders_order.user IS NULL`, `guest_email`) permanece
> intacto — ninguna migración lo elimina. El SQL de este flujo conserva
> valor para inspección de schema y diagnóstico. El flujo operativo
> activo es ahora **solo Flujo B** (registro + compra autenticada).

Usuario anónimo navega el catálogo, agrega productos al carrito y
completa la compra sin crear cuenta. La orden queda con
`orders_order.user IS NULL` y `orders_order.guest_email` poblado.

Script: `flow-guest-checkout.sql`.

### Flujo B — Registro + verificación de email + compra

Usuario anónimo decide crear cuenta. Django crea el User con
`is_active=False`, genera un `EmailVerificationToken` (solo el hash
del token se persiste — el token plano se envía por email vía
`send_mail` de Django, sin persistencia adicional). El usuario hace
click en el link recibido, lo cual:

1. Marca el token como usado (`used_at`).
2. Activa la cuenta (`users_user.is_active = True`).

Solo desde ese momento el usuario tiene **perfil** funcional: puede
iniciar sesión, sus datos en `users_user` son sus campos de perfil
(no hay tabla `Profile` separada — first_name, last_name, email y
phone viven en `users_user`). Luego inicia sesión, el carrito anónimo
se mergea (endpoint `/api/v1/cart/merge/`) y completa el checkout.

Script: `flow-register-activate-checkout.sql`.

#### UCs documentados que cubren el flujo B

| Sub-paso | UC | Estado en docs |
|---|---|---|
| Registro (form + create user inactivo) | **UC-AUTH-01** | Especificado v2.0.0 |
| Envío + click + activación email | **UC-AUTH-10** | Especificado |
| Re-envío del email de verificación | UC-AUTH-10 + `ResendVerificationView` | Implementado |
| Login | UC-AUTH-02 | Especificado |
| Sincronizar / merge carrito | UC-CART-06 | Especificado |
| Crear orden | UC-ORD-01 | Especificado |
| Pago | UC-PAY-01/02 | Especificado |

#### GAPs documentales y funcionales detectados (2026-05-20)

- **GAP-1 (UC-AUTH-01.Alt-A incompleto):** la alternativa "email ya
  registrado" describe solo el caso `is_active=True` (ofrece login
  o reset). NO documenta el subcaso "email registrado pero
  `is_active=False` por auto-soft-delete → reactivar via email".
  Operativamente la cobertura existe porque `ResendVerificationView`
  acepta cualquier user inactivo, pero el UC no lo explicita.

- **GAP-2 (sin UC para auto soft-delete): RESUELTO** (2026-05-23).
  Endpoint API `me/deactivate/` implementado en `apps/users/urls.py`
  como `DeactivateAccountView` (UC-AUTH-16). Ruta `/account/deactivate`
  en `AppRouter.jsx`. Nav item "Dar de baja" en `AccountLayout.jsx`
  `NAV_ITEMS` (posición final deliberada para evitar confusión con
  opciones cotidianas). 9 items totales en el sidebar de cuenta.

- **GAP-3 (`is_active` semántico-overloaded):** el flag es una sola
  columna booleana que actualmente representa **tres causas**
  distintas — no verificado, suspendido por admin, y auto-eliminado
  (a futuro). La separación recomendada está en el script
  `flow-register-activate-checkout.sql` sección B.2ter:
  agregar `deactivated_reason` y `deactivated_at` a `users_user`.

Estos gaps deberían abrir iniciativas formales en
`docs/source/gestion/pm/{api,ui,db}/iniciativas/`.

## Uso

```bash
# Inspeccionar el flujo guest (DDL + conteos)
./inspect-flow.sh guest

# Inspeccionar el flujo registro-activacion
./inspect-flow.sh register

# Inspeccionar ambos
./inspect-flow.sh all
```

El wrapper `inspect-flow.sh` lee las variables `DB_NAME`,
`DB_USER`, `DB_HOST`, `DB_PORT` del `.env` raíz del submodulo db
(o del entorno si están exportadas) y usa `mariadb` CLI con
`--protocol=TCP`. Si la BD no existe, falla con mensaje explícito
(loud failure según DEC-DOC-008).

## Por qué SQL puro y no Python

- El submódulo `db/` no carga Django ORM (es bash + python-dotenv).
  Inspeccionar via ORM requeriía montar el entorno del api.
- `mariadb` CLI ya está provisionado y verificado (D-028).
- El output (SHOW CREATE TABLE, INFORMATION_SCHEMA queries) es
  reproducible y diff-friendly entre runs.

## Limitaciones

- Estos scripts NO simulan transacciones (no hacen INSERT real).
  Solo enumeran las tablas, sus columnas y FKs.
- Para tests de integración E2E, ver `api/tests/` y el fixture
  `mariadb_keepalive` en `api/tests/conftest.py`.
- El envío real del email (`send_mail` → SMTP) no es una tabla:
  es un side-effect transitorio. Los scripts marcan ese paso como
  un comentario "EMAIL DELIVERY (transient)" sin tabla asociada.
  Si se quiere log de envíos, `notifications_notification` puede
  registrarlo, pero el registro NO es obligatorio del flujo de
  verificación.
