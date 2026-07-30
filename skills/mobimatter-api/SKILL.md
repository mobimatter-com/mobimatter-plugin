---
name: mobimatter-api
description: Use when adding MobiMatter eSIM functionality to a project - selling eSIM data plans, browsing the plan catalogue, creating orders, provisioning eSIMs, issuing top-ups or replacements, retrieving QR codes and LPA activation strings, checking data usage, or handling MobiMatter order webhooks. Also use when debugging an existing MobiMatter integration, or when the user mentions MobiMatter, api.mobimatter.com, esim_realtime, esim_addon, addOnOrderIdentifier, or a merchantId/api-key header pair.
---

# MobiMatter API Integration

Writes MobiMatter eSIM integration code into the project you are working in,
generated against the live API contract published at docs.mobimatter.com.

**Core principle:** the MobiMatter API spends real money. There is no sandbox.
`POST /api/v2/order` authorizes the merchant's wallet and `PUT /api/v2/order/complete`
captures it. You generate code that spends money; you never spend it yourself.

## Your access is read-only

Use `scripts/mm.sh` for every live call. It is GET-only by construction.

```bash
./scripts/mm.sh spec-refresh              # always run this first
./scripts/mm.sh products --country=AE
./scripts/mm.sh order MM-123456
./scripts/mm.sh --help
```

Never hand-roll a `curl` to the MobiMatter API. If you find yourself wanting an
endpoint `mm.sh` does not expose, it is a write endpoint and the answer is no.

Credentials come from `MOBIMATTER_API_KEY` and `MOBIMATTER_MERCHANT_ID` in the
environment. If they are unset, ask the user to export them. Never accept an API
key pasted into the conversation, and never write one to a file.

## Workflow

1. **Ground.** Run `./scripts/mm.sh spec-refresh`. It prints `SOURCE: live` or
   `SOURCE: bundled snapshot`. Tell the user which one you got — a snapshot may be
   stale. Read `references/swagger.live.yaml` if present, otherwise
   `references/swagger.snapshot.yaml`, for exact request and response shapes.
2. **Survey the project.** Language, package manager, the HTTP client it already
   uses, its service-layer and error-handling conventions, how it sources secrets,
   its web framework and route layout, its cache, its job/queue runner, its test
   framework. Read `references/stacks.md`.
3. **Confirm scope.** Ask which flows are needed. Do not generate all of them by
   default.
4. **Ground on real data.** If credentials exist, pull a couple of real products
   with `mm.sh products` and confirm the field shapes before writing parsers.
5. **Write the integration** — see the recipe below.
6. **Leave the guardrail tests.** See `references/flows.md`.
7. **Get it reviewed by a subagent.** See below. Fix everything it finds, or say
   in your report why you disagree.
8. **Report.** Files written, env vars required, the review verdict, and anything
   you left out.

## Step 7: the guardrail review

Dispatch a subagent to review what you wrote. Not yourself — you just made these
decisions and will read your own intent back into the code rather than what is
there.

The guardrails are mostly *absences*: a retry that should not exist, a call that
must not happen before another. Absence is exactly what looks fine on re-reading,
and it is what a reviewer with no memory of writing the code will actually notice.

Give the reviewer the files you wrote, `references/flows.md`, and this brief. Ask
for a verdict per item — **PASS**, **FAIL** or **CANNOT TELL** — with a file and
line for every FAIL. Treat CANNOT TELL as a finding: it means the code does not
make the answer visible.

```
Review this MobiMatter integration against these rules. For each, answer
PASS / FAIL / CANNOT TELL with file:line evidence. Do not suggest improvements
or comment on style — only judge these rules.

1. Is any MobiMatter write (POST /order, PUT /order/complete, PUT /order/cancel,
   PUT /order/refund, POST /email) reachable through a retry, backoff or
   resilience wrapper?
2. Are the usage endpoints (provider/usage, provider/info) retried on failure?
3. Are the usage endpoints reachable from a timer, scheduler, background job or
   list-view prefetch, rather than only from a user action?
4. Are successful usage responses cached ~60s, and failures NOT cached?
5. Is POST /order ever reached before the customer's payment is captured?
   Trace the actual call path, not the function names.
6. Is the MobiMatter orderId persisted BEFORE complete is called, so a retry
   resumes rather than creating a second order?
7. Is cancelOrder called in any error-handling path?
8. Is addOnOrderIdentifier sourced from a stored root order id, or from the most
   recent top-up or replacement order?
9. Is GET /products called on any browsing, listing or product-page path?
10. Is productCategory typed as a closed enum or union anywhere?
11. Is the webhook handler idempotent on eventData.orderId, and does it return
    200 before doing slow work?
12. Are credentials read from the environment, with no key literal in any file
    and no .env written?
13. Is `rechargeable` checked before top-up products are LISTED to the customer,
    not only before the top-up order is created? A UI that shows top-ups for a
    non-rechargeable eSIM charges the customer for an order that will fail.
14. Does error mapping branch on the HTTP status, or on the `statusCode` field in
    the response body? The two do not always agree.
15. Are 402, 429 and 455 from POST /order handled, and handled as clean terminal
    failures rather than as indeterminate or retryable?
16. Does any numeric status code appear outside the client's error-mapping module?
    A `455` or `429` literal at a call site means the typed error model was
    bypassed. Reasons are also NOT derived from `message` for any status but 400.
```

## What you generate

The output is these parts, in this order. Match the project's existing naming and
file layout; the names below describe responsibilities, not required filenames.

| Part | Responsibility |
|---|---|
| **client** | One function per endpoint. Sets `api-key` and `merchantId` headers. Per-endpoint response unwrapping. |
| **errors** | A `MobiMatterErrorReason` enum and a `MobiMatterError` type, mapped from HTTP status plus endpoint at the client boundary. Raw status codes never reach a call site. The API's own `message` is always passed through. Shape in `references/errors.md`. |
| **types** | Product, order, line-item and eSIM shapes. `productCategory` is an open string, never a closed enum. |
| **catalog** | `syncCatalog()`, `syncNetworks()`, `validateProduct()`. |
| **fulfilment** | `fulfillPaidOrder()`, `topUpEsim()`, `replaceEsim()`, `sendOrderConfirmation()`. |
| **usage** | `getEsimUsage()`, `getEsimInfo()` — cached, uncached-on-failure, never retried. |
| **webhook** | Route + RSA-SHA256 signature verification + idempotent handling. |
| **.env.example** | Placeholders only. Confirm `.env` is gitignored. |
| **tests** | The guardrail assertions in `references/flows.md`. |

Full endpoint reference: `references/api-contract.md`.
Flow logic and the guardrail tests: `references/flows.md`.
Product and line-item field meanings: `references/products.md`.
Error mapping: `references/errors.md`.
Webhook payload and verification: `references/webhooks.md`.

## Rules the generated code must follow

These exist because each one, when broken, costs the partner money or breaks a
customer's purchase. They are not style preferences.

**Order only after the customer has paid.** Validate the product live, then take
payment, then create the MobiMatter order. Creating first ties up wallet balance
against carts that never convert; charging first bills customers for eSIMs that
cannot be fulfilled.

**Never retry a write.** No transport-level retry, no backoff wrapper, no
circuit-breaker retry on `POST /order`, `PUT /order/complete`, `PUT /order/cancel`,
`PUT /order/refund` or `POST /email`. The API has no idempotency key and no way to
look an order up by merchant reference, so a retried create can double-charge the
wallet with no way to detect it. Resumption happens only through a persisted
`orderId`.

**Never retry a usage check.** `provider/usage` and `provider/info` reach the
upstream provider. One attempt. On failure, show the last cached figures or report
usage unavailable.

**Never cancel after a failed completion.** MobiMatter voids and cancels
automatically. A compensating `PUT /order/cancel` is a redundant write against an
already-cancelled order.

**Never call `GET /products` from a request path.** Browsing is served from the
merchant's own synced catalogue. The single exception is the live product check at
order creation — one call per order, not one per page view.

**Check `rechargeable` before offering a top-up.** It gates the *display* of
top-up products, not just the order. Listing top-ups for an eSIM that cannot accept
them means the customer picks one, pays, and the order fails — the same
charge-then-fail trap as selling a withdrawn product.

**`addOnOrderIdentifier` is always the original eSIM order.** Never the latest
top-up, never a previous replacement.

**Every persisted order carries a parent order id.** Add the column or property to
whatever table or model the project stores orders in. On an original purchase it is
the order's own id; on a top-up or replacement it is copied from the parent it was
bought against — never the id of the order immediately before it. Derived at write
time and never reassigned, so `addOnOrderIdentifier` is a field read, not a walk
back through order history that gets the wrong answer once a replacement exists.

## Red flags — stop and re-read the rules above

- You are about to add `retry`, `backoff`, `p-retry`, `tenacity`, `axios-retry`
  or a resilience wrapper "for robustness"
- You are about to call `cancelOrder()` inside a `catch` block
- You are about to create an order in a checkout, cart or "reserve" handler
- You are about to poll usage on a timer, prefetch it for a list, or refresh it in
  the background
- You are about to render a top-up list without having checked `rechargeable`
- You are about to set `addOnOrderIdentifier` to the most recent order id
- You are about to type `productCategory` as an enum or union of known values
- You are about to write `curl` against `api.mobimatter.com` yourself

## Rationalizations

| Thought | Reality |
|---|---|
| "A retry wrapper on the whole client is best practice" | On writes it double-charges the wallet. Exclude every write and both usage endpoints, or add none. |
| "The create timed out, so it failed" | A timeout tells you nothing. The order may exist, and no endpoint can tell you. Never auto-retry it. |
| "I should cancel the order if completing fails" | Already cancelled by the platform. Your cancel is a redundant write. |
| "Creating the order at checkout gives a better UX" | It holds wallet funds against carts that never convert, and an unconverted order holds them until it expires — 20 minutes to 48 hours depending on the provider. |
| "One usage poll every 30s keeps the UI fresh" | It hammers the upstream provider for a screen nobody is looking at. |
| "The local active flag is enough to block ordering" | The catalogue is only as fresh as the last sync. Check live before charging. |
| "productCategory should be a strict union type" | Historical orders carry retired values such as `physical_sim` and will throw. |
| "I'll just curl the API to test the order flow" | That spends real money. Generate the code and let the developer run it. |

## Assumptions to state when you generate

- Success is a 2xx with a present `result`. Tolerate an `isSuccess` field if the
  API returns one; the published spec does not define it.
- The generated code has not been run against the live API. Testing it, reviewing
  it, and everything it does in production are the developer's responsibility.
