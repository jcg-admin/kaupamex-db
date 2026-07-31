-- =============================================================================
-- seed_catalogo.sql — Datos iniciales del catálogo PracticaYoruba
-- =============================================================================
-- Inserta:
--   1 fila en settings_sitesettings (singleton con valores por defecto)
--   6 categorías Yoruba en catalogue_category
--   12 productos de muestra en catalogue_product
--
-- IDEMPOTENTE: usa INSERT IGNORE — re-ejecutar no duplica ni falla.
--   - settings_sitesettings: pk=1 fijo (singleton)
--   - catalogue_category:    slug UNIQUE
--   - catalogue_product:     sku UNIQUE
--
-- Prerequisito: Migraciones Django aplicadas en kaupamex_db.
--
-- Uso:
--   mysql --socket=/run/mysqld/mysqld.sock kaupamex_db < seed_catalogo.sql
-- =============================================================================

SELECT 'PROCESO INICIO' AS evento, NOW() AS timestamp_inicio FROM DUAL;

-- ─── SiteSettings (singleton) ─────────────────────────────────────────────────
-- La aplicación Django crea este registro via SiteSettings.get_or_create_defaults().
-- El seed lo inserta directamente para que las vistas y SPs que leen
-- settings_sitesettings tengan datos al momento del despliegue.

-- Valores tomados de los defaults del modelo en api
-- (src/addons/base/models/res_config_settings.py). Las columnas
-- avatar_max_size_mb y max_addresses_per_user ya no existen en el
-- schema; las de referral/contacto son NOT NULL sin DEFAULT en SQL
-- puro (el default de Django solo aplica via ORM), asi que el seed
-- debe darlas explicitamente.

INSERT IGNORE INTO settings_sitesettings
    (id, site_name, iva_rate, currency,
     payment_timeout_minutes, order_timeout_minutes, max_return_days,
     free_shipping_threshold, min_stock_threshold,
     referral_active, referral_welcome_discount, referral_reward_discount,
     support_email, phone, address, social_links,
     created_at, updated_at)
VALUES
    (1, 'PracticaYoruba', 0.1600, 'MXN',
     30, 30, 30,
     500.00, 5,
     0, 50.00, 50.00,
     '', '', '', '{}',
     NOW(6), NOW(6));

-- ─── Categorías ───────────────────────────────────────────────────────────────
-- 6 categorías de productos Yoruba. parent_id=NULL (categorías raíz).
-- INSERT IGNORE: si el slug ya existe, no hace nada.

-- created_at/updated_at y order son NOT NULL sin DEFAULT en SQL puro:
-- el default del modelo (order=0) solo aplica via ORM. order=0 en todas
-- deja el ordenamiento efectivo por nombre (Meta.ordering = ['order', 'name']).

INSERT IGNORE INTO catalogue_category
    (name, slug, description, is_active, parent_id,
     created_at, updated_at, `order`)
VALUES
    ('Collares y Elekes',
     'collares-y-elekes',
     'Collares de cuentas (elekes) consagrados para cada Orisha. '
     'Usados como protección espiritual y como marca de iniciación.',
     1, NULL, NOW(6), NOW(6), 0),

    ('Soperas y Receptáculos',
     'soperas-y-receptaculos',
     'Soperas, cazuelas y otanes para guardar las fundamentos de los Orishas. '
     'Fabricados en cerámica, madera y metal según el Orisha.',
     1, NULL, NOW(6), NOW(6), 0),

    ('Herramientas y Atributos',
     'herramientas-y-atributos',
     'Atributos sagrados propios de cada Orisha: espadas, orishas, coronas, '
     'abanicos, cuernos y demás implementos rituales.',
     1, NULL, NOW(6), NOW(6), 0),

    ('Libros y Aprendizaje',
     'libros-y-aprendizaje',
     'Textos de referencia sobre la Regla de Ocha, Ifá, Palo Monte y '
     'tradiciones afrocubanas. Para estudiantes y practicantes.',
     1, NULL, NOW(6), NOW(6), 0),

    ('Ropa y Vestimenta',
     'ropa-y-vestimenta',
     'Ropa ritual para ceremonias, iniciaciones y ebós. '
     'Colores y telas asociados a cada Orisha.',
     1, NULL, NOW(6), NOW(6), 0),

    ('Incienso y Limpiezas',
     'incienso-y-limpiezas',
     'Plantas medicinales, resinas, omiero, sahumadores y todo lo necesario '
     'para limpiezas espirituales y purificaciones.',
     1, NULL, NOW(6), NOW(6), 0);

-- ─── Productos de muestra ─────────────────────────────────────────────────────
-- 12 productos con variedad de estados:
--   - Publicados y activos (visible en v_published_catalog)
--   - Destacados (visible en v_featured_products)
--   - Stock bajo el umbral (visible en v_low_stock y sp_rpt_low_stock)
--   - Agotados (stock=0)
--   - No publicados (en proceso, no visibles al público)
--
-- Las fechas created_at/updated_at no tienen DEFAULT en la tabla —
-- deben especificarse explícitamente en INSERT (no son auto_now en SQL puro).

-- UC-CAT-13: catalogue_product ya no tiene category_id (M2M).
-- Paso 1 — insertar productos sin categoría.
-- is_deleted viene del SoftDeleteMixin (default False via ORM); en SQL
-- puro es NOT NULL sin DEFAULT, asi que se da explicitamente como 0.
INSERT IGNORE INTO catalogue_product
    (name, slug, sku, short_description, description,
     price, stock,
     is_featured, is_active, is_published, is_deleted,
     created_at, updated_at)
SELECT
    p.name, p.slug, p.sku, p.short_desc, p.desc_larga,
    p.price, p.stock,
    p.is_featured, p.is_active, p.is_published, 0,
    NOW(6), NOW(6)
FROM (
    -- ── Collares y Elekes ────────────────────────────────────────────────
    SELECT 'Eleke de Yemaya — Collar de Mar'                   AS name
         , 'eleke-yemaya-collar-mar'                           AS slug
         , 'ELK-YEM-001'                                       AS sku
         , 'Collar consagrado de 21 cuentas azul y cristal'    AS short_desc
         , 'Eleke consagrado representativo de Yemaya, '
           'patrona de los mares. 21 cuentas de color azul '
           'intercaladas con cristal. Largo: 60 cm.'           AS desc_larga
         , 'collares-y-elekes'                                 AS cat_slug
         , 450.00                                              AS price
         , 15                                                  AS stock
         , 1                                                   AS is_featured
         , 1                                                   AS is_active
         , 1                                                   AS is_published
    UNION ALL
    SELECT 'Eleke de Oshun — Collar de Río'
         , 'eleke-oshun-collar-rio'
         , 'ELK-OSH-001'
         , 'Collar consagrado de 21 cuentas amarillo y ámbar'
         , 'Eleke consagrado de Oshun, orisha del río y el amor. '
           '21 cuentas amarillas y ámbar. Largo: 60 cm.'
         , 'collares-y-elekes'
         , 420.00, 8, 1, 1, 1
    UNION ALL
    SELECT 'Eleke de Elegua — Collar de Caminos'
         , 'eleke-elegua-collar-caminos'
         , 'ELK-ELE-001'
         , 'Collar consagrado de 21 cuentas rojo y negro'
         , 'Eleke consagrado de Elegua, dueño de los caminos. '
           '21 cuentas rojo y negro. Largo: 60 cm.'
         , 'collares-y-elekes'
         , 380.00, 0, 0, 1, 1    -- AGOTADO
    UNION ALL
    -- ── Soperas y Receptáculos ───────────────────────────────────────────
    SELECT 'Sopera de Yemaya — Cerámica Azul'
         , 'sopera-yemaya-ceramica-azul'
         , 'SOP-YEM-001'
         , 'Sopera artesanal de cerámica pintada a mano, 30 cm'
         , 'Sopera para los fundamentos de Yemaya. Cerámica de alta '
           'temperatura pintada a mano en azul y blanco. Capacidad: 4 L.'
         , 'soperas-y-receptaculos'
         , 1200.00, 5, 1, 1, 1   -- DISPONIBLE (stock=5=umbral, es DISPONIBLE)
    UNION ALL
    SELECT 'Caldero de Oggun — Hierro Forjado'
         , 'caldero-oggun-hierro-forjado'
         , 'CAL-OGG-001'
         , 'Caldero de hierro con herramientas de Oggun'
         , 'Caldero de hierro forjado a mano con las 7 herramientas '
           'de Oggun. Incluye: machete, pala, pico, martillo, '
           'gancho, yunque y cadena. Peso: 3.5 kg.'
         , 'soperas-y-receptaculos'
         , 2800.00, 3, 0, 1, 1   -- BAJO_STOCK (stock=3 < umbral=5)
    UNION ALL
    SELECT 'Otán de Shango — Piedra del Trueno'
         , 'otan-shango-piedra-trueno'
         , 'OTN-SHA-001'
         , 'Otán consagrado de Shango, piedra del trueno'
         , 'Otán (piedra sagrada) consagrado a Shango. '
           'Piedra natural con patrones únicos. Incluye ashe.'
         , 'soperas-y-receptaculos'
         , 950.00, 2, 0, 1, 0    -- No publicado aún (en proceso)
    UNION ALL
    -- ── Herramientas y Atributos ─────────────────────────────────────────
    SELECT 'Oshe de Shango — Hacha Doble'
         , 'oshe-shango-hacha-doble'
         , 'HER-SHA-001'
         , 'Hacha doble de Shango en madera tallada y pintada'
         , 'Oshe (hacha doble) atributo fundamental de Shango. '
           'Madera de cedro tallada a mano, pintada en rojo y blanco. '
           'Alto: 45 cm.'
         , 'herramientas-y-atributos'
         , 750.00, 12, 1, 1, 1
    UNION ALL
    SELECT 'Corona de Obatala — Metal Plateado'
         , 'corona-obatala-metal-plateado'
         , 'HER-OBA-001'
         , 'Corona de Obatala con 8 colgantes en metal plateado'
         , 'Corona atributo de Obatala. Metal plateado con 8 colgantes '
           'de campanas. Diámetro: 18 cm.'
         , 'herramientas-y-atributos'
         , 1100.00, 4, 0, 1, 1   -- BAJO_STOCK (stock=4 < umbral=5)
    UNION ALL
    -- ── Libros y Aprendizaje ─────────────────────────────────────────────
    SELECT 'El Monte — Lydia Cabrera (Edición Especial)'
         , 'el-monte-lydia-cabrera-edicion-especial'
         , 'LIB-MON-001'
         , 'Obra fundamental de la religión yoruba en Cuba'
         , 'Edición especial de "El Monte" de Lydia Cabrera. '
           'Referencia indispensable sobre plantas sagradas, '
           'rituales y tradición oral afrocubana. 568 págs.'
         , 'libros-y-aprendizaje'
         , 680.00, 20, 0, 1, 1
    UNION ALL
    SELECT 'Ifa: La Sabiduría del Oráculo'
         , 'ifa-sabiduria-oraculo'
         , 'LIB-IFA-001'
         , 'Introducción a los fundamentos de Ifá para principiantes'
         , 'Texto introductorio al sistema adivinatorio de Ifá. '
           'Cubre los 16 Odu principales con sus historias y enseñanzas. '
           '320 págs. Incluye ilustraciones.'
         , 'libros-y-aprendizaje'
         , 450.00, 1, 0, 1, 1    -- BAJO_STOCK (stock=1 < umbral=5)
    UNION ALL
    -- ── Incienso y Limpiezas ─────────────────────────────────────────────
    SELECT 'Kit Omiero de Yemaya — 7 plantas'
         , 'kit-omiero-yemaya-7-plantas'
         , 'INC-OMI-001'
         , 'Kit con 7 plantas sagradas de Yemaya para limpieza'
         , 'Kit para preparación de omiero de Yemaya. Incluye: '
           'lechuga, verdolaga, acelga, berro, malanga, rompezarague y '
           'mastuerzo. Plantas frescas empacadas al vacío.'
         , 'incienso-y-limpiezas'
         , 280.00, 8, 0, 1, 1
    UNION ALL
    SELECT 'Sahumador de Mirra y Copal — 500g'
         , 'sahumador-mirra-copal-500g'
         , 'INC-SAH-001'
         , 'Mezcla artesanal de mirra y copal para purificaciones'
         , 'Resinas naturales de mirra y copal para quemar en carbón. '
           'Purificación de espacios y personas antes de rituales. '
           'Presentación: 500g en frasco de vidrio.'
         , 'incienso-y-limpiezas'
         , 195.00, 0, 0, 1, 1    -- AGOTADO
) p;

-- UC-CAT-13 Paso 2 — asignar categorías vía tabla join M2M.
-- INSERT IGNORE garantiza idempotencia.
INSERT IGNORE INTO catalogue_product_categories (product_id, category_id)
SELECT prod.id, cat.id
FROM (
    SELECT 'ELK-YEM-001' AS sku, 'collares-y-elekes'       AS cat_slug UNION ALL
    SELECT 'ELK-OSH-001',        'collares-y-elekes'        UNION ALL
    SELECT 'ELK-ELE-001',        'collares-y-elekes'        UNION ALL
    SELECT 'SOP-YEM-001',        'soperas-y-receptaculos'   UNION ALL
    SELECT 'CAL-OGG-001',        'soperas-y-receptaculos'   UNION ALL
    SELECT 'OTN-SHA-001',        'soperas-y-receptaculos'   UNION ALL
    SELECT 'HER-SHA-001',        'herramientas-y-atributos' UNION ALL
    SELECT 'HER-OBA-001',        'herramientas-y-atributos' UNION ALL
    SELECT 'LIB-MON-001',        'libros-y-aprendizaje'     UNION ALL
    SELECT 'LIB-IFA-001',        'libros-y-aprendizaje'     UNION ALL
    SELECT 'INC-OMI-001',        'incienso-y-limpiezas'     UNION ALL
    SELECT 'INC-SAH-001',        'incienso-y-limpiezas'
) lnk
JOIN catalogue_product  prod ON prod.sku      = lnk.sku
JOIN catalogue_category cat  ON cat.slug      = lnk.cat_slug;

-- ─── Resumen del seed ─────────────────────────────────────────────────────────

SELECT
    'settings_sitesettings' AS tabla,
    COUNT(*)                AS filas_insertadas
FROM settings_sitesettings
UNION ALL
SELECT 'catalogue_category', COUNT(*) FROM catalogue_category
UNION ALL
SELECT 'catalogue_product', COUNT(*) FROM catalogue_product;

-- Estado del catálogo post-seed:
SELECT
    SUM(IF(is_published=1 AND is_active=1, 1, 0))  AS publicados_activos,
    SUM(IF(is_featured=1, 1, 0))                   AS destacados,
    SUM(IF(stock=0, 1, 0))                         AS agotados,
    SUM(IF(stock>0 AND stock<5, 1, 0))             AS bajo_stock_umbral5
FROM catalogue_product;

SELECT 'PROCESO COMPLETADO' AS evento, NOW() AS timestamp_fin FROM DUAL;
