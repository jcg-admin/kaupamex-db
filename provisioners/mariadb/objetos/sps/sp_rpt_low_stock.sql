SELECT 'PROCESO INICIO' AS evento, NOW() AS timestamp_inicio FROM DUAL;

/********************************************************************************************
    Script          : sp_rpt_low_stock.sql
    Version         : 3.0.0
    Create          : MAYO/2026
    Engine          : MariaDB 11.8 LTS (ADR-009)
    Schema          : kaupamex_db
    Prerequisito    : fn_stock_status — desplegada antes que este SP
                      settings_sitesettings con al menos 1 fila
    Despliegue      : mysql --socket=/run/mysqld/mysqld.sock kaupamex_db < sp_rpt_low_stock.sql
    Notas           : Renombrado de sp_rpt_stock_critico (v1.0.0) a sp_rpt_low_stock (v2.0.0).
                      Sin parámetros — lee el threshold actual de settings_sitesettings.
                      Usa fn_stock_status para mostrar OUT_OF_STOCK vs LOW_STOCK de forma clara.
********************************************************************************************/

-- DEFINICIÓN

DELIMITER $$

-- -----------------------------------------------------------------------------
-- sp_rpt_low_stock
-- Detalle de productos con stock por debajo del threshold configurado.
--
-- Columnas retornadas:
--   id, name, sku, slug     — identificación del producto
--   stock                   — unidades actuales
--   threshold               — settings_sitesettings.min_stock_threshold
--   units_needed            — threshold - stock
--   status                  — OUT_OF_STOCK | LOW_STOCK (via fn_stock_status)
--   category                — nombre de la categoría
--   price                   — precio sin IVA
--   is_published            — si el producto está publicado al público
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_rpt_low_stock()
BEGIN
    SELECT
        p.id
      , p.name
      , p.sku
      , p.slug
      , p.stock
      , s.min_stock_threshold                              AS threshold
      , s.min_stock_threshold - p.stock                   AS units_needed
      , fn_stock_status(p.stock, s.min_stock_threshold)   AS status
      , c.name                                             AS category
      , p.price
      , p.is_published
    FROM catalogue_product   p
    JOIN catalogue_product_categories pc ON pc.product_id = p.id
    JOIN catalogue_category  c ON c.id = pc.category_id
    CROSS JOIN settings_sitesettings s
    WHERE p.stock < s.min_stock_threshold
      AND p.is_active = 1
    ORDER BY p.stock ASC, units_needed DESC;
END$$

DELIMITER ;

-- VERIFICACIÓN

CALL sp_rpt_low_stock();

-- FINALIZACIÓN

SELECT 'PROCESO COMPLETADO' AS evento, NOW() AS timestamp_fin FROM DUAL;
