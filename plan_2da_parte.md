# 13. Principio Final de Implementación

Cada módulo deberá preservar la siguiente regla:

```text
Ninguna operación debe dejar dinero, inventario o cobranza en estado inconsistente.
```

---

# 14. Estrategia de Base de Datos

## 14.1 Convenciones Generales

Todas las tablas operativas deberán incluir:

```text
id
company_id
created_at
updated_at
created_by
updated_by
is_active
```

Cuando aplique operación por sucursal:

```text
branch_id
```

---

## 14.2 Identificadores

Se recomienda usar UUID para entidades principales:

```text
companies
branches
products
product_variants
sales
purchase_orders
customers
```

---

## 14.3 Eliminación Lógica

No se deberán eliminar físicamente registros críticos.

Usar:

```text
is_active
deleted_at
deleted_by
```

Aplica especialmente a:

```text
products
customers
suppliers
sales
purchases
inventory_movements
cash_sessions
```

---

# 15. Estrategia de RLS

## 15.1 Regla Base

Todo acceso deberá filtrarse por:

```text
company_id
```

## 15.2 Regla por Sucursal

Para cajeros, además de empresa, deberá validarse:

```text
branch_id
```

## 15.3 Administrador

El administrador puede ver toda la información de su empresa.

## 15.4 Cajero

El cajero solo puede ver y operar:

```text
Sucursal asignada
Caja propia
Ventas propias
POS
```

No puede acceder a:

```text
Reportes administrativos
Configuración
Compras
Ajustes de inventario
Usuarios
```

---

# 16. Estrategia de Edge Functions

Las Edge Functions actuarán como frontera de seguridad para operaciones críticas.

## 16.1 Funciones MVP

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

## 16.2 Regla

Cada Edge Function deberá:

```text
1. Validar usuario
2. Validar empresa
3. Validar sucursal
4. Validar rol
5. Validar datos de entrada
6. Invocar RPC SQL
7. Registrar auditoría
8. Retornar resultado consistente
```

---

# 17. Estrategia de RPC SQL

Las funciones SQL deberán contener la lógica transaccional.

## 17.1 RPC MVP

```text
create_sale_transaction()
cancel_sale_transaction()
return_sale_item_transaction()
receive_purchase_transaction()
adjust_inventory_transaction()
register_customer_payment_transaction()
close_cash_session_transaction()
```

## 17.2 Regla de Transacción

Cada RPC deberá cumplir:

```text
BEGIN
  validar datos
  modificar tablas necesarias
  registrar movimientos
  registrar auditoría
COMMIT
```

Si ocurre error:

```text
ROLLBACK
```

---

# 18. Estrategia de Inventario

## 18.1 Inventario Físico

Representa la existencia real almacenada.

## 18.2 Inventario Comprometido

Representa productos apartados, preventas o reservas.

## 18.3 Inventario Disponible

```text
disponible = físico - comprometido
```

## 18.4 Regla Principal

El POS deberá vender contra existencia disponible, no contra existencia física.

---

# 19. Estrategia FEFO

Para productos con lote y caducidad, la venta deberá consumir primero el lote con fecha de caducidad más próxima.

Orden:

```text
1. Lote vigente con caducidad más próxima
2. Lote siguiente
3. Continuar hasta cubrir cantidad
```

No se deberán usar lotes vencidos para venta normal.

---

# 20. Estrategia de Compras

## 20.1 Pedido

Crear pedido no aumenta inventario.

## 20.2 Recepción

Recibir mercancía sí aumenta inventario.

## 20.3 Recepción Parcial

Un pedido puede quedar parcialmente recibido.

## 20.4 IVA

El IVA deberá manejarse por item.

No se recomienda dividir pedidos en:

```text
con IVA
sin IVA
```

Mejor:

```text
purchase_order_items.tax_rate
purchase_order_items.tax_amount
```

---

# 21. Estrategia de Demanda

El sistema deberá distinguir entre:

```text
Solicitud de cliente
Preventa
Apartado
Venta
```

## 21.1 Solicitud

No compromete inventario.

Sirve para decidir compras.

## 21.2 Preventa

Puede comprometer inventario futuro o pendiente.

## 21.3 Apartado

Compromete existencia disponible.

---

# 22. Estrategia de Sugerencias de Compra

La recomendación de compra deberá priorizar:

```text
1. Productos pendientes de clientes
2. Productos más vendidos con stock bajo
3. Productos agotados con ventas recientes
4. Stock bajo general
```

No se deberá comprar automáticamente.

El sistema solo sugiere.

El administrador decide.

---

# 23. Estrategia de Ventas

## 23.1 Venta de Contado

Puede ser a público general.

Cliente opcional.

## 23.2 Venta a Crédito

Cliente obligatorio.

Autorización obligatoria.

## 23.3 Venta Mixta

Puede combinar:

```text
efectivo
tarjeta
transferencia
crédito
```

## 23.4 Descuento

Requiere autorización.

Debe registrar:

```text
usuario que solicita
usuario que autoriza
motivo
monto
fecha
```

---

# 24. Estrategia de Caja

## 24.1 Apertura

El cajero debe abrir caja antes de vender.

## 24.2 Cierre

El cajero debe cerrar caja al finalizar.

## 24.3 Diferencias

El sistema deberá calcular:

```text
efectivo esperado
efectivo contado
diferencia
```

---

# 25. Estrategia de Crédito

## 25.1 Saldo Pendiente

Toda venta a crédito genera saldo pendiente.

## 25.2 Abonos

Cada abono reduce saldo.

## 25.3 Estado

Estados:

```text
pending
partial
paid
cancelled
```

---

# 26. Estrategia de Devoluciones

## 26.1 Devolución Total

Revierte toda la venta mediante movimientos controlados.

## 26.2 Devolución Parcial

Revierte solo productos seleccionados.

## 26.3 Destino del Producto

Opciones:

```text
inventario
merma
garantía
desecho
```

---

# 27. Estrategia de Auditoría

Auditar obligatoriamente:

```text
ventas canceladas
devoluciones
descuentos
créditos
abonos
ajustes de inventario
cierres de caja
cambios de precio
cambios de permisos
```

La auditoría deberá guardar:

```text
company_id
branch_id
user_id
action
entity
entity_id
old_data
new_data
created_at
```

---

# 28. Estrategia de Dashboard

El dashboard del administrador deberá responder rápidamente:

```text
¿Cuánto vendí hoy?
¿Cuánto vendí esta semana?
¿Cuánto vendí este mes?
¿Qué productos están bajos?
¿Qué productos están por caducar?
¿Qué clientes me deben?
¿Qué debo comprar?
```

---

# 29. Estrategia de Reportes

Reportes mínimos:

```text
ventas por día
ventas por semana
ventas por mes
ventas por cajero
corte de caja
inventario actual
stock bajo
caducidades
clientes con saldo
abonos recibidos
compras por proveedor
```

---

# 30. Estrategia de Exportación

Exportar en:

```text
CSV
Excel
```

Entidades exportables:

```text
productos
inventario
ventas
clientes
compras
créditos
```

---

# 31. Pantallas MVP

## Administrador

```text
Dashboard
Productos
Variantes
Inventario
Compras
Clientes
Solicitudes
Créditos
Caja
Reportes
Configuración
Usuarios
```

## Cajero

```text
Abrir caja
POS
Cobrar
Registrar venta
Consultar venta
Cerrar caja
```

---

# 32. Orden de Construcción Recomendado

```text
1. Auth
2. Empresas
3. Sucursales
4. Roles
5. Productos
6. Variantes
7. Marcas
8. Categorías
9. Unidades
10. Proveedores
11. Compras
12. Recepción
13. Lotes
14. Inventario
15. Movimientos
16. Clientes
17. Solicitudes
18. POS
19. Caja
20. Crédito
21. Abonos
22. Devoluciones
23. Dashboard
24. Reportes
25. Exportaciones
26. Auditoría
```

---

# 33. Criterios de Prueba

## Inventario

Debe poder demostrarse:

```text
existencia física
existencia comprometida
existencia disponible
movimientos que explican la existencia
```

## Ventas

Debe poder demostrarse:

```text
producto vendido
lote consumido
método de pago
cajero
sucursal
movimiento de inventario
movimiento de caja
```

## Compras

Debe poder demostrarse:

```text
pedido
recepción
lote creado
caducidad
entrada a inventario
costo histórico
```

## Crédito

Debe poder demostrarse:

```text
venta original
saldo inicial
abonos
saldo actual
estado
```

---

# 34. Criterios de Aceptación del MVP

El MVP estará listo cuando:

```text
1. El administrador pueda crear empresa y sucursal.
2. El administrador pueda crear usuarios.
3. El administrador pueda crear productos y variantes.
4. El administrador pueda registrar compras.
5. El administrador pueda recibir mercancía.
6. El sistema cree lotes con caducidad.
7. El sistema calcule existencia física y disponible.
8. El cajero pueda abrir caja.
9. El cajero pueda vender.
10. El sistema descuente inventario por FEFO.
11. El cajero pueda cerrar caja.
12. El administrador pueda ver ventas del día, semana y mes.
13. El administrador pueda ver stock bajo.
14. El administrador pueda ver próximos a caducar.
15. El administrador pueda registrar abonos.
16. El administrador pueda ver clientes con saldo.
17. El sistema registre auditoría.
18. El administrador pueda exportar información básica.
```

---

# 35. Exclusiones Técnicas del MVP

No construir en MVP:

```text
CFDI
Pasarela de pago
WhatsApp
Correo automático
Catálogo global
Transferencias entre sucursales
Promociones avanzadas
App móvil nativa
Offline mode
Integraciones externas
```

---

# 36. Roadmap Técnico

## V1

```text
Supabase-only
Vue 3
POS
Inventario
Compras
Caja
Crédito
Reportes
```

## V1.5

```text
Transferencias entre sucursales
Tickets PDF/térmico
Catálogo global opcional
```

## V2

```text
CFDI
Pasarelas de pago
Notificaciones
Promociones avanzadas
```

## V3

```text
Predicción de demanda
Recomendaciones inteligentes
Automatización de compras
Integraciones con marketplaces
```

---

# 37. Notas de Implementación

## Evitar

```text
Lógica crítica en frontend
Editar stock manualmente
Borrar ventas
Borrar compras
Permitir crédito sin cliente
Permitir descuento sin autorización
Permitir venta sin caja abierta
```

## Priorizar

```text
Consistencia
Trazabilidad
Velocidad de operación
Claridad visual
Simplicidad de permisos
```

---

# 38. Siguiente Documento

Después de este plan, debe generarse:

```text
tasks.md
```

El documento de tareas deberá transformar cada fase en acciones concretas y verificables.
