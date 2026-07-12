# Datos de seed — catálogos de referencia

## `sepomex-codigos-postales.txt`

**Catálogo Nacional de Códigos Postales** de México (SEPOMEX / Correos de
México). Es la **fuente de verdad** para poblar la tabla `geo_catalog_postal_code`
(modelo Django en `api`, iniciativa `crear-modelo-usuario-party`, DEC-02) y
también alimenta el trabajo de direcciones de envío / zonas.

Se versiona el `.txt` **tal cual** (sin transformar) para que el loader lo
consuma de forma reproducible y para tener datos reales de CP/colonia en la BD
durante los tests E2E.

### Hechos del archivo (PROVEN)

- **158 589 filas de datos** (línea 1 = licencia, línea 2 = cabecera, resto =
  datos).
- **Encoding: ISO-8859-1 (latin-1)**, terminador de línea **CRLF**. El loader
  DEBE decodificar latin-1 (con UTF-8 los acentos se corrompen) y hacer strip
  del `\r`.
- Separador de columnas: `|` (pipe).
- 32 estados; `d_zona` ∈ {`Urbano`, `Semiurbano`, `Rural`}.
- **Cardinalidad:** un código postal (`d_codigo`) mapea a **N** asentamientos
  (colonias). La clave natural de una fila es `(d_codigo, id_asenta_cpcons)`,
  no `d_codigo` solo.

### Columnas (orden del `.txt`)

```
d_codigo|d_asenta|d_tipo_asenta|D_mnpio|d_estado|d_ciudad|d_CP|c_estado|c_oficina|c_CP|c_tipo_asenta|c_mnpio|id_asenta_cpcons|d_zona|c_cve_ciudad
```

Mapeo a campos en inglés del modelo `CatalogPostalCode` (tabla `geo_catalog_postal_code`): ver la decisión
DEC-02 en
`docs/source/gestion/pm/api/iniciativas/crear-modelo-usuario-party/decisiones-crear-modelo-usuario-party.rst`.

### Licencia

> El Catálogo Nacional de Códigos Postales es elaborado por Correos de México y
> se proporciona en forma gratuita para uso particular, no estando permitida su
> comercialización, total o parcial, ni su distribución a terceros bajo ningún
> concepto.

Uso interno del proyecto para poblar la BD. No redistribuir.
