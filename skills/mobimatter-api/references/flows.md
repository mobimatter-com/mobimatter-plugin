# Flows

Every flow below assumes the client and error mapping from `api-contract.md` and
`errors.md`.

## Catalogue sync — scheduled, never a request path

`syncCatalog(known)` where `known` is `[{ productId, updated }]`.

1. `GET /api/v2/products`.
2. **If the call did not succeed, abort and return no diff.** A non-2xx, a
   transport error, or a response with no `result` array is a failed sync, not an
   empty catalogue. Returning a diff here deactivates the merchant's entire
   catalogue on a blip.
3. Otherwise diff against `known`:
   - `added` — in the response, not in `known`
   - `updated` — `updated` timestamp differs
   - `unassigned` — in `known`, absent from the response
4. Return the three sets separately. `unassigned` is not a routine diff category:
   log it at error level and route it to whatever alerting the project has.

The caller persists. `syncCatalog` writes nothing, so it imposes no schema.

**A product in `unassigned` is deactivated immediately** — one miss is enough. It
has been withdrawn and must not remain sellable. The failed-sync abort in step 2 is
what makes single-miss deactivation safe.

## Network lists — part of the same sync

`syncNetworks(products, knownListIds)`.

`GET /api/v2/products/{productId}/networks` takes a product but returns the list
identified by that product's `networkListId`, and many products share one list.

1. Collect distinct non-null `networkListId` values across the catalogue.
2. For each list not already cached, pick any one product carrying it and call the
   endpoint once.
3. Cache the result against `networkListId`.

A 2,000-product catalogue spanning 30 lists costs 30 calls, not 2,000. Re-fetch a
list only when a product's `networkListId` changes or an unseen list appears.

## Product validation — live, before charging

`validateProduct(productId)` → `GET /api/v2/products?productId=<id>`.

Present in `result` means assigned and available to this merchant right now. Empty
means neither, with no finer signal available.

Also compare the returned `wholesalePrice` against the synced value. The call
already returns the product, so this costs nothing and catches selling at a stale
margin.

## Buying an eSIM

The order of these four steps is the design. Reversing any pair makes a failure
expensive.

```
1. validateProduct(productId)        live check, before money moves
2. absent or price moved  ->         abort. Customer is NOT charged.
                                     Deactivate locally, alert the admin.
3. charge the customer               the partner's own payment provider
4. fulfillPaidOrder(ref, productId)  only once payment is captured
```

Validating before charging means an unavailable product costs the customer nothing
and the merchant no refund. Creating the MobiMatter order after charging means no
wallet authorization is held against a cart that never converts.

### `fulfillPaidOrder(ref, ...)` is resumable

`ref` is the partner's own order reference.

```
1. orderId = getOrderId(ref)
2. if orderId is null:
     orderId = POST /api/v2/order   { productId, productCategory, label: ref }
     saveOrderId(ref, orderId)      <- BEFORE completing
3. PUT /api/v2/order/complete       { orderId }
4. read orderLineItem
```

The API has no idempotency key and no lookup by merchant reference, so a crash
between create and complete would otherwise create a second order on retry —
double-charging the wallet and provisioning two eSIMs for one payment.

`getOrderId` / `saveOrderId` is a two-method interface the partner implements. Ship
an in-memory version for tests only, and say plainly in your report that a durable
implementation is required: in-memory defeats the guarantee exactly across
restarts, which is when it is needed.

`label` is portal-searchable and must not carry personal data. An internal
reference satisfies both.

**Residual risk to state, not hide:** a crash between the create returning and
`saveOrderId` landing leaves an orphan order. It expires in at least 20 minutes and
the authorization is released. No customer impact.

### Not every create failure is indeterminate

Only timeouts and 5xx leave the outcome unknown. A create that returns **402**
(wallet), **429** (out of stock) or **455** (provider down) has already been
cancelled and unreserved server-side, and returns no `orderId`. Nothing was
persisted, nothing is held, nothing needs reconciling.

Fail these straight back to the caller and refund the customer if you already
charged them. Routing them into the same indeterminate-review queue as a timeout
buries real orphans under noise that resolved itself.

### Completion outcomes

| `orderState` | Meaning |
|---|---|
| `Completed` | Done. Read `lineItemDetails`. |
| `Processing` | Not an error. KYC pending, or an async replacement in flight. |

Never retry a failed completion, and never send a compensating cancel — MobiMatter
voids and cancels automatically.

## Delayed / KYC eSIMs

`esim_delayed` is the KYC category, and the only one returning `KYC_URL`.

`PUT /api/v2/order/complete` returns `Processing` with `KYC_URL` in
`lineItemDetails`. Return this as a distinct third outcome:

```
{ status: 'kyc_required', orderId, kycUrl }
```

Not a success, not an error. A boolean return here gets misread as fulfilled.

1. Send the customer to `kycUrl`.
2. Call `sendOrderConfirmation(orderId, customer)` — MobiMatter holds the email
   until the order reaches `Completed`.
3. Completion arrives by webhook: `esim_delayed` honours `callbackUrl`.
4. If KYC is not completed within 24 hours the order is cancelled and the wallet is
   refunded. The customer has already been charged by the partner, so surface this
   as a terminal failure requiring a customer refund. Signal it; do not attempt it.

## Top-ups

1. `getEsimUsage(rootOrderId)` and check `rechargeable`. If false, do not offer
   top-ups at all.

   This gates the **listing**, not just the order. Rendering top-up options for an
   eSIM that cannot accept them leads the customer to pick one and pay, after
   which the order fails — the same charge-then-fail trap as selling a withdrawn
   product, and it happens on the screen rather than at the API.

   The check is a user action (the customer opened the top-up screen), so it obeys
   the usage rules above and is served by the same 60s cache. It is not an extra
   call on top of the ones the screen already makes.
2. Read `productFamilyId` from the original product or order.
3. `GET /api/v2/products?category=esim_addon&familyId=<id>`.
4. `POST /api/v2/order` with `productCategory: "esim_addon"` and
   `addOnOrderIdentifier` set to the **root order id**.
5. Complete as normal.

### `addOnOrderIdentifier` is always the original eSIM order

Never the latest top-up, never a previous replacement.

```
A  esim_realtime   the original purchase
B  esim_addon      addOnOrderIdentifier: A
C  esim_addon      addOnOrderIdentifier: A     <- not B
D  esim_replacement addOnOrderIdentifier: A
E  esim_addon      addOnOrderIdentifier: A     <- not D, even after replacement
```

It reads like a linked list and is not one. Give every persisted order a parent
order id column: its own id on an original purchase, copied from the parent on a
top-up or replacement. Set at write time, never reassigned. Reading it is then a
field access on any order in the chain, rather than a walk back through history
that lands on B or D above.

### `GET /order/{rootId}/linked` reconciles; it does not derive

`GET /api/v2/order/A/linked` returns `[B, C, D, E]` above. Use it to check the
stored chain against MobiMatter — find a top-up or replacement the project never
persisted (a create that timed out, a support-issued top-up), or backfill the
parent order id column on orders stored before it existed.

It is not how the purchase path finds `addOnOrderIdentifier`. That is still the
stored parent order id, read as a field. Linked orders goes the other direction —
root to children — and takes the root as input, so a purchase path that needs it
already had the answer.

## Replacements

Same shape as a top-up with `category=esim_replacement`.

Completion is **synchronous for most providers** — `PUT /order/complete` returns
`Completed` directly. 3HK is the exception and returns `Processing`. Handle both
from the same call; assume neither.

The webhook fires on completion either way, so wire `callbackUrl` on every
replacement and treat the webhook as the source of truth. The `complete` response
is an early signal, not a per-provider branch.

The original eSIM stays queryable afterwards. Keep the old order linked rather than
deleting it.

## Usage and eSIM details

`getEsimUsage(orderId)` → `GET /api/v2/provider/usage/{orderId}` (no envelope).
`getEsimInfo(orderId)` → `GET /api/v2/provider/info/{orderId}?skipLocation=true`.

Both reach the upstream provider.

- **Triggered by a user action only.** Opening eSIM details, pull-to-refresh, an
  explicit balance check. Never a scheduled sweep, a background refresh, a list-view
  prefetch, or a polling loop.
- **Cached 60 seconds per order and endpoint.** Bounds what one customer can
  generate by refreshing repeatedly — every tap is a genuine user action, so
  "event-driven" alone bounds nothing. Use the project's existing cache; fall back
  to in-process only if it has none, and say so.
- **Successes only are cached.** A cached failure would replay for 60 seconds and
  make the no-retry rule look broken to the customer.
- **Never retried.** One attempt. On failure show the last cached figures with
  their timestamp, or report usage temporarily unavailable.

Order status (`GET /api/v2/order/{orderId}`) is a MobiMatter-side read and is not
covered by these rules — it is the documented fallback once the webhook retry
window is exhausted.

## Refunds

`GET /api/v2/order/{orderId}/refund/eligibility` returns `{ isEligible, fee,
reason }`. Check before attempting. `PUT /api/v2/order/refund` is restricted and
refunds the merchant's wallet only — refunding the customer is the partner's
payment provider's job.

## Guardrail tests

Leave these in the project, against a mock that records calls. They assert ordering
and absence, which is what a happy-path test cannot.

1. No `POST /api/v2/order` is issued before payment capture in the buy path.
2. Two usage requests within 60 seconds produce one HTTP call.
3. A failed usage check produces exactly one attempt.
4. A sync whose `GET /api/v2/products` call failed produces zero deactivations.
5. A second `fulfillPaidOrder()` for the same `ref` resumes at complete and does
   not create a second order.
6. A timeout on `POST /api/v2/order` produces exactly one HTTP attempt.

Every one of these passes trivially in a happy-path test. That is why they exist.
