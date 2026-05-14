SELECT 'PROCESO INICIO' AS evento, NOW() AS timestamp_inicio FROM DUAL;

/********************************************************************************************
    Script          : fn_qualifies_free_shipping.sql
    Version         : 2.0.0
    Create          : MAYO/2026
    Engine          : MariaDB 10.11 / 11.8
    Schema          : practicayoruba_db
    Prerequisito    : Ninguno — predicado puro sin dependencias externas
    Despliegue      : mysql --socket=/run/mysqld/mysqld.sock practicayoruba_db < fn_qualifies_free_shipping.sql
    Notas           : Renombrada de fn_aplica_envio_gratis (v1.0.0) a fn_qualifies_free_shipping (v2.0.0).
                      Recibe el umbral como parámetro — no lee settings_sitesettings
                      directamente porque las funciones DETERMINISTIC no pueden hacer SELECT.
                      El caller pasa settings_sitesettings.free_shipping_threshold.
                      El umbral es inclusivo: subtotal == threshold → envío gratis.
********************************************************************************************/

-- DEFINICIÓN

DELIMITER $$

-- -----------------------------------------------------------------------------
-- fn_qualifies_free_shipping
-- Determina si el subtotal de una orden califica para envío gratis.
--
-- Parámetros:
--   p_subtotal  DECIMAL(10,2) — subtotal de la orden (suma de precios sin IVA)
--   p_threshold DECIMAL(10,2) — umbral de envío gratis (settings_sitesettings.free_shipping_threshold)
--
-- Retorna:
--   TRUE (1)  — subtotal >= threshold
--   FALSE (0) — subtotal < threshold o parámetro NULL
--
-- Umbral inclusivo: exactamente el threshold también aplica.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_qualifies_free_shipping(
    p_subtotal  DECIMAL(10,2),
    p_threshold DECIMAL(10,2)
)
RETURNS BOOLEAN
DETERMINISTIC
COMMENT 'TRUE si subtotal >= threshold de envío gratis. FALSE si NULL.'
BEGIN
    IF p_subtotal IS NULL OR p_threshold IS NULL THEN
        RETURN FALSE;
    END IF;
    RETURN p_subtotal >= p_threshold;
END$$

DELIMITER ;

-- VERIFICACIÓN

SELECT
    fn_qualifies_free_shipping(600.00, 500.00)  AS expected_1
  , fn_qualifies_free_shipping(500.00, 500.00)  AS expected_1
  , fn_qualifies_free_shipping(499.99, 500.00)  AS expected_0
  , fn_qualifies_free_shipping(0.00,   500.00)  AS expected_0
  , fn_qualifies_free_shipping(NULL,   500.00)  AS expected_0
  , fn_qualifies_free_shipping(600.00, NULL)    AS expected_0
FROM DUAL;

-- FINALIZACIÓN

SELECT 'PROCESO COMPLETADO' AS evento, NOW() AS timestamp_fin FROM DUAL;
