SELECT 'PROCESO INICIO' AS evento, NOW() AS timestamp_inicio FROM DUAL;

/********************************************************************************************
    Script          : v_catalogo_publicado.sql
    Version         : 1.0.0
    Create          : MAYO/2026
    Engine          : MariaDB 10.11 / 11.8
    Schema          : practicayoruba_db
    Prerequisito    : Migraciones Django aplicadas (catalogue_product, catalogue_category)
    Despliegue      : mysql --socket=/run/mysqld/mysqld.sock practicayoruba_db < v_catalogo_publicado.sql
    Notas           : Vista de catálogo visible al público: productos is_published=1, is_active=1
                      con categoría activa. JOIN con catalogue_category incluye category_name
                      y category_slug para evitar un JOIN adicional en el cliente.
                      v_productos_destacados depende de esta vista — desplegarla primero.
********************************************************************************************/

-- DEFINICIÓN

CREATE OR REPLACE VIEW v_catalogo_publicado AS
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
    'v_catalogo_publicado' AS vista
  , COUNT(*)               AS filas
FROM v_catalogo_publicado;

-- FINALIZACIÓN

SELECT 'PROCESO COMPLETADO' AS evento, NOW() AS timestamp_fin FROM DUAL;
