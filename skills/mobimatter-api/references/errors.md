# Error mapping

The API publishes exactly one error shape and no error codes:

```json
{ "statusCode": 400, "message": "..." }
```

So mapping keys on **HTTP status plus which endpoint was called**, and the API's
own `message` is always passed through. Do not invent an error-code taxonomy the
API does not have, and do not replace `message` with a guess — it is the only
specific information available.

## Success detection

A 2xx with a present `result` is success. Tolerate an `isSuccess` field if the API
returns one; the published spec does not define it, and one guide example shows it.

`GET /api/v2/provider/usage/{orderId}` has no envelope at all — a 2xx body *is* the
result.

## By status

| Status | Meaning | What to tell the caller |
|---|---|---|
| 400 | Rejected. `message` carries the reason. | Surface `message`. See per-endpoint notes below. |
| 401 / 403 | Auth, or missing elevated access | See below — these two cases look identical and are not. |
| 402 | Wallet authorization failed — insufficient balance | Top up the wallet. See below. |
| 404 | Order or product not found | For orders, check the id came from a create you persisted. |
| 429 | **Out of stock.** Not a rate limit. | Do not back off and retry — stock is not a quota. See below. |
| 455 | Product source unavailable — the upstream provider is down | Non-standard code. See below. |
| 5xx | Upstream fault | Never auto-retry a write. See below. |
| timeout | Outcome unknown | Never auto-retry. See below. |

## Trust the HTTP status, not the body

The `statusCode` field in the error body does not always match the HTTP status of
the response. A 402 arrives with `"statusCode": 400` in its body.

Key all mapping on the HTTP status. The body's `statusCode` is decoration.

## 402, 429 and 455 are clean, terminal failures

These three are the only write failures with a **known** outcome: no `orderId` is
returned, and no wallet authorization is left held.

So unlike a timeout or 5xx, they need no manual review and no indeterminate state:
fail the fulfilment immediately, refund the customer if you already charged them,
and move on. Do not mark the reference for reconciliation — there is nothing to
reconcile.

## Always generate a typed error model

Never let raw status codes leak into calling code. `if (status === 455)` at a call
site is unreadable and unsearchable, and `429` in particular reads as a rate limit
to every developer who has met it anywhere else.

Generate one error type and one closed set of reasons, and map at the client
boundary so nothing downstream sees a number. Shape, in TypeScript — translate
idiomatically per stack (a `str` `Enum` plus a dataclass in Python, an enum plus an
exception class in PHP):

```ts
export enum MobiMatterErrorReason {
  InsufficientBalance  = 'insufficient_balance',   // 402
  OutOfStock           = 'out_of_stock',           // 429 — stock, not throttling
  ProviderUnavailable  = 'provider_unavailable',   // 455
  ProductUnavailable   = 'product_unavailable',    // 400 — withdrawn or unassigned
  InvalidTopUpTarget   = 'invalid_topup_target',   // 400 — addOnOrderIdentifier / family
  NotEligible          = 'not_eligible',           // 400 — provider eligibility check
  InvalidRequest       = 'invalid_request',        // 400 — everything else
  NotFound             = 'not_found',              // 404
  Unauthorized         = 'unauthorized',           // 401/403 on a public endpoint
  AccessDenied         = 'access_denied',          // 401/403 on a restricted endpoint
  Indeterminate        = 'indeterminate',          // timeout or 5xx — outcome unknown
}

export interface MobiMatterError {
  reason: MobiMatterErrorReason;
  message: string;        // the API's own message, verbatim, never replaced
  status: number | null;  // null on timeout
  endpoint: string;       // needed to tell Unauthorized from AccessDenied
  terminal: boolean;      // order already cancelled, nothing to reconcile
}
```

This is the one closed enum in the generated code. It is safe to close because you
own it — it is your classification of the API's behaviour, not a mirror of an API
field. `productCategory` stays an open `string` for exactly the opposite reason.

`terminal` is `true` for every reason except `Indeterminate`. It is the field
fulfilment code branches on, and keeping it on the error means no call site has to
remember which codes clean up after themselves.

**`reason` is derived from status plus endpoint. Only the 400 sub-reasons involve
reading `message`**, because 400 is the one status the API overloads. Treat that
classification as a hint: keep the match loose, default to `InvalidRequest` rather
than guessing, and always surface `message` alongside. Never build a code taxonomy
on `message` for any other status, and never show `reason` to an end user in place
of `message` — it is coarser than what the API actually said.

## Auth failures need two different messages

A merchant without elevated access calling a restricted endpoint gets the same 401
or 403 as a merchant with a bad key. Telling them to check their credentials sends
them to debug the wrong thing.

- On a **public** endpoint: credentials are wrong or missing. Check `api-key` and
  `merchantId` are both set and both sent as headers.
- On a **restricted** endpoint (`PUT /api/v2/order/refund`,
  `POST /api/v{version}/provider/sms/{orderId}`): most likely this merchant does not
  have elevated access. Say so, and say it is arranged with MobiMatter — do not
  lead with "check your API key".

Access to a restricted endpoint can also be scoped to particular orders rather than
granted outright, so a merchant may hold elevated access and still be refused for a
specific order. Both cases are arranged with MobiMatter; neither is fixable by
rotating a key.

## Timeouts and 5xx on writes

A timed-out `POST /api/v2/order` may or may not have created an order, and **no
endpoint can tell you which** — there is no idempotency key, no order list, and no
lookup by `label` or merchant reference.

- Never auto-retry.
- Record the reference as indeterminate and surface it for manual review.
- Offer the customer a fresh attempt. If an orphan was created, it expires on its
  own — anywhere from 20 minutes to 48 hours depending on the provider — and the
  authorization is released.

The same applies to `PUT /order/complete`, `PUT /order/cancel`,
`PUT /order/refund` and `POST /email`. Resumption happens only through a persisted
`orderId`, never through transport retry.

## Per-endpoint 400s

### `POST /api/v2/order`

`message` is the only discriminator. The realistic causes, in the order worth
suggesting:

- **Product not assigned to this merchant.** It was withdrawn. Deactivate it
  locally and alert the admin — this is the same condition `syncCatalog` reports as
  `unassigned`.
- **Invalid `addOnOrderIdentifier`.** Most often because it was set to the latest
  top-up rather than the original eSIM order.
- **Product family mismatch.** The add-on product's `productFamilyId` differs from
  the target eSIM's. Only same-family products can top one another up.
- **Top-up not supported for this product.** The target `esim_realtime` product has
  no top-up version.
- **Failed the provider eligibility check.** The message is generic except when the
  eSIM is suspended, which is passed through verbatim.
- **`label` over 300 characters.**

Insufficient balance is **not** here — it is 402.

### `POST /api/v2/order` — 402

The wallet could not authorize the wholesale price. `message` is
`"Unable to authorize funds: "` plus the wallet service's own reason.

Remedy: top up in the Partner Portal or by bank transfer. MobiMatter also emails
automatically when the wallet runs low.

### `POST /api/v2/order` — 429

The product is out of stock. `message` carries the specific reason.

This is a per-product condition, not a throttle. Retrying the same product will
fail the same way. Treat it like an unavailable product: deactivate locally, alert
the admin, and offer the customer an alternative.

### `POST /api/v2/order` and `PUT /order/complete` — 455

The upstream provider is unavailable. `455` is not a registered HTTP status code —
some clients, proxies and generated SDKs mishandle unknown 4xx codes, so match on
the numeric value explicitly rather than relying on a status-class helper.

Unlike 429 this is transient and provider-wide, not product-specific. Do not
deactivate the product. Surface it as a temporary failure.

### `PUT /api/v2/order/complete`

The order may have expired. Time in `Created` state before expiry varies by
provider — from 20 minutes to 48 hours — so never treat any single window as
guaranteed. The authorization is released on expiry.

The correct action is to create a new order, not to retry completion. And do not
send a cancel — MobiMatter has already voided and cancelled.

### `PUT /api/v2/order/refund`

Ineligible orders return 400. Call
`GET /api/v2/order/{orderId}/refund/eligibility` first; its `reason` field is more
specific than the refund error. Refunds cannot be reversed, and any `fee` from the
eligibility check is applied.

## States that are not errors

| | |
|---|---|
| `Processing` | KYC pending (`KYC_URL` in `lineItemDetails`) or an async replacement in flight. Both resolve by webhook. |
| `Expired` | Funds already released. Create a new order. |
| `Cancelled` | Terminal. If it followed a KYC timeout, the customer needs refunding by the partner. |

Treating `Processing` as a failure is the most common misread: the call returned
2xx, the order is progressing, and retrying it will not help.
