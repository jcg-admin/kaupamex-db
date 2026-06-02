SELECT 'PROCESO INICIO' AS evento, NOW() AS timestamp_inicio FROM DUAL;

/********************************************************************************************
    Script          : fn_stock_status.sql
    Version         : 2.0.0
    Create          : MAYO/2026
    Engine          : MariaDB 11.8 LTS (ADR-009)
    Schema          : practicayoruba_db
    Prerequisito    : Ninguno — clasificación pura sin dependencias externas
    Despliegue      : mysql --socket=/run/mysqld/mysqld.sock practicayoruba_db < fn_stock_status.sql
    Notas           : p_umbral renombrado a p_threshold (v2.0.0). Recibe el threshold como parámetro — no lee settings_sitesettings
                      directamente porque las funciones DETERMINISTIC no pueden hacer SELECT.
                      El caller pasa settings_sitesettings.min_stock_threshold.
                      Tres estados (enums en INGLES, canon de codigo): OUT_OF_STOCK
                      (stock=0 o NULL) / LOW_STOCK (0 < stock < umbral) / AVAILABLE
                      (stock >= umbral). El espanol es solo display de UI, no del enum.
********************************************************************************************/

-- DEFINICIÓN

DELIMITER $$

-- -----------------------------------------------------------------------------
-- fn_stock_status
-- Clasifica el nivel de stock de un producto en tres estados.
--
-- Parámetros:
--   p_stock   INT — unidades actuales en stock (>= 0)
--   p_threshold  INT — stock threshold configurado (settings_sitesettings.min_stock_threshold)
--
-- Retorna:
--   'OUT_OF_STOCK' — stock es NULL o 0
--   'LOW_STOCK'    — 0 < stock < umbral
--   'AVAILABLE'    — stock >= umbral
--
-- Uso:
--   SELECT fn_stock_status(p.stock, s.min_stock_threshold)
--     FROM catalogue_product p
--     CROSS JOIN settings_sitesettings s;
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_stock_status(
    p_stock  INT,
    p_threshold INT
)
RETURNS VARCHAR(20)
DETERMINISTIC
COMMENT 'Clasifica stock: OUT_OF_STOCK | LOW_STOCK | AVAILABLE según umbral.'
BEGIN
    -- NULL se trata como agotado — el stock de un producto nunca debería ser NULL
    -- pero la función es defensiva para evitar retornar un valor inesperado.
    IF p_stock IS NULL OR p_stock = 0 THEN
        RETURN 'OUT_OF_STOCK';
    END IF;
    IF p_threshold IS NULL OR p_stock >= p_threshold THEN
        RETURN 'AVAILABLE';
    END IF;
    RETURN 'LOW_STOCK';
END$$

DELIMITER ;

-- VERIFICACIÓN

SELECT
    fn_stock_status(0,  5)    AS expected_OUT_OF_STOCK
  , fn_stock_status(3,  5)    AS expected_LOW_STOCK
  , fn_stock_status(5,  5)    AS expected_AVAILABLE
  , fn_stock_status(10, 5)    AS expected_AVAILABLE
  , fn_stock_status(NULL, 5)  AS expected_OUT_OF_STOCK
  , fn_stock_status(1,  NULL) AS expected_AVAILABLE
FROM DUAL;

-- FINALIZACIÓN

SELECT 'PROCESO COMPLETADO' AS evento, NOW() AS timestamp_fin FROM DUAL;
