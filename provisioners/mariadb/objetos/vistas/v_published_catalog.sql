SELECT 'PROCESO INICIO' AS evento, NOW() AS timestamp_inicio FROM DUAL;

/********************************************************************************************
    Script          : v_published_catalog.sql
    Version         : 2.0.0
    Create          : MAYO/2026
    Engine          : MariaDB 11.8 LTS (ADR-009)
    Schema          : practicayoruba_db
    Prerequisito    : Migraciones Django aplicadas (catalogue_product, catalogue_category)
    Despliegue      : mysql --socket=/run/mysqld/mysqld.sock practicayoruba_db < v_published_catalog.sql
    Notas           : Renombrada de v_catalogo_publicado (v1.0.0) a v_published_catalog (v2.0.0).
                      Vista de catálogo visible al público: productos is_published=1, is_active=1
                      con categoría activa. v_featured_products depende de esta vista.
********************************************************************************************/

-- DEFINICIÓN

CREATE OR REPLACE VIEW v_published_catalog AS
SELECT
    p.id
  , p.name
  , p.slug
  , p.sku
  , p.short_description
  , p.price
  , p.stock
  , p.is_featured
  , p.created_at
  , p.updated_at
  , c.id   AS category_id
  , c.name AS category_name
  , c.slug AS category_slug
FROM catalogue_product  p
JOIN catalogue_category c ON c.id = p.category_id
WHERE p.is_published = 1
  AND p.is_active   = 1
  AND c.is_active   = 1;

-- VERIFICACIÓN

SELECT
    'v_published_catalog' AS view_name
  , COUNT(*)              AS rows_count
FROM v_published_catalog;

-- FINALIZACIÓN

SELECT 'PROCESO COMPLETADO' AS evento, NOW() AS timestamp_fin FROM DUAL;
