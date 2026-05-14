SELECT 'PROCESO INICIO' AS evento, NOW() AS timestamp_inicio FROM DUAL;

/********************************************************************************************
    Script          : v_productos_destacados.sql
    Version         : 1.0.0
    Create          : MAYO/2026
    Engine          : MariaDB 10.11 / 11.8
    Schema          : practicayoruba_db
    Prerequisito    : v_catalogo_publicado — desplegar antes que esta vista
    Despliegue      : mysql --socket=/run/mysqld/mysqld.sock practicayoruba_db < v_productos_destacados.sql
    Notas           : Subconjunto de v_catalogo_publicado donde is_featured=1.
                      Depende de v_catalogo_publicado — cualquier cambio en la vista base
                      se propaga automáticamente. El orden de despliegue es obligatorio:
                      v_catalogo_publicado ANTES de v_productos_destacados.
********************************************************************************************/

-- DEFINICIÓN

CREATE OR REPLACE VIEW v_productos_destacados AS
SELECT *
FROM v_catalogo_publicado
WHERE is_featured = 1;

-- VERIFICACIÓN

SELECT
    'v_productos_destacados' AS vista
  , COUNT(*)                 AS filas
FROM v_productos_destacados;

-- FINALIZACIÓN

SELECT 'PROCESO COMPLETADO' AS evento, NOW() AS timestamp_fin FROM DUAL;
