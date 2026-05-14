SELECT 'PROCESO INICIO' AS evento, NOW() AS timestamp_inicio FROM DUAL;

/********************************************************************************************
    Script          : sp_rpt_catalogo_por_categoria.sql
    Version         : 1.0.0
    Create          : MAYO/2026
    Engine          : MariaDB 10.11 / 11.8
    Schema          : practicayoruba_db
    Prerequisito    : Migraciones Django aplicadas (catalogue_product, catalogue_category)
    Despliegue      : mysql --socket=/run/mysqld/mysqld.sock practicayoruba_db < sp_rpt_catalogo_por_categoria.sql
    Notas           : Sin parámetros — retorna el estado actual del catálogo.
                      LEFT JOIN para incluir categorías sin productos (total_productos=0).
                      Solo categorías is_active=1. Una fila por categoría activa.
                      precio_minimo/maximo/promedio son NULL si no hay productos en la categoría.
********************************************************************************************/

-- DEFINICIÓN

DELIMITER $$

-- -----------------------------------------------------------------------------
-- sp_rpt_catalogo_por_categoria
-- Resumen del catálogo agrupado por categoría.
--
-- Columnas retornadas:
--   categoria_id, categoria, categoria_slug — identificación de la categoría
--   total_productos  — todos los productos (activos o no)
--   publicados       — is_published=1 AND is_active=1
--   agotados         — stock=0 (independiente de is_published)
--   precio_minimo    — de todos los productos de la categoría
--   precio_maximo    — de todos los productos de la categoría
--   precio_promedio  — de todos los productos de la categoría, 2 decimales
--
-- Ordenado por total_productos DESC, nombre de categoría ASC.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_rpt_catalogo_por_categoria()
BEGIN
    SELECT
        c.id                                                          AS categoria_id
      , c.name                                                        AS categoria
      , c.slug                                                        AS categoria_slug
      , COUNT(p.id)                                                   AS total_productos
      , SUM(IF(p.is_published = 1 AND p.is_active = 1, 1, 0))        AS publicados
      , SUM(IF(p.stock = 0, 1, 0))                                   AS agotados
      , MIN(p.price)                                                  AS precio_minimo
      , MAX(p.price)                                                  AS precio_maximo
      , ROUND(AVG(p.price), 2)                                        AS precio_promedio
    FROM catalogue_category  c
    LEFT JOIN catalogue_product p ON p.category_id = c.id
    WHERE c.is_active = 1
    GROUP BY c.id, c.name, c.slug
    ORDER BY total_productos DESC, c.name ASC;
END$$

DELIMITER ;

-- VERIFICACIÓN

CALL sp_rpt_catalogo_por_categoria();

-- FINALIZACIÓN

SELECT 'PROCESO COMPLETADO' AS evento, NOW() AS timestamp_fin FROM DUAL;
