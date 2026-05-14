SELECT 'PROCESO INICIO' AS evento, NOW() AS timestamp_inicio FROM DUAL;

/********************************************************************************************
    Script          : fn_precio_con_iva.sql
    Version         : 1.0.0
    Create          : MAYO/2026
    Engine          : MariaDB 10.11 / 11.8
    Schema          : practicayoruba_db
    Prerequisito    : Ninguno — calculo puro sin dependencias externas
    Despliegue      : mysql --socket=/run/mysqld/mysqld.sock practicayoruba_db < fn_precio_con_iva.sql
    Notas           : Recibe la tasa de IVA como parámetro — no lee settings_sitesettings
                      directamente porque las funciones DETERMINISTIC no pueden hacer SELECT.
                      El caller pasa la tasa vigente (settings_sitesettings.iva_rate).
                      ROUND a 2 decimales: centavos exactos, sin artefactos de punto flotante.
********************************************************************************************/

-- DEFINICIÓN

DELIMITER $$

-- -----------------------------------------------------------------------------
-- fn_precio_con_iva
-- Calcula el precio final con IVA incluido.
--
-- Parámetros:
--   p_precio    DECIMAL(10,2) — precio base sin IVA
--   p_iva_rate  DECIMAL(5,4)  — tasa de IVA como fracción (0.16 para 16%)
--
-- Retorna NULL si cualquier parámetro es NULL o negativo.
--
-- Uso:
--   SELECT fn_precio_con_iva(100.00, 0.16);  -- retorna 116.00
--   SELECT fn_precio_con_iva(p.price, s.iva_rate)
--     FROM catalogue_product p
--     CROSS JOIN settings_sitesettings s;
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_precio_con_iva(
    p_precio   DECIMAL(10,2),
    p_iva_rate DECIMAL(5,4)
)
RETURNS DECIMAL(10,2)
DETERMINISTIC
COMMENT 'Precio con IVA incluido. Retorna ROUND(precio*(1+iva),2). NULL si params inválidos.'
BEGIN
    IF p_precio IS NULL OR p_iva_rate IS NULL THEN
        RETURN NULL;
    END IF;
    IF p_precio < 0 OR p_iva_rate < 0 THEN
        RETURN NULL;
    END IF;
    RETURN ROUND(p_precio * (1 + p_iva_rate), 2);
END$$

DELIMITER ;

-- VERIFICACIÓN

SELECT
    fn_precio_con_iva(100.00, 0.16)  AS esperado_116_00
  , fn_precio_con_iva(250.00, 0.08)  AS esperado_270_00
  , fn_precio_con_iva(333.33, 0.16)  AS esperado_386_66
  , fn_precio_con_iva(0.00,   0.16)  AS esperado_0_00
  , fn_precio_con_iva(NULL,   0.16)  AS esperado_NULL
  , fn_precio_con_iva(100.00, NULL)  AS esperado_NULL
FROM DUAL;

-- FINALIZACIÓN

SELECT 'PROCESO COMPLETADO' AS evento, NOW() AS timestamp_fin FROM DUAL;
