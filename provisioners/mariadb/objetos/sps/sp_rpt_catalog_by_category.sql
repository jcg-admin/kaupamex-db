SELECT 'PROCESO INICIO' AS evento, NOW() AS timestamp_inicio FROM DUAL;

/********************************************************************************************
    Script          : sp_rpt_catalog_by_category.sql
    Version         : 3.0.0
    Create          : MAYO/2026
    Engine          : MariaDB 11.8 LTS (ADR-009)
    Schema          : kaupamex_db
    Prerequisito    : Migraciones Django aplicadas (catalogue_product, catalogue_category)
    Despliegue      : mysql --socket=/run/mysqld/mysqld.sock kaupamex_db < sp_rpt_catalog_by_category.sql
    Notas           : Renombrado de sp_rpt_catalogo_por_categoria (v1.0.0) a sp_rpt_catalog_by_category (v2.0.0).
                      Sin parámetros — retorna el estado actual del catálogo.
                      LEFT JOIN para incluir categorías sin productos (total_products=0).
********************************************************************************************/

-- DEFINICIÓN

DELIMITER $$

-- -----------------------------------------------------------------------------
-- sp_rpt_catalog_by_category
-- Resumen del catálogo agrupado por categoría.
--
-- Columnas retornadas:
--   category_id, category, category_slug — identificación de la categoría
--   total_products  — todos los productos (activos o no)
--   published       — is_published=1 AND is_active=1
--   out_of_stock    — stock=0
--   price_min       — precio mínimo de todos los productos de la categoría
--   price_max       — precio máximo de todos los productos de la categoría
--   price_avg       — precio promedio, 2 decimales
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_rpt_catalog_by_category()
BEGIN
    SELECT
        c.id                                                          AS category_id
      , c.name                                                        AS category
      , c.slug                                                        AS category_slug
      , COUNT(p.id)                                                   AS total_products
      , SUM(IF(p.is_published = 1 AND p.is_active = 1, 1, 0))        AS published
      , SUM(IF(p.stock = 0, 1, 0))                                   AS out_of_stock
      , MIN(p.price)                                                  AS price_min
      , MAX(p.price)                                                  AS price_max
      , ROUND(AVG(p.price), 2)                                        AS price_avg
    FROM catalogue_category  c
    LEFT JOIN catalogue_product_categories pc ON pc.category_id = c.id
    LEFT JOIN catalogue_product p ON p.id = pc.product_id
    WHERE c.is_active = 1
    GROUP BY c.id, c.name, c.slug
    ORDER BY total_products DESC, c.name ASC;
END$$

DELIMITER ;

-- VERIFICACIÓN

CALL sp_rpt_catalog_by_category();

-- FINALIZACIÓN

SELECT 'PROCESO COMPLETADO' AS evento, NOW() AS timestamp_fin FROM DUAL;
