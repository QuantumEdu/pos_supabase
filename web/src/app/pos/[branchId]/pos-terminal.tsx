"use client";

import { createClient } from "@/lib/supabase-client";
import {
  FunctionsFetchError,
  FunctionsHttpError,
  FunctionsRelayError,
} from "@supabase/supabase-js";
import { startTransition, useDeferredValue, useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";

type BranchSession = {
  id: string;
  opened_at: string;
  opening_amount: number;
  expected_cash_amount: number;
};

type SellableVariant = {
  id: string;
  name: string;
  sku: string | null;
  productName: string;
  stock: number;
  price: number | null;
  currency: string;
};

type SupportedCustomer = {
  id: string;
  name: string;
  phone: string | null;
  email: string | null;
  creditLimit: number | null;
  outstandingAmount: number;
  balances: Array<{
    id: string;
    saleId: string;
    saleNumber: number | null;
    totalAmount: number;
    paidAmount: number;
    remainingAmount: number;
    status: string;
    createdAt: string;
  }>;
};

type CancelableSale = {
  id: string;
  saleNumber: number;
  total: number;
  status: string;
  createdAt: string;
  customerName: string | null;
};

type ReturnableSaleItem = {
  id: string;
  saleId: string;
  saleNumber: number | null;
  createdAt: string | null;
  variantId: string;
  quantity: number;
  unitPrice: number;
  variantName: string;
  productName: string;
  batches: Array<{
    id: string;
    quantity: number;
  }>;
};

type SaleResult = {
  sale_id: string;
  sale_number: number;
  status: string;
  subtotal: number;
  discount_amount: number;
  tax_amount: number;
  total: number;
  cash_session_id: string;
};

type CashSessionResult = {
  cash_session_id: string;
  movement_id: string;
  status: "open";
  expected_cash_amount: number;
};

type CloseCashSessionResult = {
  cash_session_id: string;
  status: "closed";
  expected_cash_amount: number;
  counted_cash_amount: number;
  difference_amount: number;
};

type ManualCashMovementResult = {
  cash_session_id: string;
  movement_id: string;
  movement_type: "manual_cash_in" | "manual_cash_out";
  expected_cash_amount: number;
};

type RegisterPaymentResult = {
  payment_id: string;
  balance_id: string;
  amount_paid: number;
  new_paid_amount: number;
  new_remaining_amount: number;
  new_status: "pending" | "partial" | "paid";
};

type CancelSaleResult = {
  sale_id: string;
  status: "cancelled";
  reversed_items: number;
};

type ReturnSaleItemResult = {
  return_id: string;
  status: string;
  total_amount: number;
  items_count: number;
};

type EdgeFunctionResult<T> = {
  success: boolean;
  data?: T;
  error?: {
    code: string;
    message: string;
  };
};

type CartLine = {
  variantId: string;
  name: string;
  productName: string;
  unitPrice: number;
  quantity: number;
  stock: number;
};

const paymentMethods = [
  { value: "cash", label: "Efectivo" },
  { value: "card", label: "Tarjeta" },
  { value: "transfer", label: "Transferencia" },
  { value: "credit", label: "Crédito" },
] as const;

const movementTypes = [
  { value: "manual_cash_in", label: "Entrada de efectivo" },
  { value: "manual_cash_out", label: "Salida de efectivo" },
] as const;

export function PosTerminal({
  branchId,
  currentUserRole,
  sessions,
  variants,
  customers,
  sales,
  returnableItems,
}: {
  branchId: string;
  currentUserRole?: string;
  sessions: BranchSession[];
  variants: SellableVariant[];
  customers: SupportedCustomer[];
  sales: CancelableSale[];
  returnableItems: ReturnableSaleItem[];
}) {
  const router = useRouter();
  const supabase = createClient();

  const [search, setSearch] = useState("");
  const [historySearch, setHistorySearch] = useState("");
  const deferredSearch = useDeferredValue(search);
  const deferredHistorySearch = useDeferredValue(historySearch);
  const [openingAmount, setOpeningAmount] = useState("100");
  const [paymentMethod, setPaymentMethod] = useState<(typeof paymentMethods)[number]["value"]>("cash");
  const [selectedCustomerId, setSelectedCustomerId] = useState("");
  const [selectedBalanceId, setSelectedBalanceId] = useState("");
  const [selectedSaleId, setSelectedSaleId] = useState("");
  const [selectedReturnItemId, setSelectedReturnItemId] = useState("");
  const [selectedSessionId, setSelectedSessionId] = useState(sessions[0]?.id ?? "");
  const [countedCashAmount, setCountedCashAmount] = useState("");
  const [movementType, setMovementType] = useState<(typeof movementTypes)[number]["value"]>("manual_cash_in");
  const [movementAmount, setMovementAmount] = useState("");
  const [movementReason, setMovementReason] = useState("");
  const [abonoAmount, setAbonoAmount] = useState("");
  const [abonoMethod, setAbonoMethod] = useState<"cash" | "card" | "transfer">("cash");
  const [abonoReference, setAbonoReference] = useState("");
  const [cancelReason, setCancelReason] = useState("");
  const [returnQty, setReturnQty] = useState("");
  const [returnDestination, setReturnDestination] = useState<
    "inventario" | "merma" | "garantia" | "desecho"
  >("inventario");
  const [returnReason, setReturnReason] = useState("");
  const [cart, setCart] = useState<CartLine[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [openingSession, setOpeningSession] = useState(false);
  const [closingSession, setClosingSession] = useState(false);
  const [recordingMovement, setRecordingMovement] = useState(false);
  const [registeringPayment, setRegisteringPayment] = useState(false);
  const [cancellingSale, setCancellingSale] = useState(false);
  const [returningItem, setReturningItem] = useState(false);
  const [submittingSale, setSubmittingSale] = useState(false);

  const activeSessionId = selectedSessionId || sessions[0]?.id || "";
  const activeSession = sessions.find((session) => session.id === activeSessionId) ?? sessions[0];
  const isAdmin = currentUserRole === "admin";
  const selectedCustomer = customers.find((customer) => customer.id === selectedCustomerId);
  const selectedBalance = selectedCustomer?.balances.find(
    (balance) => balance.id === selectedBalanceId,
  );
  const selectedSale = sales.find((sale) => sale.id === selectedSaleId);
  const selectedReturnItem = returnableItems.find((item) => item.id === selectedReturnItemId);

  const filteredVariants = variants.filter((variant) => {
    const term = deferredSearch.trim().toLowerCase();
    if (!term) return true;

    return (
      variant.name.toLowerCase().includes(term) ||
      variant.productName.toLowerCase().includes(term) ||
      variant.sku?.toLowerCase().includes(term)
    );
  });

  const filteredSales = sales.filter((sale) => {
    const term = deferredHistorySearch.trim().toLowerCase();
    if (!term) return true;

    return (
      String(sale.saleNumber).includes(term) ||
      (sale.customerName ?? "").toLowerCase().includes(term) ||
      new Date(sale.createdAt).toLocaleString("es-MX").toLowerCase().includes(term)
    );
  });

  const filteredReturnableItems = returnableItems.filter((item) => {
    const term = deferredHistorySearch.trim().toLowerCase();
    if (!term) return true;

    return (
      String(item.saleNumber ?? "").includes(term) ||
      item.productName.toLowerCase().includes(term) ||
      item.variantName.toLowerCase().includes(term) ||
      (item.createdAt
        ? new Date(item.createdAt).toLocaleString("es-MX").toLowerCase().includes(term)
        : false)
    );
  });

  const roleHint = isAdmin
    ? "Administrador: podés registrar abonos y devoluciones."
    : "Cajero: venta, caja y cancelación propia habilitadas. Abonos y devoluciones requieren administrador.";

  const subtotal = cart.reduce(
    (acc, item) => acc + item.unitPrice * item.quantity,
    0,
  );

  async function openCashSession() {
    setError(null);
    setSuccess(null);
    setOpeningSession(true);

    try {
      const amount = Number(openingAmount);
      const { data, error } = await supabase.functions.invoke<EdgeFunctionResult<CashSessionResult>>(
        "cash-session/open-session",
        {
          body: {
            branch_id: branchId,
            opening_amount: amount,
          },
        },
      );

      if (error) {
        throw await normalizeFunctionError(error);
      }

      if (!data?.success || !data.data) {
        throw new Error(data?.error?.message ?? "No se pudo abrir la caja");
      }

      setSuccess("Caja abierta correctamente.");
      startTransition(() => {
        router.refresh();
      });
    } catch (err) {
      setError(err instanceof Error ? err.message : "No se pudo abrir la caja");
    } finally {
      setOpeningSession(false);
    }
  }

  async function submitSale() {
    if (cart.length === 0) {
      setError("Agregá al menos un producto antes de cobrar.");
      return;
    }

    if (paymentMethod === "credit" && !selectedCustomerId) {
      setError("Seleccioná un cliente antes de registrar una venta a crédito.");
      return;
    }

    setError(null);
    setSuccess(null);
    setSubmittingSale(true);

    try {
      const { data, error } = await supabase.functions.invoke<EdgeFunctionResult<SaleResult>>(
        "pos-sales/create-sale",
        {
          body: {
            branch_id: branchId,
            customer_id: selectedCustomerId || undefined,
            items: cart.map((item) => ({
              variant_id: item.variantId,
              quantity: item.quantity,
              unit_price: item.unitPrice,
              line_total: item.unitPrice * item.quantity,
              discount_percent: 0,
              discount_amount: 0,
              tax_percent: 0,
              tax_amount: 0,
              is_manual_price: false,
            })),
            payments: [
              {
                payment_method: paymentMethod,
                amount: subtotal,
              },
            ],
          },
        },
      );

      if (error) {
        throw await normalizeFunctionError(error);
      }

      if (!data?.success || !data.data) {
        throw new Error(data?.error?.message ?? "No se pudo registrar la venta");
      }

      setCart([]);
      setSuccess(`Venta #${data.data.sale_number} registrada por ${formatCurrency(data.data.total)}.`);
      startTransition(() => {
        router.refresh();
      });
    } catch (err) {
      setError(err instanceof Error ? err.message : "No se pudo registrar la venta");
    } finally {
      setSubmittingSale(false);
    }
  }

  async function closeCashSession() {
    if (!activeSession) {
      setError("No hay una caja seleccionada para cerrar.");
      return;
    }

    setError(null);
    setSuccess(null);
    setClosingSession(true);

    try {
      const amount = Number(countedCashAmount);
      const { data, error } = await supabase.functions.invoke<
        EdgeFunctionResult<CloseCashSessionResult>
      >("cash-session/close-session", {
        body: {
          cash_session_id: activeSession.id,
          counted_cash_amount: amount,
        },
      });

      if (error) {
        throw await normalizeFunctionError(error);
      }

      if (!data?.success || !data.data) {
        throw new Error(data?.error?.message ?? "No se pudo cerrar la caja");
      }

      setCart([]);
      setCountedCashAmount("");
      setSuccess(
        `Caja cerrada. Diferencia final: ${formatCurrency(data.data.difference_amount)}.`,
      );
      startTransition(() => {
        router.refresh();
      });
    } catch (err) {
      setError(err instanceof Error ? err.message : "No se pudo cerrar la caja");
    } finally {
      setClosingSession(false);
    }
  }

  async function registerPayment() {
    if (!selectedCustomer) {
      setError("Seleccioná un cliente antes de registrar un abono.");
      return;
    }

    if (!selectedBalance) {
      setError("Seleccioná un saldo pendiente antes de registrar un abono.");
      return;
    }

    setError(null);
    setSuccess(null);
    setRegisteringPayment(true);

    try {
      const amount = Number(abonoAmount);
      const { data, error } = await supabase.functions.invoke<
        EdgeFunctionResult<RegisterPaymentResult>
      >("register-payment", {
        body: {
          balance_id: selectedBalance.id,
          amount,
          payment_method: abonoMethod,
          reference: abonoReference || undefined,
        },
      });

      if (error) {
        throw await normalizeFunctionError(error);
      }

      if (!data?.success || !data.data) {
        throw new Error(data?.error?.message ?? "No se pudo registrar el abono");
      }

      setAbonoAmount("");
      setAbonoReference("");
      setSuccess(
        `Abono registrado. Restante: ${formatCurrency(data.data.new_remaining_amount)}.`,
      );
      startTransition(() => {
        router.refresh();
      });
    } catch (err) {
      setError(err instanceof Error ? err.message : "No se pudo registrar el abono");
    } finally {
      setRegisteringPayment(false);
    }
  }

  async function cancelSale() {
    if (!selectedSale) {
      setError("Seleccioná una venta activa antes de cancelarla.");
      return;
    }

    setError(null);
    setSuccess(null);
    setCancellingSale(true);

    try {
      const { data, error } = await supabase.functions.invoke<
        EdgeFunctionResult<CancelSaleResult>
      >("pos-sales/cancel-sale", {
        body: {
          sale_id: selectedSale.id,
          reason: cancelReason || undefined,
        },
      });

      if (error) {
        throw await normalizeFunctionError(error);
      }

      if (!data?.success || !data.data) {
        throw new Error(data?.error?.message ?? "No se pudo cancelar la venta");
      }

      setSelectedSaleId("");
      setCancelReason("");
      setSuccess(`Venta #${selectedSale.saleNumber} cancelada correctamente.`);
      startTransition(() => {
        router.refresh();
      });
    } catch (err) {
      setError(err instanceof Error ? err.message : "No se pudo cancelar la venta");
    } finally {
      setCancellingSale(false);
    }
  }

  async function submitReturn() {
    if (!selectedReturnItem) {
      setError("Seleccioná una línea vendida antes de registrar una devolución.");
      return;
    }

    const qty = Number(returnQty);
    if (!qty || qty <= 0) {
      setError("Ingresá una cantidad válida para devolver.");
      return;
    }

    const allocatedBatches = allocateReturnBatches(qty, selectedReturnItem.batches);
    if (!allocatedBatches) {
      setError("La cantidad supera los lotes trazados de la venta seleccionada.");
      return;
    }

    setError(null);
    setSuccess(null);
    setReturningItem(true);

    try {
      const { data, error } = await supabase.functions.invoke<
        EdgeFunctionResult<ReturnSaleItemResult>
      >("return-sale-item", {
        body: {
          branch_id: branchId,
          sale_id: selectedReturnItem.saleId,
          type: "partial",
          reason: returnReason || undefined,
          items: [
            {
              sale_item_id: selectedReturnItem.id,
              variant_id: selectedReturnItem.variantId,
              qty,
              destination: returnDestination,
              unit_price: selectedReturnItem.unitPrice,
              batches: allocatedBatches.map((batch) => ({
                original_batch_id: batch.id,
                qty: batch.quantity,
              })),
            },
          ],
        },
      });

      if (error) {
        throw await normalizeFunctionError(error);
      }

      if (!data?.success || !data.data) {
        throw new Error(data?.error?.message ?? "No se pudo registrar la devolución");
      }

      setSelectedReturnItemId("");
      setReturnQty("");
      setReturnReason("");
      setReturnDestination("inventario");
      setSuccess(
        `Devolución registrada por ${formatCurrency(data.data.total_amount)}.`,
      );
      startTransition(() => {
        router.refresh();
      });
    } catch (err) {
      setError(err instanceof Error ? err.message : "No se pudo registrar la devolución");
    } finally {
      setReturningItem(false);
    }
  }

  async function recordManualMovement() {
    if (!activeSession) {
      setError("No hay una caja seleccionada para registrar movimientos.");
      return;
    }

    setError(null);
    setSuccess(null);
    setRecordingMovement(true);

    try {
      const amount = Number(movementAmount);
      const { data, error } = await supabase.functions.invoke<
        EdgeFunctionResult<ManualCashMovementResult>
      >("cash-session/record-manual-movement", {
        body: {
          cash_session_id: activeSession.id,
          movement_type: movementType,
          amount,
          reason: movementReason || undefined,
        },
      });

      if (error) {
        throw await normalizeFunctionError(error);
      }

      if (!data?.success || !data.data) {
        throw new Error(data?.error?.message ?? "No se pudo registrar el movimiento");
      }

      setMovementAmount("");
      setMovementReason("");
      setSuccess(
        `${movementType === "manual_cash_in" ? "Entrada" : "Salida"} registrada. Nuevo esperado: ${formatCurrency(data.data.expected_cash_amount)}.`,
      );
      startTransition(() => {
        router.refresh();
      });
    } catch (err) {
      setError(
        err instanceof Error ? err.message : "No se pudo registrar el movimiento",
      );
    } finally {
      setRecordingMovement(false);
    }
  }

  function addToCart(variant: SellableVariant) {
    if (variant.price === null || variant.stock <= 0) {
      return;
    }

    const unitPrice = variant.price;

    setError(null);
    setSuccess(null);
    setCart((current) => {
      const existing = current.find((item) => item.variantId === variant.id);

      if (!existing) {
        return [
          ...current,
          {
            variantId: variant.id,
            name: variant.name,
            productName: variant.productName,
            unitPrice,
            quantity: 1,
            stock: variant.stock,
          },
        ];
      }

      if (existing.quantity >= existing.stock) {
        setError(`No podés agregar más de ${existing.stock} unidad(es) de ${existing.productName}.`);
        return current;
      }

      return current.map((item) =>
        item.variantId === variant.id
          ? { ...item, quantity: item.quantity + 1 }
          : item,
      );
    });
  }

  function updateQuantity(variantId: string, nextQuantity: number) {
    setCart((current) =>
      current
        .map((item) => {
          if (item.variantId !== variantId) {
            return item;
          }

          return {
            ...item,
            quantity: Math.max(1, Math.min(item.stock, nextQuantity)),
          };
        })
        .filter((item) => item.quantity > 0),
    );
  }

  function removeFromCart(variantId: string) {
    setCart((current) => current.filter((item) => item.variantId !== variantId));
  }

  function handleCustomerChange(nextCustomerId: string) {
    setSelectedCustomerId(nextCustomerId);
    setSelectedBalanceId("");
  }

  // ── Keyboard shortcuts ──────────────────────────────────────────────
  const searchRef = useRef<HTMLInputElement>(null);
  const submitSaleRef = useRef(submitSale);

  // Keep the ref up-to-date with the latest submitSale
  submitSaleRef.current = submitSale;

  useEffect(() => {
    function handleKeyDown(event: KeyboardEvent) {
      // Ctrl+K or / (when not in an input) → focus search
      if ((event.ctrlKey && event.key === "k") || (!event.ctrlKey && !event.metaKey && event.key === "/" && !(event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement || event.target instanceof HTMLSelectElement))) {
        event.preventDefault();
        searchRef.current?.focus();
        return;
      }

      // Escape → clear search, then clear error/success
      if (event.key === "Escape") {
        if (searchRef.current === document.activeElement && search) {
          setSearch("");
          return;
        }
        setError(null);
        setSuccess(null);
        return;
      }

      // Ctrl+Enter → submit sale
      if (event.ctrlKey && event.key === "Enter" && cart.length > 0 && !submittingSale) {
        event.preventDefault();
        submitSaleRef.current();
        return;
      }
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [search, cart, submittingSale]);

  // Auto-focus search on mount
  useEffect(() => {
    searchRef.current?.focus();
  }, []);

  return (
    <div className="grid grid-cols-1 gap-6 lg:grid-cols-[1.2fr_0.8fr]">
      <section className="rounded-2xl border bg-white p-6">
        <div className="flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
          <div>
            <h2 className="text-lg font-semibold">Terminal POS</h2>
            <p className="mt-1 text-sm text-zinc-500">
              Buscá variantes, armá el carrito y registrá la venta por Edge Function.
            </p>
            <p className="mt-2 text-sm text-zinc-400">{roleHint}</p>
          </div>
          <label className="block md:w-72">
            <span className="mb-1 block text-sm font-medium text-zinc-700">
              Buscar <kbd className="ml-1 rounded border border-zinc-300 px-1.5 py-0.5 text-[10px] font-medium text-zinc-400">/</kbd>
            </span>
            <input
              ref={searchRef}
              value={search}
              onChange={(event) => setSearch(event.target.value)}
              placeholder="SKU, producto o variante"
              className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm outline-none ring-0 focus:border-blue-500"
            />
          </label>
        </div>

        <div className="mt-6 grid grid-cols-1 gap-4 md:grid-cols-2">
          {filteredVariants.map((variant) => (
            <div key={variant.id} className="rounded-xl border border-zinc-200 p-4">
              <p className="text-xs uppercase tracking-[0.2em] text-zinc-400">
                {variant.sku ?? "Sin SKU"}
              </p>
              <h3 className="mt-2 font-semibold">{variant.productName}</h3>
              <p className="text-sm text-zinc-500">{variant.name}</p>

              <div className="mt-4 flex items-end justify-between gap-3">
                <div>
                  <p className="text-xs text-zinc-400">Disponible</p>
                  <p className="text-lg font-semibold">{variant.stock}</p>
                </div>
                <div className="text-right">
                  <p className="text-xs text-zinc-400">Precio</p>
                  <p className="text-lg font-semibold">
                    {variant.price === null
                      ? "Sin precio"
                      : `${variant.currency} ${Number(variant.price).toLocaleString("es-MX", { minimumFractionDigits: 2 })}`}
                  </p>
                </div>
              </div>

              <button
                type="button"
                onClick={() => addToCart(variant)}
                disabled={variant.price === null || variant.stock <= 0 || sessions.length === 0}
                className="mt-4 w-full rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-blue-700 disabled:cursor-not-allowed disabled:bg-zinc-200 disabled:text-zinc-500"
              >
                {sessions.length === 0
                  ? "Abrí caja para vender"
                  : variant.stock <= 0
                    ? "Sin stock"
                    : variant.price === null
                      ? "Sin precio activo"
                      : "Agregar"}
              </button>
            </div>
          ))}

          {filteredVariants.length === 0 && (
            <div className="rounded-xl border border-dashed p-6 text-sm text-zinc-500">
              No hay variantes que coincidan con la búsqueda.
            </div>
          )}
        </div>
      </section>

      <section className="space-y-6">
        <div className="rounded-2xl border bg-white p-6">
          <h2 className="text-lg font-semibold">Caja</h2>

          {sessions.length === 0 ? (
            <div className="mt-4 space-y-4">
              <p className="text-sm text-zinc-500">
                No hay una caja abierta para esta sucursal. Abrila antes de cobrar.
              </p>
              <label className="block">
                <span className="mb-1 block text-sm font-medium text-zinc-700">
                  Fondo inicial
                </span>
                <input
                  type="number"
                  min="0"
                  step="0.01"
                  value={openingAmount}
                  onChange={(event) => setOpeningAmount(event.target.value)}
                  className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-blue-500"
                />
              </label>
              <button
                type="button"
                onClick={openCashSession}
                disabled={openingSession}
                className="w-full rounded-lg bg-emerald-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-emerald-700 disabled:opacity-50"
              >
                {openingSession ? "Abriendo caja..." : "Abrir caja"}
              </button>
            </div>
          ) : (
            <div className="mt-4 space-y-3">
              <label className="block">
                <span className="mb-1 block text-sm font-medium text-zinc-700">
                  Caja activa
                </span>
                <select
                  value={activeSessionId}
                  onChange={(event) => setSelectedSessionId(event.target.value)}
                  className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-blue-500"
                >
                  {sessions.map((session) => (
                    <option key={session.id} value={session.id}>
                      {new Date(session.opened_at).toLocaleString("es-MX")}
                    </option>
                  ))}
                </select>
              </label>

              {sessions.map((session) => (
                <div
                  key={session.id}
                  className={`rounded-xl border p-4 text-sm ${
                    session.id === activeSessionId
                      ? "border-blue-300 bg-blue-50/40"
                      : "border-zinc-200"
                  }`}
                >
                  <p className="font-medium text-zinc-800">
                    Abierta {new Date(session.opened_at).toLocaleString("es-MX")}
                  </p>
                  <p className="mt-1 text-zinc-500">
                    Fondo inicial: {formatCurrency(session.opening_amount)}
                  </p>
                  <p className="text-zinc-500">
                    Efectivo esperado: {formatCurrency(session.expected_cash_amount)}
                  </p>
                </div>
              ))}

              <div className="rounded-xl border border-zinc-200 p-4">
                <h3 className="font-medium text-zinc-800">Movimiento manual</h3>
                <div className="mt-3 space-y-3">
                  <label className="block">
                    <span className="mb-1 block text-sm font-medium text-zinc-700">
                      Tipo
                    </span>
                    <select
                      value={movementType}
                      onChange={(event) =>
                        setMovementType(
                          event.target.value as (typeof movementTypes)[number]["value"],
                        )
                      }
                      className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-blue-500"
                    >
                      {movementTypes.map((type) => (
                        <option key={type.value} value={type.value}>
                          {type.label}
                        </option>
                      ))}
                    </select>
                  </label>

                  <label className="block">
                    <span className="mb-1 block text-sm font-medium text-zinc-700">
                      Monto
                    </span>
                    <input
                      type="number"
                      min="0"
                      step="0.01"
                      value={movementAmount}
                      onChange={(event) => setMovementAmount(event.target.value)}
                      className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-blue-500"
                    />
                  </label>

                  <label className="block">
                    <span className="mb-1 block text-sm font-medium text-zinc-700">
                      Motivo
                    </span>
                    <input
                      value={movementReason}
                      onChange={(event) => setMovementReason(event.target.value)}
                      placeholder="Ej. retiro bancario, cambio, ajuste"
                      className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-blue-500"
                    />
                  </label>

                  <button
                    type="button"
                    onClick={recordManualMovement}
                    disabled={recordingMovement || !activeSessionId}
                    className="w-full rounded-lg bg-zinc-900 px-4 py-2 text-sm font-medium text-white transition hover:bg-zinc-800 disabled:opacity-50"
                  >
                    {recordingMovement ? "Registrando movimiento..." : "Registrar movimiento"}
                  </button>
                </div>
              </div>

              <div className="rounded-xl border border-zinc-200 p-4">
                <h3 className="font-medium text-zinc-800">Cerrar caja</h3>
                <div className="mt-3 space-y-3">
                  <label className="block">
                    <span className="mb-1 block text-sm font-medium text-zinc-700">
                      Efectivo contado
                    </span>
                    <input
                      type="number"
                      min="0"
                      step="0.01"
                      value={countedCashAmount}
                      onChange={(event) => setCountedCashAmount(event.target.value)}
                      className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-blue-500"
                    />
                  </label>

                  {activeSession && (
                    <p className="text-sm text-zinc-500">
                      Esperado actual: {formatCurrency(activeSession.expected_cash_amount)}
                    </p>
                  )}

                  <button
                    type="button"
                    onClick={closeCashSession}
                    disabled={closingSession || !activeSessionId}
                    className="w-full rounded-lg bg-amber-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-amber-700 disabled:opacity-50"
                  >
                    {closingSession ? "Cerrando caja..." : "Cerrar caja"}
                  </button>
                </div>
              </div>
            </div>
          )}
        </div>

        <div className="rounded-2xl border bg-white p-6">
          <h2 className="text-lg font-semibold">Cobro</h2>

          <div className="mt-4 space-y-4">
            <div className="rounded-xl border border-zinc-200 p-4">
              <label className="block">
                <span className="mb-1 block text-sm font-medium text-zinc-700">
                  Cliente
                </span>
                <select
                  value={selectedCustomerId}
                  onChange={(event) => handleCustomerChange(event.target.value)}
                  className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-blue-500"
                >
                  <option value="">Público general / sin cliente</option>
                  {customers.map((customer) => (
                    <option key={customer.id} value={customer.id}>
                      {customer.name}
                    </option>
                  ))}
                </select>
              </label>

              <div className="mt-3 text-sm text-zinc-500">
                {selectedCustomer ? (
                  <>
                    <p>{selectedCustomer.phone ?? selectedCustomer.email ?? "Cliente sin contacto registrado"}</p>
                    <p className="mt-1">
                      Saldo pendiente actual: {formatCurrency(selectedCustomer.outstandingAmount)}
                    </p>
                    {selectedCustomer.creditLimit !== null && (
                      <p className="mt-1">
                        Límite de crédito: {formatCurrency(selectedCustomer.creditLimit)}
                        <span className={selectedCustomer.outstandingAmount >= selectedCustomer.creditLimit ? " ml-2 font-semibold text-red-600" : " ml-2 text-zinc-400"}>
                          ({((selectedCustomer.outstandingAmount / selectedCustomer.creditLimit) * 100).toFixed(0)}% usado)
                        </span>
                      </p>
                    )}
                    <p className="mt-1">
                      Saldos abiertos en esta sucursal: {selectedCustomer.balances.length}
                    </p>
                  </>
                ) : customers.length === 0 ? (
                  <p>
                    No hay clientes registrados para esta empresa.
                  </p>
                ) : (
                  <p>Podés vender sin cliente, salvo cuando el método de pago sea crédito.</p>
                )}
              </div>
            </div>

            <label className="block">
              <span className="mb-1 block text-sm font-medium text-zinc-700">
                Método de pago
              </span>
              <select
                value={paymentMethod}
                onChange={(event) => setPaymentMethod(event.target.value as (typeof paymentMethods)[number]["value"])}
                className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-blue-500"
              >
                {paymentMethods.map((method) => (
                  <option
                    key={method.value}
                    value={method.value}
                    disabled={method.value === "credit" && customers.length === 0}
                  >
                    {method.label}
                  </option>
                ))}
              </select>
            </label>

            {paymentMethod === "credit" && selectedCustomer && (
              <div className="rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800">
                {selectedCustomer.creditLimit !== null ? (
                  <>
                    Crédito disponible: {formatCurrency(selectedCustomer.creditLimit - selectedCustomer.outstandingAmount)}
                    {" · "}Límite: {formatCurrency(selectedCustomer.creditLimit)}
                    {" · "}Usado: {formatCurrency(selectedCustomer.outstandingAmount)}
                    {selectedCustomer.outstandingAmount >= selectedCustomer.creditLimit && (
                      <span className="ml-1 font-bold text-red-700">¡Límite agotado!</span>
                    )}
                  </>
                ) : (
                  <>Crédito sin límite definido para este cliente.</>
                )}
              </div>
            )}
            {paymentMethod === "credit" && !selectedCustomer && (
              <div className="rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800">
                El crédito exige un cliente seleccionado.
              </div>
            )}

            {isAdmin && (
              <div className="rounded-xl border border-zinc-200 p-4">
                <h3 className="font-medium text-zinc-800">Registrar abono</h3>
                <p className="mt-1 text-sm text-zinc-500">
                  Disponible solo para administradores.
                </p>

                <div className="mt-3 space-y-3">
                  <label className="block">
                    <span className="mb-1 block text-sm font-medium text-zinc-700">
                      Saldo pendiente
                    </span>
                    <select
                      value={selectedBalanceId}
                      onChange={(event) => setSelectedBalanceId(event.target.value)}
                      className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-blue-500"
                      disabled={!selectedCustomer || selectedCustomer.balances.length === 0}
                    >
                      <option value="">Seleccioná un saldo</option>
                      {selectedCustomer?.balances.map((balance) => (
                        <option key={balance.id} value={balance.id}>
                          Venta #{balance.saleNumber ?? "s/n"} · restante {formatCurrency(balance.remainingAmount)}
                        </option>
                      ))}
                    </select>
                  </label>

                  {selectedBalance && (
                    <div className="rounded-lg bg-zinc-50 p-3 text-sm text-zinc-600">
                      <p>Total: {formatCurrency(selectedBalance.totalAmount)}</p>
                      <p>Pagado: {formatCurrency(selectedBalance.paidAmount)}</p>
                      <p>Restante: {formatCurrency(selectedBalance.remainingAmount)}</p>
                    </div>
                  )}

                  <label className="block">
                    <span className="mb-1 block text-sm font-medium text-zinc-700">
                      Monto del abono
                    </span>
                    <input
                      type="number"
                      min="0"
                      step="0.01"
                      value={abonoAmount}
                      onChange={(event) => setAbonoAmount(event.target.value)}
                      className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-blue-500"
                    />
                  </label>

                  <label className="block">
                    <span className="mb-1 block text-sm font-medium text-zinc-700">
                      Método del abono
                    </span>
                    <select
                      value={abonoMethod}
                      onChange={(event) =>
                        setAbonoMethod(event.target.value as "cash" | "card" | "transfer")
                      }
                      className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-blue-500"
                    >
                      <option value="cash">Efectivo</option>
                      <option value="card">Tarjeta</option>
                      <option value="transfer">Transferencia</option>
                    </select>
                  </label>

                  <label className="block">
                    <span className="mb-1 block text-sm font-medium text-zinc-700">
                      Referencia
                    </span>
                    <input
                      value={abonoReference}
                      onChange={(event) => setAbonoReference(event.target.value)}
                      placeholder="Folio, autorización o nota"
                      className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-blue-500"
                    />
                  </label>

                  <button
                    type="button"
                    onClick={registerPayment}
                    disabled={registeringPayment || !selectedCustomer || !selectedBalanceId}
                    className="w-full rounded-lg bg-violet-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-violet-700 disabled:opacity-50"
                  >
                    {registeringPayment ? "Registrando abono..." : "Registrar abono"}
                  </button>
                </div>
              </div>
            )}

            <div className="rounded-xl border border-zinc-200 p-4">
              <h3 className="font-medium text-zinc-800">Cancelar venta</h3>
              <p className="mt-1 text-sm text-zinc-500">
                El backend solo permite cancelar ventas activas y, para cajeros, únicamente las propias.
              </p>

              <div className="mt-3 space-y-3">
                <label className="block">
                  <span className="mb-1 block text-sm font-medium text-zinc-700">
                    Buscar en historial
                  </span>
                  <input
                    value={historySearch}
                    onChange={(event) => setHistorySearch(event.target.value)}
                    placeholder="Venta, cliente, producto o fecha"
                    className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-blue-500"
                  />
                </label>

                <label className="block">
                  <span className="mb-1 block text-sm font-medium text-zinc-700">
                    Venta activa reciente
                  </span>
                  <select
                    value={selectedSaleId}
                    onChange={(event) => setSelectedSaleId(event.target.value)}
                    className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-blue-500"
                    disabled={filteredSales.length === 0}
                  >
                    <option value="">Seleccioná una venta</option>
                    {filteredSales.map((sale) => (
                      <option key={sale.id} value={sale.id}>
                        Venta #{sale.saleNumber} · {sale.customerName ?? "Público general"} · {formatCurrency(sale.total)}
                      </option>
                    ))}
                  </select>
                </label>

                {selectedSale && (
                  <div className="rounded-lg bg-zinc-50 p-3 text-sm text-zinc-600">
                    <p>Fecha: {new Date(selectedSale.createdAt).toLocaleString("es-MX")}</p>
                    <p>Cliente: {selectedSale.customerName ?? "Público general"}</p>
                    <p>Total: {formatCurrency(selectedSale.total)}</p>
                  </div>
                )}

                <label className="block">
                  <span className="mb-1 block text-sm font-medium text-zinc-700">
                    Motivo
                  </span>
                  <input
                    value={cancelReason}
                    onChange={(event) => setCancelReason(event.target.value)}
                    placeholder="Ej. error de captura, cliente desistió"
                    className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-blue-500"
                  />
                </label>

                <button
                  type="button"
                  onClick={cancelSale}
                  disabled={cancellingSale || !selectedSaleId}
                  className="w-full rounded-lg bg-rose-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-rose-700 disabled:opacity-50"
                >
                  {cancellingSale ? "Cancelando venta..." : "Cancelar venta"}
                </button>
              </div>
            </div>

            {isAdmin && (
              <div className="rounded-xl border border-zinc-200 p-4">
                <h3 className="font-medium text-zinc-800">Devolver ítem</h3>
                <p className="mt-1 text-sm text-zinc-500">
                  La devolución usa la trazabilidad real de lotes de la venta.
                </p>

                <div className="mt-3 space-y-3">
                  <label className="block">
                    <span className="mb-1 block text-sm font-medium text-zinc-700">
                      Línea vendida
                    </span>
                    <select
                    value={selectedReturnItemId}
                    onChange={(event) => setSelectedReturnItemId(event.target.value)}
                    className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-blue-500"
                    disabled={filteredReturnableItems.length === 0}
                  >
                    <option value="">Seleccioná una línea</option>
                    {filteredReturnableItems.map((item) => (
                      <option key={item.id} value={item.id}>
                        Venta #{item.saleNumber ?? "s/n"} · {item.productName} · {item.variantName} · qty {item.quantity}
                      </option>
                    ))}
                  </select>
                  </label>

                  {selectedReturnItem && (
                    <div className="rounded-lg bg-zinc-50 p-3 text-sm text-zinc-600">
                      <p>{selectedReturnItem.productName} · {selectedReturnItem.variantName}</p>
                      <p>Vendida: {selectedReturnItem.quantity} unidad(es)</p>
                      <p>Precio unitario: {formatCurrency(selectedReturnItem.unitPrice)}</p>
                      <p>Lotes trazados: {selectedReturnItem.batches.length}</p>
                    </div>
                  )}

                  <label className="block">
                    <span className="mb-1 block text-sm font-medium text-zinc-700">
                      Cantidad a devolver
                    </span>
                    <input
                      type="number"
                      min="0"
                      step="0.001"
                      value={returnQty}
                      onChange={(event) => setReturnQty(event.target.value)}
                      className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-blue-500"
                    />
                  </label>

                  <label className="block">
                    <span className="mb-1 block text-sm font-medium text-zinc-700">
                      Destino
                    </span>
                    <select
                      value={returnDestination}
                      onChange={(event) =>
                        setReturnDestination(
                          event.target.value as "inventario" | "merma" | "garantia" | "desecho",
                        )
                      }
                      className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-blue-500"
                    >
                      <option value="inventario">Inventario</option>
                      <option value="merma">Merma</option>
                      <option value="garantia">Garantía</option>
                      <option value="desecho">Desecho</option>
                    </select>
                  </label>

                  <label className="block">
                    <span className="mb-1 block text-sm font-medium text-zinc-700">
                      Motivo
                    </span>
                    <input
                      value={returnReason}
                      onChange={(event) => setReturnReason(event.target.value)}
                      placeholder="Ej. producto dañado, cambio aceptado"
                      className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-blue-500"
                    />
                  </label>

                  <button
                    type="button"
                    onClick={submitReturn}
                    disabled={returningItem || !selectedReturnItemId}
                    className="w-full rounded-lg bg-orange-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-orange-700 disabled:opacity-50"
                  >
                    {returningItem ? "Registrando devolución..." : "Registrar devolución"}
                  </button>
                </div>
              </div>
            )}

            <div className="rounded-xl bg-zinc-50 p-4">
              <div className="flex items-center justify-between text-sm">
                <span className="text-zinc-500">Items</span>
                <span className="font-medium">{cart.length}</span>
              </div>
              <div className="mt-2 flex items-center justify-between text-sm">
                <span className="text-zinc-500">Total</span>
                <span className="text-lg font-semibold">{formatCurrency(subtotal)}</span>
              </div>
            </div>

            <div className="space-y-3">
              {cart.map((item) => (
                <div key={item.variantId} className="rounded-xl border border-zinc-200 p-4">
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <p className="font-medium text-zinc-800">{item.productName}</p>
                      <p className="text-sm text-zinc-500">{item.name}</p>
                    </div>
                    <button
                      type="button"
                      onClick={() => removeFromCart(item.variantId)}
                      className="text-sm text-red-600"
                    >
                      Quitar
                    </button>
                  </div>

                  <div className="mt-3 flex items-center justify-between gap-3">
                    <div className="flex items-center gap-2">
                      <button
                        type="button"
                        onClick={() => updateQuantity(item.variantId, item.quantity - 1)}
                        className="h-8 w-8 rounded-full bg-zinc-100 text-sm"
                      >
                        -
                      </button>
                      <span className="min-w-8 text-center text-sm font-medium">{item.quantity}</span>
                      <button
                        type="button"
                        onClick={() => updateQuantity(item.variantId, item.quantity + 1)}
                        className="h-8 w-8 rounded-full bg-zinc-100 text-sm"
                      >
                        +
                      </button>
                    </div>

                    <p className="font-semibold">
                      {formatCurrency(item.unitPrice * item.quantity)}
                    </p>
                  </div>
                </div>
              ))}

              {cart.length === 0 && (
                <p className="text-sm text-zinc-500">
                  El carrito está vacío.
                </p>
              )}
            </div>

            {error && <p className="text-sm text-red-600">{error}</p>}
            {success && <p className="text-sm text-emerald-600">{success}</p>}

            <button
              type="button"
              onClick={submitSale}
              disabled={submittingSale || cart.length === 0 || sessions.length === 0}
              className="w-full rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-blue-700 disabled:cursor-not-allowed disabled:bg-zinc-200 disabled:text-zinc-500"
            >
              {submittingSale ? "Registrando venta..." : "Registrar venta"}
            </button>

            <div className="mt-3 flex flex-wrap gap-2 text-[10px] text-zinc-400">
              <kbd className="rounded border border-zinc-200 px-1.5 py-0.5 font-medium">/</kbd>
              <span>Buscar</span>
              <kbd className="rounded border border-zinc-200 px-1.5 py-0.5 font-medium">Esc</kbd>
              <span>Limpiar</span>
              <kbd className="rounded border border-zinc-200 px-1.5 py-0.5 font-medium">Ctrl+Enter</kbd>
              <span>Cobrar</span>
            </div>
          </div>
        </div>
      </section>
    </div>
  );
}

async function normalizeFunctionError(error: Error) {
  if (error instanceof FunctionsHttpError) {
    const body = (await error.context.json()) as EdgeFunctionResult<unknown>;
    return new Error(body.error?.message ?? error.message);
  }

  if (error instanceof FunctionsRelayError || error instanceof FunctionsFetchError) {
    return new Error(error.message);
  }

  return error;
}

function allocateReturnBatches(
  qty: number,
  batches: Array<{ id: string; quantity: number }>,
) {
  let remaining = qty;
  const allocation: Array<{ id: string; quantity: number }> = [];

  for (const batch of batches) {
    if (remaining <= 0) {
      break;
    }

    const take = Math.min(remaining, batch.quantity);
    if (take > 0) {
      allocation.push({ id: batch.id, quantity: take });
      remaining -= take;
    }
  }

  if (remaining > 0) {
    return null;
  }

  return allocation;
}

function formatCurrency(value: number) {
  return `$${value.toLocaleString("es-MX", { minimumFractionDigits: 2 })}`;
}
