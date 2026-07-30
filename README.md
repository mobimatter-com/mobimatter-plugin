# MobiMatter eSIM API — agent skill

Generates MobiMatter eSIM integration code directly into your project: catalogue
sync, ordering, top-ups, replacements, QR/LPA retrieval, usage checks and order
completion webhooks.

Written against the API contract published at
[docs.mobimatter.com](https://docs.mobimatter.com).

Works with Claude Code and Codex.

## Install — Claude Code

```
/plugin marketplace add mobimatter-com/mobimatter-plugin
/plugin install mobimatter
```

## Install — Codex

```
codex plugin marketplace add mobimatter-com/mobimatter-plugin
codex plugin add mobimatter@mobimatter
```

Then start a new Codex thread so it picks up the skill.

## Using it

Then ask for what you need — "add MobiMatter eSIM checkout to this app", "wire up
the order completion webhook", "why is my top-up failing" — and the skill loads
itself.

## What it generates

An API client, typed models, catalogue sync, fulfilment flows, a usage layer with
caching, a signature-verifying webhook handler, and tests for the parts that are
easy to get wrong. It matches your project's existing HTTP client, cache, job
runner and file layout rather than introducing its own.

Supported out of the box: TypeScript/Node, Python, PHP. Any other language works
too — the contract it generates from is language-neutral.

## Why it is careful

The MobiMatter API moves real money and has no sandbox. Creating an order
authorizes the merchant's wallet; completing it captures the funds. There is no
idempotency key, so a blindly retried write can double-charge and provision two
eSIMs for one payment.

The skill encodes the rules that follow from that — writes are never retried,
orders are persisted before completion so a crash resumes rather than duplicates,
and products are validated live before a customer is charged. It reviews its own
output against those rules before handing back.

## Configuration

```
MOBIMATTER_API_KEY=...
MOBIMATTER_MERCHANT_ID=...
```

Get both from the [Partner Portal](https://partner.mobimatter.com). The skill
reads them from the environment, writes a `.env.example` with placeholders, and
never writes a `.env` or embeds a key in generated code.

Its own access to the live API is read-only by construction — it can fetch the
spec and read your catalogue, but it cannot place an order.

## Links

- [API documentation](https://docs.mobimatter.com)
- [Partner Portal](https://partner.mobimatter.com)

## Disclaimer

This plugin is provided "as is", without warranty of any kind, express or implied,
including but not limited to the warranties of merchantability, fitness for a
particular purpose and non-infringement.

It generates code. It does not review, approve or operate the code it generates,
and it is not a substitute for your own testing, security review and judgement.
The MobiMatter API moves real money: you are solely responsible for everything
your integration does in production, including orders placed, funds captured or
authorized, eSIMs provisioned, refunds owed, data handled, and any resulting
liability to your own customers.

In no event shall MobiMatter LTD or its contributors be liable for any claim,
damages or other liability — whether direct, indirect, incidental, special,
consequential or exemplary, including lost profits, lost revenue, financial loss
or data loss — arising from or in connection with this plugin, the code it
generates, or the use of either.

Your use of the MobiMatter API remains governed by your partner agreement and the
MobiMatter terms of service. Nothing here modifies them.

---

© MobiMatter LTD
