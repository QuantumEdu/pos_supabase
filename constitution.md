# constitution.md

## POS SaaS para Suplementos, Vitaminas y Nutracéuticos

### Versión

1.0

---

# Propósito

El sistema existe para proporcionar una fuente confiable de información comercial, inventario y cobranza para empresas dedicadas a la venta de suplementos, vitaminas, nutracéuticos y productos relacionados.

La prioridad principal es garantizar la integridad del inventario, la trazabilidad de las operaciones y la visibilidad del desempeño comercial.

---

# Principio 1: El Inventario es la Fuente de Verdad

La existencia de inventario es el activo operativo más importante del sistema.

Toda existencia mostrada deberá poder explicarse mediante eventos registrados.

La existencia nunca será modificada directamente.

Toda modificación deberá originarse por:

* Compras
* Recepciones
* Ventas
* Devoluciones
* Ajustes
* Mermas
* Caducidades
* Transferencias (cuando existan)

---

# Principio 2: Existencia Física y Existencia Disponible son Diferentes

El sistema deberá distinguir entre:

* Existencia física
* Existencia comprometida
* Existencia disponible

La existencia disponible será la utilizada para operaciones de venta.

La existencia disponible deberá considerar:

* Apartados
* Preventas
* Solicitudes comprometidas
* Reservas futuras

---

# Principio 3: Toda Operación Crítica Debe Ser Trazable

Toda operación que afecte dinero, inventario o cobranza deberá generar evidencia auditable.

El sistema deberá registrar:

* Usuario responsable
* Fecha y hora
* Empresa
* Sucursal
* Operación realizada

Ninguna operación crítica deberá desaparecer sin dejar historial.

---

# Principio 4: Ninguna Operación Financiera Debe Perderse

Las operaciones relacionadas con:

* Ventas
* Créditos
* Abonos
* Descuentos
* Caja

deberán conservarse permanentemente.

Las cancelaciones deberán registrarse mediante reversión controlada y nunca mediante eliminación física de información.

---

# Principio 5: La Demanda es Tan Importante Como el Inventario

El sistema deberá registrar no solamente lo que existe, sino también lo que los clientes desean adquirir.

Las decisiones de compra deberán considerar:

* Solicitudes de clientes
* Preventas
* Productos agotados
* Productos más vendidos
* Existencias disponibles

---

# Principio 6: El Sistema Debe Ayudar a Tomar Decisiones

El objetivo no es únicamente registrar operaciones.

El sistema deberá facilitar la toma de decisiones mediante:

* Ventas diarias
* Ventas semanales
* Ventas mensuales
* Productos más vendidos
* Productos agotados
* Productos próximos a caducar
* Créditos pendientes
* Sugerencias de compra

---

# Principio 7: Simplicidad Operativa

Las operaciones diarias deberán requerir el menor número posible de pasos.

Las pantallas deberán optimizarse para:

* Administradores
* Cajeros

La complejidad técnica nunca deberá trasladarse al usuario final.

---

# Principio 8: Multiempresa por Diseño

Toda información operativa pertenece a una empresa.

El aislamiento de información entre empresas es obligatorio.

Ningún usuario podrá visualizar información de empresas para las que no tenga autorización explícita.

---

# Principio 9: Seguridad por Defecto

Las operaciones sensibles deberán protegerse mediante:

* Roles
* Permisos
* Auditoría
* Autorizaciones explícitas

Las acciones de alto impacto requerirán validación adicional cuando corresponda.

Ejemplos:

* Descuentos
* Créditos
* Cancelaciones
* Ajustes de inventario

---

# Principio 10: Consistencia Antes Que Conveniencia

Cuando exista conflicto entre velocidad de implementación y consistencia de datos:

La consistencia deberá prevalecer.

Cuando exista conflicto entre facilidad operativa y trazabilidad:

La trazabilidad deberá prevalecer.

Cuando exista conflicto entre flexibilidad y confiabilidad:

La confiabilidad deberá prevalecer.

---

# Principio 11: Operaciones Transaccionales

Las operaciones críticas deberán ejecutarse de manera atómica.

Una operación deberá completarse completamente o revertirse completamente.

No se permitirán estados intermedios inconsistentes.

Ejemplos:

* Venta
* Recepción de mercancía
* Abono
* Ajuste de inventario
* Devolución

---

# Principio 12: Evolución Modular

El sistema deberá crecer mediante módulos independientes.

El núcleo funcional estará compuesto por:

* Productos
* Inventario
* Compras
* Ventas
* Caja
* Clientes
* Créditos

Las funcionalidades futuras deberán incorporarse sin comprometer la estabilidad del núcleo.

---

# Definición de Éxito

Un usuario debe poder responder en menos de un minuto:

* ¿Cuánto vendí hoy?
* ¿Cuánto vendí esta semana?
* ¿Cuánto vendí este mes?
* ¿Qué productos están por agotarse?
* ¿Qué productos están por caducar?
* ¿Qué clientes me deben dinero?
* ¿Cuál es la existencia disponible real de un producto?

Si estas respuestas son correctas y confiables, el sistema cumple su propósito.
