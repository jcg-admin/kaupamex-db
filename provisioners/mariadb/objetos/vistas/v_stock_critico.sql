SELECT 'PROCESO INICIO' AS evento, NOW() AS timestamp_inicio FROM DUAL;

/********************************************************************************************
    Script          : v_stock_critico.sql
    Version         : 1.0.0
    Create          : MAYO/2026
    Engine          : MariaDB 10.11 / 11.8
    Schema          : practicayoruba_db
    Prerequisito    : Migraciones Django aplicadas — settings_sitesettings con al menos 1 fila
    Despliegue      : mysql --socket=/run/mysqld/mysqld.sock practicayoruba_db < v_stock_critico.sql
    Notas           : CROSS JOIN con settings_sitesettings (singleton) lee el umbral directamente
                      — no es posible en funciones DETERMINISTIC pero sí en vistas.
                      Si settings_sitesettings está vacío la vista retorna 0 filas.
                      Incluye productos is_active=1 con cualquier nivel de publicación:
                      un producto no publicado también puede tener stock crítico.
********************************************************************************************/

-- DEFINICIÓN

CREATE OR REPLACE VIEW v_stock_critico AS
SELECT
    p.id
  , p.name
  , p.slug
  , p.sku
  , p.stock
  , s.min_stock_threshold                AS umbral
  , s.min_stock_threshold - p.stock      AS unidades_faltantes
  , p.is_published
  , c.name                               AS category_name
  , c.slug                               AS category_slug
  , p.price
FROM catalogue_product   p
JOIN catalogue_category  c ON c.id = p.category_id
CROSS JOIN settings_sitesettings s
WHERE p.stock < s.min_stock_threshold
  AND p.is_active = 1
ORDER BY p.stock ASC, unidades_faltantes DESC;

-- VERIFICACIÓN

SELECT
    'v_stock_critico' AS vista
  , COUNT(*)          AS filas
FROM v_stock_critico;

-- FINALIZACIÓN

SELECT 'PROCESO COMPLETADO' AS evento, NOW() AS timestamp_fin FROM DUAL;
