SELECT 'PROCESO INICIO' AS evento, NOW() AS timestamp_inicio FROM DUAL;

/********************************************************************************************
    Script          : fn_aplica_envio_gratis.sql
    Version         : 1.0.0
    Create          : MAYO/2026
    Engine          : MariaDB 10.11 / 11.8
    Schema          : practicayoruba_db
    Prerequisito    : Ninguno — predicado puro sin dependencias externas
    Despliegue      : mysql --socket=/run/mysqld/mysqld.sock practicayoruba_db < fn_aplica_envio_gratis.sql
    Notas           : Recibe el umbral como parámetro — no lee settings_sitesettings
                      directamente porque las funciones DETERMINISTIC no pueden hacer SELECT.
                      El caller pasa settings_sitesettings.free_shipping_threshold.
                      El umbral es inclusivo: subtotal == umbral → envío gratis.
********************************************************************************************/

-- DEFINICIÓN

DELIMITER $$

-- -----------------------------------------------------------------------------
-- fn_aplica_envio_gratis
-- Determina si el subtotal de una orden califica para envío gratis.
--
-- Parámetros:
--   p_subtotal DECIMAL(10,2) — subtotal de la orden (suma de precios sin IVA)
--   p_umbral   DECIMAL(10,2) — umbral de envío gratis (settings_sitesettings.free_shipping_threshold)
--
-- Retorna:
--   TRUE (1)  — subtotal >= umbral
--   FALSE (0) — subtotal < umbral o parámetro NULL
--
-- Umbral inclusivo: exactamente el umbral también aplica.
--
-- Uso:
--   SELECT fn_aplica_envio_gratis(SUM(p.price * cantidad), s.free_shipping_threshold)
--     FROM carrito c
--     JOIN catalogue_product p ON p.id = c.product_id
--     CROSS JOIN settings_sitesettings s;
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_aplica_envio_gratis(
    p_subtotal DECIMAL(10,2),
    p_umbral   DECIMAL(10,2)
)
RETURNS BOOLEAN
DETERMINISTIC
COMMENT 'TRUE si subtotal >= umbral de envío gratis. FALSE si NULL.'
BEGIN
    IF p_subtotal IS NULL OR p_umbral IS NULL THEN
        RETURN FALSE;
    END IF;
    RETURN p_subtotal >= p_umbral;
END$$

DELIMITER ;

-- VERIFICACIÓN

SELECT
    fn_aplica_envio_gratis(600.00, 500.00)  AS esperado_1
  , fn_aplica_envio_gratis(500.00, 500.00)  AS esperado_1
  , fn_aplica_envio_gratis(499.99, 500.00)  AS esperado_0
  , fn_aplica_envio_gratis(0.00,   500.00)  AS esperado_0
  , fn_aplica_envio_gratis(NULL,   500.00)  AS esperado_0
  , fn_aplica_envio_gratis(600.00, NULL)    AS esperado_0
FROM DUAL;

-- FINALIZACIÓN

SELECT 'PROCESO COMPLETADO' AS evento, NOW() AS timestamp_fin FROM DUAL;
