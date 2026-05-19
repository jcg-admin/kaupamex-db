SELECT 'PROCESO INICIO' AS evento, NOW() AS timestamp_inicio FROM DUAL;

/********************************************************************************************
    Script          : v_low_stock.sql
    Version         : 2.0.0
    Create          : MAYO/2026
    Engine          : MariaDB 11.8 LTS (ADR-009)
    Schema          : practicayoruba_db
    Prerequisito    : Migraciones Django aplicadas — settings_sitesettings con al menos 1 fila
    Despliegue      : mysql --socket=/run/mysqld/mysqld.sock practicayoruba_db < v_low_stock.sql
    Notas           : Renombrada de v_stock_critico (v1.0.0) a v_low_stock (v2.0.0).
                      CROSS JOIN con settings_sitesettings (singleton) lee el threshold directamente.
                      Si settings_sitesettings está vacío la vista retorna 0 filas.
********************************************************************************************/

-- DEFINICIÓN

CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    p.id
  , p.name
  , p.slug
  , p.sku
  , p.stock
  , s.min_stock_threshold            AS threshold
  , s.min_stock_threshold - p.stock  AS units_needed
  , p.is_published
  , c.name                           AS category_name
  , c.slug                           AS category_slug
  , p.price
FROM catalogue_product   p
JOIN catalogue_category  c ON c.id = p.category_id
CROSS JOIN settings_sitesettings s
WHERE p.stock < s.min_stock_threshold
  AND p.is_active = 1
ORDER BY p.stock ASC, units_needed DESC;

-- VERIFICACIÓN

SELECT
    'v_low_stock' AS view_name
  , COUNT(*)      AS rows_count
FROM v_low_stock;

-- FINALIZACIÓN

SELECT 'PROCESO COMPLETADO' AS evento, NOW() AS timestamp_fin FROM DUAL;
