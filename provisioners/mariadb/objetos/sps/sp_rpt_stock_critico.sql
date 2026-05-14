SELECT 'PROCESO INICIO' AS evento, NOW() AS timestamp_inicio FROM DUAL;

/********************************************************************************************
    Script          : sp_rpt_stock_critico.sql
    Version         : 1.0.0
    Create          : MAYO/2026
    Engine          : MariaDB 10.11 / 11.8
    Schema          : practicayoruba_db
    Prerequisito    : fn_stock_status — desplegada antes que este SP
                      settings_sitesettings con al menos 1 fila
    Despliegue      : mysql --socket=/run/mysqld/mysqld.sock practicayoruba_db < sp_rpt_stock_critico.sql
    Notas           : Sin parámetros — lee el umbral actual de settings_sitesettings.
                      Incluye productos is_active=1 con cualquier nivel de publicación:
                      el administrador necesita saber de stock crítico incluso en productos
                      no publicados aún.
                      Usa fn_stock_status para mostrar AGOTADO vs BAJO_STOCK de forma clara.
********************************************************************************************/

-- DEFINICIÓN

DELIMITER $$

-- -----------------------------------------------------------------------------
-- sp_rpt_stock_critico
-- Detalle de productos con stock por debajo del umbral configurado.
--
-- Columnas retornadas:
--   id, name, sku, slug          — identificación del producto
--   stock                        — unidades actuales
--   umbral                       — settings_sitesettings.min_stock_threshold
--   unidades_faltantes           — umbral - stock (cuántas hacen falta para salir del estado crítico)
--   estado                       — AGOTADO | BAJO_STOCK (via fn_stock_status)
--   categoria                    — nombre de la categoría
--   price                        — precio sin IVA
--   is_published                 — si el producto está publicado al público
--
-- Ordenado por stock ASC (primero los más urgentes), unidades_faltantes DESC.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_rpt_stock_critico()
BEGIN
    SELECT
        p.id
      , p.name
      , p.sku
      , p.slug
      , p.stock
      , s.min_stock_threshold                              AS umbral
      , s.min_stock_threshold - p.stock                   AS unidades_faltantes
      , fn_stock_status(p.stock, s.min_stock_threshold)   AS estado
      , c.name                                             AS categoria
      , p.price
      , p.is_published
    FROM catalogue_product   p
    JOIN catalogue_category  c ON c.id = p.category_id
    CROSS JOIN settings_sitesettings s
    WHERE p.stock < s.min_stock_threshold
      AND p.is_active = 1
    ORDER BY p.stock ASC, unidades_faltantes DESC;
END$$

DELIMITER ;

-- VERIFICACIÓN

CALL sp_rpt_stock_critico();

-- FINALIZACIÓN

SELECT 'PROCESO COMPLETADO' AS evento, NOW() AS timestamp_fin FROM DUAL;
