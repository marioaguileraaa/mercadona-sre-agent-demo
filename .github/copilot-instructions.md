# Synthetic retail SRE demo repository guidance

- Preserve this visible statement in user-facing surfaces: `Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices, carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.`
- Never add real customer, personal, operational, or authentication data. Never add official logos, product photos, packaging, slogans, proprietary fonts, or copied website assets/layout.
- Keep the generic palette `#126B3A`, `#F2C94C`, `#F7FAF5`, neutral dark text, MUI icons/cards, and Segoe UI/Arial.
- Preserve the flow Stores -> Products -> Shopping Cart -> Checkout -> Order/Tracking and ensure the frontend Add control calls `POST /api/carts/{cartId}/items`.
- Keep `DEMO_CART_MEMORY_MB_PER_ADD` startup-validated from 0 through 10, default 0. Keep `DEMO_CART_MEMORY_MAX_MB` bounded at 640 by default.
- Retain memory only after a valid cart/product add. Touch pages, use a process-lifetime strong root, enforce the cap atomically, preserve successful responses at cap, and never add a reset endpoint, forced collection, unbounded loop, or uncontrolled allocation.
- Preserve structured fields `CorrelationId`, `CartId`, `StoreId`, `ProductId`, `Quantity`, `AllocationBytes`, `RetainedBytes`, `MaxRetainedBytes`, `ErrorCode`, and fictional `RootCauseClue`. Never log secrets.
- Keep backend max replicas at 1 and the `WorkingSetBytes` alert threshold at 600 MiB unless the runbook and baseline validation are deliberately updated.
- Keep Azure SRE Agent in Review/Low. The only proposed mitigation is `DEMO_CART_MEMORY_MB_PER_ADD=0`; no write occurs without explicit approval.
- Preserve least privilege, managed identities, the secure Logic App bridge contract, one-secret GitHub workflow, exact Azure context guards, and non-destructive repository configuration.
- Run API/frontend tests, Bicep build/lint, PowerShell parser/contract checks, YAML/JSON parsing, secret/legacy scans, and `git diff --check` before changes are published.
