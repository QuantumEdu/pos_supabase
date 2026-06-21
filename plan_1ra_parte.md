# plan.md

# Plan de Implementación

## SaaS POS para Suplementos, Vitaminas y Nutracéuticos

Versión: 1.0

---

# 1. Objetivo del Plan

Convertir la especificación funcional en una ruta técnica de desarrollo para construir un MVP usando:

* Vue 3
* TypeScript
* Supabase
* PostgreSQL
* Row Level Security
* Edge Functions
* RPC SQL transaccional

El objetivo del MVP es validar el núcleo operativo:

* Inventario confiable
* Compras
* Ventas POS
* Caja
* Crédito y abonos
* Reportes básicos

---

# 2. Arquitectura General

```text
Vue 3 + TypeScript
        |
        | Supabase JS SDK
        |
Supabase Auth
        |
Row Level Security
        |
PostgreSQL
        |
RPC SQL transaccional
        |
Edge Functions
```

---

# 3. Principios Técnicos

## 3.1 Supabase como plataforma principal

No se usará backend externo en V1.

Se utilizará:

* Supabase Auth
* Supabase PostgreSQL
* Supabase RLS
* Supabase Edge Functions
* Supabase Storage si se requiere posteriormente

---

## 3.2 Operaciones críticas vía Edge Functions

Toda operación que afecte dinero o inventario deberá pasar por Edge Function.

Ejemplos:

* Crear venta
* Registrar compra
* Recibir mercancía
* Registrar abono
* Cerrar caja
* Cancelar venta
* Ajustar inventario
* Autorizar descuento

---

## 3.3 Consistencia mediante RPC SQL

Las operaciones críticas llamarán funciones SQL transaccionales.

Ejemplo:

```text
Vue
  ↓
Edge Function create-sale
  ↓
RPC create_sale_transaction()
  ↓
PostgreSQL transaction
```

---

## 3.4 Seguridad por RLS

Todas las tablas operativas deberán protegerse por:

```text
company_id
```

y cuando aplique:

```text
branch_id
```

---

# 4. Fases de Desarrollo

---

# Fase 0: Preparación del Proyecto

## Objetivo

Crear la base técnica del proyecto.

## Entregables

* Proyecto Vue 3 + TypeScript
* Configuración Supabase
* Variables de entorno
* Estructura inicial de carpetas
* Conexión Supabase JS
* Estándares de código

## Resultado esperado

El usuario puede iniciar sesión y acceder a una pantalla base.

---

# Fase 1: Multiempresa, Sucursales y Usuarios

## Objetivo

Crear la estructura SaaS base.

## Módulos

* Empresas
* Sucursales
* Usuarios
* Roles
* Relación usuario-empresa
* Relación usuario-sucursal

## Tablas principales

```text
companies
branches
profiles
company_users
branch_users
subscription_plans
company_subscriptions
```

## Reglas

* Un usuario puede pertenecer a varias empresas.
* Un usuario puede tener diferente rol por empresa.
* El cajero solo accede a sucursales asignadas.
* El administrador puede gestionar la empresa.

## Resultado esperado

El usuario puede:

* Iniciar sesión
* Seleccionar empresa
* Seleccionar sucursal
* Acceder según su rol

---

# Fase 2: Catálogo Base

## Objetivo

Crear la estructura de productos y variantes.

## Módulos

* Marcas
* Categorías
* Unidades
* Productos
* Variantes

## Tablas principales

```text
brands
categories
units
products
product_variants
```

## Reglas

* Cada empresa tiene su propio catálogo.
* Cada producto puede tener múltiples variantes.
* Cada variante tiene SKU y código de barras.
* El precio es único por empresa.
* El último costo se guarda en la variante.
* El costo histórico se guarda en compras.

## Resultado esperado

El administrador puede crear y administrar productos vendibles.

---

# Fase 3: Proveedores y Compras

## Objetivo

Permitir registrar pedidos y recepciones de mercancía.

## Módulos

* Proveedores
* Pedidos de compra
* Recepción total
* Recepción parcial
* IVA
* Forma de pago
* Costo histórico

## Tablas principales

```text
suppliers
purchase_orders
purchase_order_items
purchase_receipts
purchase_receipt_items
```

## Estados de pedido

```text
draft
sent
partial
received
cancelled
```

## Reglas

* El inventario no aumenta al crear pedido.
* El inventario aumenta solo al recibir mercancía.
* Una compra puede recibirse parcialmente.
* Cada recepción puede generar lotes.
* Cada item puede tener IVA o no tener IVA.
* Se guarda costo histórico por item.

## Edge Functions

```text
create-purchase-order
receive-purchase-order
cancel-purchase-order
```

## RPC SQL

```text
receive_purchase_transaction()
```

## Resultado esperado

El administrador puede registrar compras y recibir mercancía al inventario.

---

# Fase 4: Inventario, Lotes y Caducidades

## Objetivo

Crear el núcleo de inventario confiable.

## Módulos

* Inventario físico
* Inventario disponible
* Lotes
* Caducidades
* FEFO
* Movimientos
* Ajustes
* Mermas

## Tablas principales

```text
inventory_batches
inventory_movements
inventory_adjustments
inventory_reservations
```

## Conceptos

```text
existencia_fisica
existencia_comprometida
existencia_disponible
```

## Fórmula

```text
existencia_disponible =
existencia_fisica
- apartados
- preventas
- reservas
```

## Reglas

* No se permite editar stock directamente.
* Todo cambio debe generar movimiento.
* FEFO se usa para ventas.
* Los ajustes requieren motivo.
* Las mermas quedan registradas.
* Las caducidades generan alertas.

## Edge Functions

```text
adjust-inventory
register-waste
```

## RPC SQL

```text
adjust_inventory_transaction()
```

## Resultado esperado

El sistema puede responder con confiabilidad:

```text
¿Cuál es la existencia física y disponible de este producto?
```

---

# Fase 5: Clientes, Solicitudes y Preventas

## Objetivo

Capturar demanda real antes de comprar o vender.

## Módulos

* Clientes
* Solicitudes de clientes
* Preventas
* Apartados
* Existencia comprometida

## Tablas principales

```text
customers
customer_requests
preorders
preorder_items
inventory_reservations
```

## Reglas

* Cliente obligatorio para crédito, preventa o apartado.
* Cliente opcional para venta de contado.
* Las solicitudes alimentan sugerencias de compra.
* Las preventas pueden comprometer existencia disponible.
* La existencia física y disponible deben mostrarse separadas.

## Resultado esperado

El sistema puede detectar productos con demanda pendiente.

---

# Fase 6: POS y Ventas

## Objetivo

Crear la operación principal de ventas.

## Módulos

* Punto de venta
* Captura por código de barras
* Captura por SKU
* Búsqueda por nombre
* Descuentos autorizados
* Pago contado
* Pago mixto
* Crédito

## Tablas principales

```text
sales
sale_items
sale_item_batches
payments
discount_authorizations
```

## Métodos de pago

```text
cash
card
transfer
mixed
credit
```

## Reglas

* La venta descuenta inventario mediante FEFO.
* La venta usa existencia disponible, no solo existencia física.
* Crédito requiere cliente.
* Crédito requiere autorización.
* Descuento requiere autorización.
* Cada venta genera movimiento de inventario.
* Cada venta genera movimiento financiero.
* Cada venta queda auditada.

## Edge Functions

```text
create-sale
authorize-discount
cancel-sale
```

## RPC SQL

```text
create_sale_transaction()
cancel_sale_transaction()
```

## Resultado esperado

El cajero puede vender productos sin romper inventario ni caja.

---

# Fase 7: Caja

## Objetivo

Controlar apertura, operación y cierre de caja.

## Módulos

* Apertura de caja
* Cierre de caja
* Efectivo inicial
* Efectivo contado
* Diferencias
* Ventas por cajero

## Tablas principales

```text
cash_sessions
cash_movements
```

## Reglas

* El cajero debe abrir caja antes de vender.
* El cajero debe cerrar caja al finalizar.
* Cada venta se liga a una sesión de caja.
* El cierre calcula diferencias.
* El administrador puede revisar cierres.

## Edge Functions

```text
open-cash-session
close-cash-session
```

## RPC SQL

```text
close_cash_session_transaction()
```

## Resultado esperado

El administrador puede saber cuánto se vendió y cuánto efectivo debe existir.

---

# Fase 8: Crédito y Abonos

## Objetivo

Controlar saldos pendientes de clientes.

## Módulos

* Ventas a crédito
* Abonos
* Estado de cuenta
* Saldos pendientes

## Tablas principales

```text
customer_balances
customer_payments
```

## Estados

```text
pending
partial
paid
cancelled
```

## Reglas

* Toda venta a crédito requiere cliente.
* Todo abono disminuye saldo.
* Todo abono queda ligado a cliente y venta.
* Los saldos pendientes aparecen en dashboard.
* Los abonos aparecen en reportes.

## Edge Functions

```text
register-payment
```

## RPC SQL

```text
register_customer_payment_transaction()
```

## Resultado esperado

El sistema permite saber quién debe dinero y cuánto debe.

---

# Fase 9: Devoluciones y Cancelaciones

## Objetivo

Permitir revertir operaciones sin borrar historial.

## Módulos

* Cancelación total
* Devolución parcial
* Devolución a inventario
* Merma
* Garantía
* Desecho

## Tablas principales

```text
returns
return_items
```

## Reglas

* Cancelaciones requieren autorización.
* Devoluciones requieren autorización.
* El producto devuelto puede regresar a inventario o ir a merma.
* Nunca se borra una venta.
* Las reversión genera movimientos inversos.

## Edge Functions

```text
return-sale-item
cancel-sale
```

## RPC SQL

```text
return_sale_item_transaction()
```

## Resultado esperado

Las devoluciones no rompen inventario, caja ni auditoría.

---

# Fase 10: Dashboard y Reportes

## Objetivo

Dar visibilidad rápida al administrador.

## Dashboard

Debe mostrar:

* Ventas de hoy
* Ventas de la semana
* Ventas del mes
* Créditos pendientes
* Stock bajo
* Productos agotados
* Productos próximos a caducar
* Solicitudes de clientes
* Sugerencias de compra

## Reportes MVP

```text
sales_report
cash_report
inventory_report
expiration_report
credit_report
purchase_report
```

## Reglas

* Reportes filtrables por empresa.
* Reportes filtrables por sucursal.
* Reportes exportables CSV/Excel.
* Cajero no ve reportes administrativos.

## Resultado esperado

El administrador responde rápidamente:

```text
¿Cuánto vendí?
¿Qué tengo?
¿Qué debo comprar?
¿Quién me debe?
```

---

# Fase 11: Auditoría

## Objetivo

Registrar acciones críticas.

## Tabla principal

```text
audit_logs
```

## Eventos auditados

* Descuentos autorizados
* Créditos autorizados
* Ventas canceladas
* Devoluciones
* Ajustes de inventario
* Cierres de caja
* Cambios de precio
* Cambios de permisos

## Resultado esperado

Toda acción sensible puede rastrearse.

---

# Fase 12: Exportaciones

## Objetivo

Permitir al administrador extraer información.

## Exportaciones MVP

* Productos
* Inventario
* Ventas
* Clientes
* Compras
* Créditos

## Formatos

* CSV
* Excel

## Resultado esperado

El cliente conserva control sobre su información.

---

# 5. Orden de Prioridad del MVP

El orden recomendado de construcción es:

```text
1. Auth + empresas + sucursales
2. Productos + variantes
3. Compras + recepción
4. Inventario + lotes + caducidades
5. Clientes + solicitudes
6. POS + ventas
7. Caja
8. Crédito + abonos
9. Dashboard
10. Reportes
11. Auditoría
12. Exportaciones
```

---

# 6. Modelo Inicial de Tablas

## Seguridad y SaaS

```text
profiles
companies
branches
company_users
branch_users
subscription_plans
company_subscriptions
```

## Catálogo

```text
brands
categories
units
products
product_variants
```

## Compras

```text
suppliers
purchase_orders
purchase_order_items
purchase_receipts
purchase_receipt_items
```

## Inventario

```text
inventory_batches
inventory_movements
inventory_adjustments
inventory_reservations
```

## Clientes y Demanda

```text
customers
customer_requests
preorders
preorder_items
```

## Ventas

```text
sales
sale_items
sale_item_batches
payments
discount_authorizations
```

## Caja

```text
cash_sessions
cash_movements
```

## Crédito

```text
customer_balances
customer_payments
```

## Devoluciones

```text
returns
return_items
```

## Auditoría

```text
audit_logs
```

---

# 7. Edge Functions Iniciales

```text
create-sale
cancel-sale
return-sale-item
authorize-discount
open-cash-session
close-cash-session
create-purchase-order
receive-purchase-order
adjust-inventory
register-payment
register-waste
```

---

# 8. RPC SQL Iniciales

```text
create_sale_transaction()
cancel_sale_transaction()
return_sale_item_transaction()
receive_purchase_transaction()
adjust_inventory_transaction()
register_customer_payment_transaction()
close_cash_session_transaction()
```

---

# 9. Pantallas Principales

## Administrador

```text
Dashboard
Productos
Inventario
Compras
Clientes
Créditos
Caja
Reportes
Configuración
Usuarios
```

## Cajero

```text
Abrir Caja
POS
Registrar Pago
Consultar Venta
Cerrar Caja
```

---

# 10. Roadmap

## MVP

* Inventario
* Compras
* POS
* Caja
* Crédito
* Reportes

## V1.5

* Transferencias entre sucursales
* Catálogo global opcional
* Tickets PDF o térmicos

## V2

* CFDI
* Pasarela de pago
* Promociones avanzadas
* Notificaciones WhatsApp/correo

## V3

* Recomendaciones inteligentes de compra
* Pronóstico de demanda
* Integraciones externas

---

# 11. Riesgos Técnicos

## Riesgo 1: Lógica crítica en frontend

Mitigación:

```text
Toda lógica sensible debe estar en Edge Functions + RPC.
```

## Riesgo 2: Inventario inconsistente

Mitigación:

```text
Movimientos obligatorios.
Transacciones SQL.
Auditoría.
```

## Riesgo 3: RLS mal configurado

Mitigación:

```text
Pruebas de aislamiento por empresa.
Pruebas de permisos por rol.
```

## Riesgo 4: Alcance excesivo

Mitigación:

```text
No incluir CFDI, pasarelas, catálogo global ni transferencias en MVP.
```

---

# 12. Criterio de Finalización del MVP

El MVP se considera listo cuando:

* Un administrador puede configurar empresa y sucursal.
* Puede crear productos con variantes.
* Puede registrar compras.
* Puede recibir mercancía con lotes y caducidad.
* Puede consultar existencia física y disponible.
* Puede vender desde POS.
* Puede abrir y cerrar caja.
* Puede registrar crédito y abonos.
* Puede ver ventas del día, semana y mes.
* Puede ver stock bajo, agotados y próximos a caducar.
* Puede exportar información básica.
* Toda operación crítica queda auditada.

---

# 13. Principio Final de Implementación

Cada módulo deberá preservar la siguiente regla:

```text
Ninguna operación debe dejar dinero, inventario o cobranza en estado inconsistente.
```
