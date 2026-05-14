SELECT 'PROCESO INICIO' AS evento, NOW() AS timestamp_inicio FROM DUAL;

/********************************************************************************************
    Script          : sp_rpt_catalog_summary.sql
    Version         : 2.0.0
    Create          : MAYO/2026
    Engine          : MariaDB 10.11 / 11.8
    Schema          : practicayoruba_db
    Prerequisito    : Migraciones Django aplicadas
                      settings_sitesettings con al menos 1 fila
    Despliegue      : mysql --socket=/run/mysqld/mysqld.sock practicayoruba_db < sp_rpt_catalog_summary.sql
    Notas           : Renombrado de sp_rpt_resumen_catalogo (v1.0.0) a sp_rpt_catalog_summary (v2.0.0).
                      Sin parámetros — dashboard ejecutivo en una sola fila.
                      CROSS JOIN con settings_sitesettings (singleton) para incluir
                      la configuración vigente en el mismo resultado.
********************************************************************************************/

-- DEFINICIÓN

DELIMITER $$

-- -----------------------------------------------------------------------------
-- sp_rpt_catalog_summary
-- Vista ejecutiva del estado global del catálogo en una sola fila.
--
-- Columnas retornadas:
--   total_products       — todos los productos registrados
--   active               — is_active=1
--   published            — is_published=1
--   featured             — is_featured=1 AND is_published=1
--   out_of_stock         — stock=0
--   low_stock            — 0 < stock < min_stock_threshold
--   price_min            — precio más bajo del catálogo completo
--   price_max            — precio más alto del catálogo completo
--   price_avg            — promedio, redondeado a 2 decimales
--   stock_threshold      — settings_sitesettings.min_stock_threshold vigente
--   tax_rate             — settings_sitesettings.iva_rate vigente
--   free_shipping_threshold — settings_sitesettings.free_shipping_threshold vigente
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_rpt_catalog_summary()
BEGIN
    SELECT
        COUNT(p.id)                                                         AS total_products
      , SUM(IF(p.is_active = 1, 1, 0))                                     AS active
      , SUM(IF(p.is_published = 1, 1, 0))                                  AS published
      , SUM(IF(p.is_featured = 1 AND p.is_published = 1, 1, 0))            AS featured
      , SUM(IF(p.stock = 0, 1, 0))                                         AS out_of_stock
      , SUM(IF(p.stock > 0 AND p.stock < s.min_stock_threshold, 1, 0))     AS low_stock
      , MIN(p.price)                                                        AS price_min
      , MAX(p.price)                                                        AS price_max
      , ROUND(AVG(p.price), 2)                                              AS price_avg
      , s.min_stock_threshold                                               AS stock_threshold
      , s.iva_rate                                                          AS tax_rate
      , s.free_shipping_threshold                                           AS free_shipping_threshold
    FROM catalogue_product p
    CROSS JOIN settings_sitesettings s;
END$$

DELIMITER ;

-- VERIFICACIÓN

CALL sp_rpt_catalog_summary();

-- FINALIZACIÓN

SELECT 'PROCESO COMPLETADO' AS evento, NOW() AS timestamp_fin FROM DUAL;
