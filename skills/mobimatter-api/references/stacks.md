# Per-stack guidance

Read the project before applying any of this. Everything below is a default for
when the project has no established convention — an existing convention always
wins.

## Rules that apply everywhere

**Reuse the project's HTTP client.** If it uses `fetch`, use `fetch`. If it uses
`axios`, `got`, `httpx`, `requests` or Guzzle, use that. Do not add a client
dependency for nine JSON calls.

**Do not add a retry library.** Not `p-retry`, `axios-retry`, `tenacity`,
`backoff`, or a framework's built-in retry middleware. If one is already wired into
the project's shared HTTP client, the MobiMatter client must bypass it or opt out
explicitly, and you must say so in your report. Every MobiMatter write is
unsafe to retry.

**Reuse the project's cache** for the 60-second usage cache — Redis, the framework
cache, whatever exists. In-process only as a last resort, and say so: it does not
bound load across multiple instances.

**Reuse the project's job runner** for webhook processing and the scheduled sync.

**Secrets come from the environment** — `MOBIMATTER_API_KEY`,
`MOBIMATTER_MERCHANT_ID` — unless the project already sources secrets from a
manager, in which case follow that. Write `.env.example` with placeholders. Never
write `.env`. Confirm `.env` is gitignored.

## TypeScript / Node

- Types from the schemas in `api-contract.md`. `productCategory` stays `string`,
  not a union — historical orders carry retired values.
- `lineItemDetails` is an array of `{name, value}`; generate a lookup helper rather
  than indexing positionally.
- Scheduled sync: whatever the project uses — a cron container, BullMQ repeatable
  job, Vercel/Netlify scheduled function. Do not introduce `node-cron` into a
  project that has a scheduler already.
- Webhook route: `app/api/.../route.ts` on Next.js App Router, `pages/api/` on
  Pages Router, a router module on Express/Nest. Read the raw body before parsing
  where the framework buffers it.
- Verification: `crypto.createVerify('RSA-SHA256')`, no dependency needed.

## Python

- `httpx` if present, else `requests`. Match the project's sync/async style — do
  not introduce async into a sync codebase for these calls.
- Dataclasses or Pydantic to match what the project already uses. With Pydantic,
  `productCategory` is `str`, not an `Enum`.
- Scheduled sync: Celery beat, APScheduler, Django management command plus system
  cron — whichever exists.
- Webhook route: Django view, FastAPI/Flask route. Read the raw body before parsing.
- Verification: `cryptography` — `padding.PKCS1v15()` with `hashes.SHA256()`.

## PHP

- Guzzle if present, else the framework's HTTP client (`Http::` facade on Laravel).
- Laravel: client as a service-container binding, sync as an artisan command on the
  scheduler, webhook as a route with CSRF disabled for that path, usage cache via
  `Cache::remember`.
- WooCommerce/WordPress: sync on WP-Cron, webhook via `register_rest_route`.
- Verification: `openssl_verify($signingString, $signature, $publicKey,
  OPENSSL_ALGO_SHA256)` with the signature base64-decoded first.

## Any other stack

The contract in `api-contract.md` and the rules in `flows.md` are complete and
language-neutral. Write idiomatic code for whatever the project uses, follow its
existing structure, and keep the guardrails intact — they are the part that must
not be adapted away.
