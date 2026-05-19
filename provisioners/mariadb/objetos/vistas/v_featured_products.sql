SELECT 'PROCESO INICIO' AS evento, NOW() AS timestamp_inicio FROM DUAL;

/********************************************************************************************
    Script          : v_featured_products.sql
    Version         : 2.0.0
    Create          : MAYO/2026
    Engine          : MariaDB 11.8 LTS (ADR-009)
    Schema          : practicayoruba_db
    Prerequisito    : v_published_catalog — desplegar antes que esta vista
    Despliegue      : mysql --socket=/run/mysqld/mysqld.sock practicayoruba_db < v_featured_products.sql
    Notas           : Renombrada de v_productos_destacados (v1.0.0) a v_featured_products (v2.0.0).
                      Subconjunto de v_published_catalog donde is_featured=1.
                      El orden de despliegue es obligatorio:
                      v_published_catalog ANTES de v_featured_products.
********************************************************************************************/

-- DEFINICIÓN

CREATE OR REPLACE VIEW v_featured_products AS
SELECT *
FROM v_published_catalog
WHERE is_featured = 1;

-- VERIFICACIÓN

SELECT
    'v_featured_products' AS view_name
  , COUNT(*)              AS rows_count
FROM v_featured_products;

-- FINALIZACIÓN

SELECT 'PROCESO COMPLETADO' AS evento, NOW() AS timestamp_fin FROM DUAL;
