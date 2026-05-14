SELECT 'PROCESO INICIO' AS evento, NOW() AS timestamp_inicio FROM DUAL;

/********************************************************************************************
    Script          : sp_rpt_resumen_catalogo.sql
    Version         : 1.0.0
    Create          : MAYO/2026
    Engine          : MariaDB 10.11 / 11.8
    Schema          : practicayoruba_db
    Prerequisito    : Migraciones Django aplicadas
                      settings_sitesettings con al menos 1 fila
    Despliegue      : mysql --socket=/run/mysqld/mysqld.sock practicayoruba_db < sp_rpt_resumen_catalogo.sql
    Notas           : Sin parámetros — dashboard ejecutivo en una sola fila.
                      CROSS JOIN con settings_sitesettings (singleton) para incluir la
                      configuración vigente en el mismo resultado.
                      agotados y bajo_stock usan el umbral de settings_sitesettings.
                      precio_minimo/maximo/promedio incluyen TODOS los productos
                      independientemente de is_active o is_published.
********************************************************************************************/

-- DEFINICIÓN

DELIMITER $$

-- -----------------------------------------------------------------------------
-- sp_rpt_resumen_catalogo
-- Vista ejecutiva del estado global del catálogo en una sola fila.
--
-- Columnas retornadas:
--   total_productos  — todos los productos registrados
--   activos          — is_active=1
--   publicados       — is_published=1 (puede incluir no activos)
--   destacados       — is_featured=1 AND is_published=1
--   agotados         — stock=0
--   bajo_stock       — 0 < stock < min_stock_threshold
--   precio_minimo    — precio más bajo del catálogo completo
--   precio_maximo    — precio más alto del catálogo completo
--   precio_promedio  — promedio, redondeado a 2 decimales
--   umbral_stock     — settings_sitesettings.min_stock_threshold vigente
--   tasa_iva         — settings_sitesettings.iva_rate vigente
--   umbral_envio_gratis — settings_sitesettings.free_shipping_threshold vigente
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_rpt_resumen_catalogo()
BEGIN
    SELECT
        COUNT(p.id)                                                         AS total_productos
      , SUM(IF(p.is_active = 1, 1, 0))                                     AS activos
      , SUM(IF(p.is_published = 1, 1, 0))                                  AS publicados
      , SUM(IF(p.is_featured = 1 AND p.is_published = 1, 1, 0))            AS destacados
      , SUM(IF(p.stock = 0, 1, 0))                                         AS agotados
      , SUM(IF(p.stock > 0 AND p.stock < s.min_stock_threshold, 1, 0))     AS bajo_stock
      , MIN(p.price)                                                        AS precio_minimo
      , MAX(p.price)                                                        AS precio_maximo
      , ROUND(AVG(p.price), 2)                                              AS precio_promedio
      , s.min_stock_threshold                                               AS umbral_stock
      , s.iva_rate                                                          AS tasa_iva
      , s.free_shipping_threshold                                           AS umbral_envio_gratis
    FROM catalogue_product p
    CROSS JOIN settings_sitesettings s;
END$$

DELIMITER ;

-- VERIFICACIÓN

CALL sp_rpt_resumen_catalogo();

-- FINALIZACIÓN

SELECT 'PROCESO COMPLETADO' AS evento, NOW() AS timestamp_fin FROM DUAL;
