# Terminología L0/Company — cheat-sheet (canónico en docs)

Regla completa: `docs/.claude/rules/terminologia-l0-company.md`. Invariante:

**Company, nunca "Tenant"** (el modelo de suscripción es `CompanyModuleSubscription`,
no "TenantModuleSubscription"). **El producto/plataforma es Kaupamex (L0).** Los
repos se llaman `kaupamex-*` (renombrados desde `e-comerce-*` el 2026-07-23); el
nombre del repo coincide con el operador L0. Un **e-commerce** (sustantivo genérico)
es a lo sumo lo que hace un **L1** (una `Company` cliente) — nunca "el producto".

**El L1 no se nombra — ni en código ni en prosa.** Actualizado 2026-09-05 por
directiva del ejecutor: *«ya no queremos que esté practicayoruba»*. La empresa L1
inicial se declara en **config** (`BOOTSTRAP_COMPANY_CODE` / `BOOTSTRAP_COMPANY_NAME`,
ambas con `default=''`) y la crea `kaupamex-bin company_create`; con esas claves
vacías no se siembra ninguna. En prosa se dice **"la empresa L1"** o **"el L1 de
ejemplo"**, sin nombre propio. "founder" sigue prohibido: implica fundar u operar
la plataforma, que es lo contrario de ser un L1.

Canon: DEC-KX-05 + ADR-021. Verificar nombres reales en código, no de labels de
tareas (react-gate).
