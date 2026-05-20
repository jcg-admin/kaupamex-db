-- =============================================================================
-- flow-guest-checkout.sql — Mapeo de tablas, flujo A
--
-- Caso: usuario ANONIMO compra como INVITADO (sin registrar cuenta).
-- La orden final queda con orders_order.user IS NULL y
-- orders_order.guest_email poblado con el email de contacto del comprador.
--
-- Cobertura UC:
--   UC-CAT-01/02   Ver catalogo y detalle de producto
--   UC-CART-01..06 Carrito anonimo (cart_token)
--   UC-ORD-01      Crear orden
--   UC-PAY-01/02   Mercadopago / PayPal
--
-- Solo SELECT y SHOW. NO modifica datos.
-- =============================================================================

-- Paso 1 — usuario anonimo navega el catalogo (READ only)
-- -----------------------------------------------------------------------------
-- Tablas tocadas: catalogue_category, catalogue_product, catalogue_product_image
-- Operaciones: SELECT
SHOW CREATE TABLE catalogue_category;
SHOW CREATE TABLE catalogue_product;
SHOW CREATE TABLE catalogue_product_image;

-- Paso 2 — agregar al carrito (INSERT anonimo con cart_token)
-- -----------------------------------------------------------------------------
-- El cliente arranca sin user (Cart.user = NULL).
-- Backend genera cart_token UUID y lo devuelve en el header
-- X-Cart-Token; el frontend lo persiste en localStorage hasta el
-- checkout.
-- Tablas: cart_cart, cart_cart_item
-- Operaciones: INSERT INTO cart_cart (id, user=NULL, cart_token=<uuid>)
--              INSERT INTO cart_cart_item (cart_id, variant_id, qty)
SHOW CREATE TABLE cart_cart;
SHOW CREATE TABLE cart_cart_item;

-- (Opcional) aplica cupon de descuento — UC-CART-04
-- -----------------------------------------------------------------------------
-- Tablas: voucher_voucher
-- Operaciones: SELECT (validar codigo) + UPDATE cart_cart.voucher_id
SHOW CREATE TABLE voucher_voucher;

-- Paso 3 — checkout, crear orden (INSERT con user=NULL, guest_email!=NULL)
-- -----------------------------------------------------------------------------
-- orders_order.user es FK nullable (api/practicayoruba/apps/orders/models.py:41-42).
-- guest_email captura el email para enviar confirmacion sin crear cuenta.
-- Tablas: orders_order, orders_order_item, orders_order_value,
--         orders_order_address, orders_status_log
SHOW CREATE TABLE orders_order;
SHOW CREATE TABLE orders_order_item;
SHOW CREATE TABLE orders_order_value;
SHOW CREATE TABLE orders_order_address;
SHOW CREATE TABLE orders_status_log;

-- Paso 4 — pago (INSERT payment + gateway events)
-- -----------------------------------------------------------------------------
-- Tablas: payments_payment, payments_gateway_event
-- (payments_refund se involucra solo si hay reembolso posterior)
SHOW CREATE TABLE payments_payment;
SHOW CREATE TABLE payments_gateway_event;

-- Paso 5 — decremento de stock e inventario (UPDATE / INSERT log)
-- -----------------------------------------------------------------------------
-- UC-INV-02. Tablas tocadas en este flujo:
--   inventory_stock     (UPDATE: quantity -= qty)
--   inventory_movement  (INSERT: tipo='sale', order_id=...)
-- Si tu instancia no tiene esos nombres exactos, ajustar
-- segun apps/inventory/models.py.
SELECT TABLE_NAME, TABLE_ROWS
  FROM information_schema.TABLES
 WHERE TABLE_SCHEMA = DATABASE()
   AND TABLE_NAME   LIKE 'inventory_%'
 ORDER BY TABLE_NAME;

-- =============================================================================
-- Reporte de FKs entre las tablas del flujo
-- =============================================================================
SELECT TABLE_NAME, COLUMN_NAME, CONSTRAINT_NAME,
       REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
  FROM information_schema.KEY_COLUMN_USAGE
 WHERE TABLE_SCHEMA           = DATABASE()
   AND REFERENCED_TABLE_NAME IS NOT NULL
   AND TABLE_NAME IN (
       'cart_cart','cart_cart_item',
       'orders_order','orders_order_item','orders_order_value',
       'orders_order_address','orders_status_log',
       'payments_payment','payments_gateway_event'
   )
 ORDER BY TABLE_NAME, COLUMN_NAME;

-- =============================================================================
-- Resumen de filas activas por tabla (sanity check)
-- =============================================================================
SELECT 'cart_cart anonimas'           AS metrica, COUNT(*) AS valor FROM cart_cart WHERE user_id IS NULL
UNION ALL SELECT 'cart_cart con user', COUNT(*) FROM cart_cart WHERE user_id IS NOT NULL
UNION ALL SELECT 'cart_cart_item',     COUNT(*) FROM cart_cart_item
UNION ALL SELECT 'orders guest',       COUNT(*) FROM orders_order WHERE user_id IS NULL AND guest_email IS NOT NULL
UNION ALL SELECT 'orders registrados', COUNT(*) FROM orders_order WHERE user_id IS NOT NULL
UNION ALL SELECT 'payments',           COUNT(*) FROM payments_payment;
