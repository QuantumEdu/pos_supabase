# spec.md

# SaaS POS para Suplementos, Vitaminas y Nutracéuticos

Version: 1.0

---

# 1. Resumen Ejecutivo

Sistema SaaS multiempresa orientado a la administración comercial de tiendas de suplementos, vitaminas, nutracéuticos y productos de bienestar.

El sistema proporciona:

* Control de inventario
* Compras
* Ventas POS
* Caja
* Créditos y abonos
* Caducidades
* Lotes
* Reportes
* Auditoría

El objetivo principal es proporcionar información confiable sobre inventario, ventas y cobranza.

---

# 2. Objetivos del Producto

## Objetivos Primarios

* Mantener inventario confiable
* Reducir faltantes
* Controlar productos próximos a caducar
* Facilitar compras
* Controlar créditos y cobranza
* Permitir operación rápida en punto de venta

## Objetivos Secundarios

* Facilitar crecimiento multi-sucursal
* Permitir operación SaaS multiempresa
* Generar información para toma de decisiones

---

# 3. Usuarios

## Administrador

Responsable de:

* Configuración
* Compras
* Inventario
* Clientes
* Créditos
* Reportes
* Usuarios
* Caja

## Cajero

Responsable de:

* Ventas
* Cobros
* Apertura de caja
* Cierre de caja

No puede:

* Ajustar inventario
* Registrar compras
* Cambiar precios
* Modificar usuarios

---

# 4. Alcance MVP

Incluye:

* Empresas
* Sucursales
* Usuarios
* Productos
* Variantes
* Inventario
* Compras
* Ventas
* Caja
* Créditos
* Abonos
* Reportes
* Auditoría

No incluye:

* CFDI
* Catálogo global
* Pasarelas de pago
* Transferencias entre sucursales
* Notificaciones externas
* Promociones avanzadas

---

# 5. Multiempresa

Cada empresa opera de forma aislada.

Toda entidad operativa deberá pertenecer a una empresa.

Ejemplos:

* Productos
* Clientes
* Proveedores
* Ventas
* Compras
* Inventario

Todas las consultas deberán respetar company_id.

---

# 6. Sucursales

Una empresa puede tener múltiples sucursales.

Cada sucursal mantiene:

* Inventario propio
* Caja propia
* Ventas propias
* Compras propias

Los precios son compartidos entre sucursales de la misma empresa.

---

# 7. Usuarios y Roles

## Roles MVP

### Administrador

Acceso completo.

### Cajero

Acceso restringido a:

* POS
* Cobros
* Apertura de caja
* Cierre de caja

---

# 8. Productos

## Información General

Cada producto incluye:

* Nombre
* Marca
* Categoría
* Descripción
* Estado

## Variantes

Cada variante incluye:

* SKU
* Código de barras
* Presentación
* Tamaño
* Precio
* Último costo

Ejemplos:

* Chocolate 1kg
* Chocolate 2kg
* Vainilla 1kg

---

# 9. Marcas

Entidad independiente.

Ejemplos:

* NOW Foods
* Life Extension
* Nutricost
* Universal Nutrition

---

# 10. Categorías

Ejemplos:

* Proteínas
* Creatinas
* Vitaminas
* Minerales
* Adaptógenos
* Omega 3
* Pre-entrenos

---

# 11. Unidades y Presentaciones

Ejemplos:

* Cápsulas
* Tabletas
* Gramos
* Kilogramos
* Servicios
* Mililitros

---

# 12. Compras

## Flujo

Solicitud
→ Pedido
→ Recepción
→ Inventario

## Estados

* Borrador
* Enviado
* Parcial
* Recibido
* Cancelado

## Datos

* Proveedor
* Fecha
* Forma de pago
* Subtotal
* IVA
* Total

---

# 13. Solicitudes de Clientes

Permite registrar productos solicitados.

Campos:

* Cliente
* Producto
* Cantidad
* Observaciones
* Estado

Estados:

* Pendiente
* Atendido
* Cancelado

---

# 14. Inventario

## Existencia Física

Cantidad real almacenada.

## Existencia Comprometida

Cantidad reservada.

## Existencia Disponible

Existencia física menos compromisos.

Formula:

Disponible =
Existencia Física

* Apartados
* Preventas

---

# 15. Lotes

Cada recepción puede generar lotes.

Datos:

* Lote
* Fecha recepción
* Fecha caducidad
* Cantidad
* Costo

---

# 16. Caducidades

Los productos pueden tener fecha de vencimiento.

Alertas configurables por empresa.

Ejemplos:

* 30 días
* 60 días
* 90 días

---

# 17. FEFO

First Expired First Out.

El sistema deberá consumir automáticamente:

1. Lote más próximo a vencer
2. Lote siguiente

---

# 18. Movimientos de Inventario

Tipos:

* Compra
* Venta
* Ajuste
* Merma
* Caducidad
* Devolución

Todos generan trazabilidad.

---

# 19. Ajustes

Nunca se modifica stock directamente.

Todo ajuste requiere:

* Motivo
* Usuario
* Fecha
* Comentario

---

# 20. Ventas POS

## Captura

* Código de barras
* SKU
* Búsqueda por nombre
* Catálogo visual

## Métodos de Pago

* Efectivo
* Tarjeta
* Transferencia
* Mixto
* Crédito

---

# 21. Descuentos

Requieren autorización.

Tipos:

* Porcentaje
* Importe fijo

Se registra:

* Usuario solicitante
* Usuario autorizador

---

# 22. Clientes

Campos mínimos:

* Nombre
* Teléfono
* Notas

Cliente obligatorio para:

* Crédito
* Abonos
* Preventas

---

# 23. Crédito

Permite ventas con saldo pendiente.

Estados:

* Pendiente
* Parcial
* Liquidado

---

# 24. Abonos

Datos:

* Cliente
* Venta
* Fecha
* Monto
* Método de pago

Actualizan saldo automáticamente.

---

# 25. Caja

## Apertura

* Cajero
* Fecha
* Monto inicial

## Cierre

* Ventas
* Efectivo contado
* Diferencias

---

# 26. Devoluciones

Tipos:

* Total
* Parcial

Destino:

* Inventario
* Merma
* Garantía
* Desecho

Requieren autorización.

---

# 27. Auditoría

Registrar:

* Usuario
* Empresa
* Sucursal
* Acción
* Entidad
* Fecha

Ejemplos:

* Venta cancelada
* Ajuste inventario
* Descuento autorizado

---

# 28. Dashboard Ejecutivo

## Ventas

* Hoy
* Semana
* Mes

## Inventario

* Stock bajo
* Agotados
* Próximos a caducar

## Créditos

* Pendientes
* Abonos recientes

## Compras

* Últimas compras
* Sugerencias de compra

---

# 29. Reportes MVP

## Ventas

* Diarias
* Semanales
* Mensuales
* Por cajero

## Inventario

* Existencias
* Stock bajo
* Caducidades

## Créditos

* Saldos pendientes
* Abonos

## Compras

* Por proveedor
* Por periodo

---

# 30. Exportaciones

Formatos:

* CSV
* Excel

Exportables:

* Productos
* Inventario
* Ventas
* Clientes
* Compras

---

# 31. Eventos de Negocio

## Compra Recibida

Genera:

* Lote
* Inventario
* Movimiento

## Venta Registrada

Genera:

* Movimiento inventario
* Pago
* Auditoría

## Abono Registrado

Genera:

* Movimiento financiero
* Actualización saldo

## Ajuste Inventario

Genera:

* Movimiento
* Auditoría

---

# 32. Requisitos Técnicos

Frontend:

* Vue 3
* TypeScript

Backend:

* Supabase

Servicios:

* Auth
* PostgreSQL
* RLS
* Edge Functions

Operaciones críticas:

* RPC SQL
* Transacciones

---

# 33. Requisitos No Funcionales

* Multiempresa
* Seguro por defecto
* Auditoría completa
* Operaciones transaccionales
* Escalable
* Responsive
* Alta trazabilidad

---

# 34. Roadmap Futuro

## V1.5

* Transferencias entre sucursales

## V2

* Catálogo global
* CFDI
* Pasarelas de pago

## V3

* Pronóstico de compras
* Recomendaciones inteligentes
* Automatización comercial

---

# Definición de Éxito

El sistema debe permitir responder rápidamente:

* ¿Cuánto vendí hoy?
* ¿Cuánto vendí esta semana?
* ¿Cuánto vendí este mes?
* ¿Qué productos debo comprar?
* ¿Qué productos están por agotarse?
* ¿Qué productos están por caducar?
* ¿Qué clientes me deben dinero?
* ¿Cuál es la existencia disponible real de cualquier producto?
