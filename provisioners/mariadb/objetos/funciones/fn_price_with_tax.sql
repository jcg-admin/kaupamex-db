SELECT 'PROCESO INICIO' AS evento, NOW() AS timestamp_inicio FROM DUAL;

/********************************************************************************************
    Script          : fn_price_with_tax.sql
    Version         : 2.0.0
    Create          : MAYO/2026
    Engine          : MariaDB 10.11 / 11.8
    Schema          : practicayoruba_db
    Prerequisito    : Ninguno — calculo puro sin dependencias externas
    Despliegue      : mysql --socket=/run/mysqld/mysqld.sock practicayoruba_db < fn_price_with_tax.sql
    Notas           : Renombrada de fn_precio_con_iva (v1.0.0) a fn_price_with_tax (v2.0.0).
                      Recibe la tasa de IVA como parámetro — no lee settings_sitesettings
                      directamente porque las funciones DETERMINISTIC no pueden hacer SELECT.
                      El caller pasa la tasa vigente (settings_sitesettings.iva_rate).
                      ROUND a 2 decimales: centavos exactos, sin artefactos de punto flotante.
********************************************************************************************/

-- DEFINICIÓN

DELIMITER $$

-- -----------------------------------------------------------------------------
-- fn_price_with_tax
-- Calcula el precio final con IVA incluido.
--
-- Parámetros:
--   p_price    DECIMAL(10,2) — precio base sin IVA
--   p_iva_rate DECIMAL(5,4)  — tasa de IVA como fracción (0.16 para 16%)
--
-- Retorna NULL si cualquier parámetro es NULL o negativo.
--
-- Uso:
--   SELECT fn_price_with_tax(100.00, 0.16);  -- retorna 116.00
--   SELECT fn_price_with_tax(p.price, s.iva_rate)
--     FROM catalogue_product p
--     CROSS JOIN settings_sitesettings s;
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_price_with_tax(
    p_price    DECIMAL(10,2),
    p_iva_rate DECIMAL(5,4)
)
RETURNS DECIMAL(10,2)
DETERMINISTIC
COMMENT 'Precio con IVA incluido. Retorna ROUND(price*(1+iva),2). NULL si params inválidos.'
BEGIN
    IF p_price IS NULL OR p_iva_rate IS NULL THEN
        RETURN NULL;
    END IF;
    IF p_price < 0 OR p_iva_rate < 0 THEN
        RETURN NULL;
    END IF;
    RETURN ROUND(p_price * (1 + p_iva_rate), 2);
END$$

DELIMITER ;

-- VERIFICACIÓN

SELECT
    fn_price_with_tax(100.00, 0.16)  AS expected_116_00
  , fn_price_with_tax(250.00, 0.08)  AS expected_270_00
  , fn_price_with_tax(333.33, 0.16)  AS expected_386_66
  , fn_price_with_tax(0.00,   0.16)  AS expected_0_00
  , fn_price_with_tax(NULL,   0.16)  AS expected_NULL
  , fn_price_with_tax(100.00, NULL)  AS expected_NULL
FROM DUAL;

-- FINALIZACIÓN

SELECT 'PROCESO COMPLETADO' AS evento, NOW() AS timestamp_fin FROM DUAL;
