-- =============================================================================
-- flow-register-activate-checkout.sql — Mapeo de tablas, flujo B
--
-- Caso: usuario ANONIMO decide registrarse, recibe email de verificacion,
-- hace click en el link, su cuenta se activa (queda con perfil disponible)
-- y luego completa una compra como usuario REGISTRADO.
--
-- Subflujos cubiertos:
--   B.1  Registro (INSERT users_user con is_active=False)
--   B.2  Generacion + envio del email de verificacion (token hash en BD;
--        el token plano viaja solo en el email).
--   B.3  Click en el link → activacion (UPDATE is_active=True, used_at=now)
--   B.4  Login + merge del carrito anonimo
--   B.5  Checkout como usuario registrado
--   B.6  (DOCUMENTADO COMO GAP) Eliminacion logica auto-iniciada: SIN
--        IMPLEMENTACION ACTUAL. Solo se incluye el contrato propuesto.
--
-- Cobertura UC (documentados en docs/source/requisitos/casos-uso/):
--   UC-AUTH-01     Registrar cuenta             (auth/, v2.0.0, Especificado)
--   UC-AUTH-10     Verificar email              (auth/, Especificado;
--                                                 cubre tambien re-envio
--                                                 via ResendVerificationView)
--   UC-AUTH-02     Iniciar sesion               (auth/, Especificado)
--   UC-CART-06     Sincronizar / merge carrito  (cart/, Especificado)
--   UC-ORD-01      Crear orden                  (orders/, Especificado)
--   UC-PAY-01/02   Mercadopago / PayPal         (payments/, Especificado)
--
-- GAPs documentales (segun mapeo del 2026-05-20):
--   * UC-AUTH-01 Alt-A "Email ya registrado" describe solo el caso
--     is_active=True (ofrece login o reset). NO documenta el subcaso
--     "email registrado pero is_active=False por auto-soft-delete -->
--     reactivar via email". Operativamente funciona porque
--     ResendVerificationView (apps/users/views.py:382) acepta cualquier
--     user inactivo, pero el UC no lo explicita.
--   * NO existe UC para "auto soft-delete" del propio usuario
--     (UC-AUTH-13/14 son admin-only). Ni hay endpoint
--     /api/v1/auth/me/deactivate/ ni item en el menu de AccountLayout.
--     Ver seccion B.6 al final de este archivo.
-- =============================================================================

-- B.1 — Registro: INSERT users_user con is_active=False
-- -----------------------------------------------------------------------------
SHOW CREATE TABLE users_user;

-- B.2 — Token de verificacion: INSERT users_email_verification_token
-- -----------------------------------------------------------------------------
-- IMPORTANTE: el token plano NUNCA se persiste. La BD guarda solo el hash
-- (CharField token_hash, unique).  El plano viaja en el email vía
-- Django send_mail() — paso transient sin tabla.
--
--   send_verification_email(user, plain_token):
--     verify_url = f'{FRONTEND_URL}/auth/verify-email/{plain_token}'
--     send_mail(...)
SHOW CREATE TABLE users_email_verification_token;

-- B.2bis — Envio del email (TRANSIENT, NO HAY TABLA)
-- -----------------------------------------------------------------------------
-- send_mail() llama al SMTP configurado en settings.EMAIL_BACKEND y
-- NO persiste el envio en BD por defecto. Si se quiere log de envios,
-- existe notifications_notification pero no es obligatorio del flujo de
-- verificacion: el contrato del UC-AUTH-10 solo requiere que el link
-- llegue al inbox.
--
-- Tabla opcional (no obligatoria del flujo):
SHOW CREATE TABLE notifications_notification;

-- B.2ter — Re-registro de una cuenta previamente inactiva
-- -----------------------------------------------------------------------------
-- Activador: visitante (anonimo o autenticado-pero-deslogueado) intenta
-- registrarse usando un email que ya esta en users_user.
--
-- Escenarios (semantica overloaded de users_user.is_active):
--   E1) is_active=True   → cuenta activa → mostrar mensaje "ya estas
--       registrado" y ofrecer UC-AUTH-02 login / UC-AUTH-09 reset.
--       (UC-AUTH-01.Alt-A actual cubre solo este caso.)
--   E2) is_active=False y nunca verificado → re-enviar email
--       (UC-AUTH-10 + apps/users/views.py:382 ResendVerificationView).
--   E3) is_active=False por suspension de admin (UC-AUTH-13) →
--       NO debe permitirse reactivacion via email; el admin tiene que
--       invocar UC-AUTH-14. Falta diferenciar el motivo en la BD.
--   E4) is_active=False por auto-soft-delete (futuro) → reactivar via
--       email se considera valido. Mismo flujo que E2 operativamente.
--
-- Gap a resolver: el campo users_user.is_active no distingue entre E2,
-- E3 y E4. Propuesta — agregar:
--   ALTER TABLE users_user
--     ADD COLUMN deactivated_reason ENUM('unverified','suspended','self_deleted')
--                                   NULL,
--     ADD COLUMN deactivated_at     DATETIME NULL;
--
-- Operacion en BD para E2/E4 (re-registro reactiva):
--   - SELECT users_user WHERE email=<x> AND is_active=False
--     AND deactivated_reason IN ('unverified','self_deleted');
--   - INSERT users_email_verification_token (nuevo token)
--   - send_mail() — transient
--   - (click) UPDATE users_email_verification_token SET used_at=NOW()
--   - UPDATE users_user
--        SET is_active=True,
--            deactivated_reason=NULL,
--            deactivated_at=NULL
--      WHERE id=<user.id>
SELECT 'B.2ter contrato propuesto — NO hay schema change aplicado todavia'
       AS nota;

-- B.3 — Click en el link → activacion
-- -----------------------------------------------------------------------------
-- POST /api/v1/auth/verify-email/{token}/  → validate_verification_token()
-- Operaciones:
--   UPDATE users_email_verification_token SET used_at = NOW() WHERE token_hash = sha256(<plain>)
--   UPDATE users_user SET is_active = True WHERE id = <token.user_id>
--
-- Idempotencia: si is_active ya es True, el endpoint devuelve 200 sin
-- side-effects (idempotente segun el docstring del modelo).
--
-- ACTIVACION = PERFIL DISPONIBLE
--   No existe una tabla 'users_profile' separada. El perfil del usuario
--   son los campos de users_user mismo: first_name, last_name, email,
--   phone, date_joined, is_active. La UI los muestra en
--   ui/src/pages/account/ProfilePage.jsx leyendo de selectUser (Redux).

-- B.4 — Login y merge del carrito anonimo
-- -----------------------------------------------------------------------------
-- POST /api/v1/auth/login/        → crea JWT en cookies httpOnly
-- POST /api/v1/cart/merge/        → cart_token (header) + user (jwt)
--                                   funde el carrito anonimo con el del user.
--
-- Operaciones en cart_cart:
--   SELECT existing user-cart por user_id.
--   SELECT anonymous cart por cart_token (validar user IS NULL).
--   Si ambos existen: cart.merge(otro_cart) consolida items.
--   UPDATE cart_cart SET user_id = <user>, cart_token = NULL.
--
-- Ver apps/cart/views.py:_get_or_create_cart y CartMergeView.
-- (Tabla cart_cart ya documentada en flow-guest-checkout.sql; se incluye
-- aqui de nuevo por completitud del flujo B.)
SHOW CREATE TABLE cart_cart;

-- B.5 — Checkout como usuario registrado
-- -----------------------------------------------------------------------------
-- Diferencias vs flujo guest:
--   - orders_order.user IS NOT NULL
--   - orders_order.guest_email puede ir NULL (se usa user.email)
--   - users_address: si el usuario reusa una direccion guardada, se
--     copia a orders_order_address (snapshot, no FK al users_address).
SHOW CREATE TABLE users_address;
SHOW CREATE TABLE orders_order;
SHOW CREATE TABLE orders_order_item;
SHOW CREATE TABLE orders_order_value;
SHOW CREATE TABLE orders_order_address;
SHOW CREATE TABLE orders_status_log;
SHOW CREATE TABLE payments_payment;

-- =============================================================================
-- B.6 — Eliminacion logica auto-iniciada por el usuario (GAP — NO IMPLEMENTADO)
-- =============================================================================
-- Estado actual del codigo (2026-05-20):
--
-- UI:
--   ui/src/layouts/AccountLayout.jsx NAV_ITEMS no contiene una entrada
--   "Dar de baja" / "Eliminar mi cuenta". El menu tiene 8 items:
--     Resumen, Mis pedidos, Mis favoritos, Mis devoluciones, Soporte,
--     Notificaciones, Mi perfil, Cambiar contrasena.
--
-- API:
--   api/practicayoruba/apps/users/views.py NO tiene endpoint
--   self-destroy/self-deactivate para /api/v1/auth/me/.
--
--   Lo unico relacionado es el admin-flow:
--     POST /api/v1/admin/users/{pk}/suspend/    UC-AUTH-13
--     POST /api/v1/admin/users/{pk}/reactivate/ UC-AUTH-14
--   Que cambian users_user.is_active de True ↔ False. Pero solo admin
--   puede invocarlos.
--
-- Mecanismo de eliminacion logica:
--   Reusa el campo users_user.is_active (BooleanField).
--   No existe deleted_at ni is_self_deleted ni separacion semantica
--   entre "no verificado", "suspendido por admin" y "auto-eliminado".
--
-- Contrato propuesto (cuando se implemente esta funcionalidad):
--   Endpoint:  POST /api/v1/auth/me/deactivate/   (autenticado)
--   Operaciones:
--     UPDATE users_user
--        SET is_active = False
--      WHERE id = <request.user.id>
--     Opcional: agregar deactivated_at, deactivated_reason si se quiere
--     auditar el origen (auto vs admin).
--   Side effects sugeridos:
--     - Invalidar refresh tokens (blacklist).
--     - Anonimizar datos personales (PII) si la regulacion lo exige
--       (GDPR-art-17 equivalente local). Esto SI requiere UPDATE de
--       campos no-clave de users_user (email, first_name, etc.) y
--       posiblemente users_address.
--     - Los datos transaccionales (orders_order) NO se anonimizan: son
--       evidencia fiscal/contable.
--
-- Las tablas tocadas en el contrato propuesto son:
--   users_user                              (UPDATE is_active=False)
--   users_email_verification_token          (DELETE / mark expired)
--   users_password_reset_token              (DELETE)
--   cart_cart                               (DELETE o UPDATE user_id=NULL)
--   cart_saved_cart                         (DELETE)
--   users_address                           (UPDATE PII si aplica)

-- =============================================================================
-- Reporte de FKs entre las tablas del flujo B
-- =============================================================================
SELECT TABLE_NAME, COLUMN_NAME, CONSTRAINT_NAME,
       REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
  FROM information_schema.KEY_COLUMN_USAGE
 WHERE TABLE_SCHEMA           = DATABASE()
   AND REFERENCED_TABLE_NAME IS NOT NULL
   AND TABLE_NAME IN (
       'users_user','users_email_verification_token','users_address',
       'cart_cart','cart_cart_item',
       'orders_order','orders_order_item','orders_order_value',
       'orders_order_address','orders_status_log',
       'payments_payment'
   )
 ORDER BY TABLE_NAME, COLUMN_NAME;

-- =============================================================================
-- Sanity-check de estado de cuentas
-- =============================================================================
SELECT 'users total'              AS metrica, COUNT(*) AS valor FROM users_user
UNION ALL SELECT 'users activos',       COUNT(*) FROM users_user WHERE is_active = 1
UNION ALL SELECT 'users inactivos',     COUNT(*) FROM users_user WHERE is_active = 0
UNION ALL SELECT 'tokens email pendientes',
                                       COUNT(*) FROM users_email_verification_token WHERE used_at IS NULL
UNION ALL SELECT 'tokens email usados',
                                       COUNT(*) FROM users_email_verification_token WHERE used_at IS NOT NULL
UNION ALL SELECT 'direcciones guardadas',
                                       COUNT(*) FROM users_address;
