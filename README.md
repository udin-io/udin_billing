# udin_billing

Billing for Phoenix + Ash apps: sell plans, turn them into access (on/off features and
counted units per cycle), take payments through Paymob or the app stores (RevenueCat), and
manage it all from an admin dashboard in English and Arabic.

One library, many apps: everything an app does differently is **config** or **data**, so no
app ever patches the library.

**Contents:** [What it does](#1-what-it-does) ·
[Install](#2-install) · [Config](#3-config) · [Check access](#4-check-access) ·
[Spend counters](#5-spend-counters) · [Payments](#6-payments) ·
[Catalog](#7-plans-and-features-catalog-file) · [Dashboard](#8-admin-dashboard) ·
[Telemetry](#9-react-to-changes-telemetry) · [Tests in your app](#10-tests-in-your-app) ·
[Going live](#11-going-live-checklist) · [Developing the library](#12-developing-the-library)

---

## 1. What it does

| Concept | Meaning | Example |
|---|---|---|
| **Feature: switch** | On or off for a user | `export_pdf` |
| **Feature: counter** | Units per cycle, no carry over | `credits: 100`, `ai_generations: 50` |
| **Plan** | A price plus feature values | Starter: 10 USD, 100 credits, 1 month |
| **Plan kind** | `free` (everyone), `one_time` (bought once), `recurring` (store subscription) | Free, Starter pack, Pro monthly |
| **Purchase** | A user bought a one time plan (or got it as a gift) | Paymob checkout |
| **Subscription** | A store plan that renews | App Store / Google Play via RevenueCat |

Features and plans are **data** (dashboard or catalog file). Differences between apps are **config**. You never patch the library.

---

## 2. Install

```elixir
# mix.exs
{:udin_billing, git: "https://github.com/udin-io/udin_billing.git", tag: "v0.1.0"}
```

```bash
mix deps.get
mix udin_billing.install --user MyApp.Accounts.User --admin-check MyApp.Billing.admin? \
  --modes one_time --locales en,ar
mix ash.codegen add_billing && mix ash.migrate
```

The installer writes the config below, adds `UdinBilling.Domain` to `:ash_domains` and prints the remaining steps. Safe to run again.

Requirements:

| | Version |
|---|---|
| Elixir | `~> 1.17` |
| Ash / AshPostgres | `~> 3.12` / `~> 2.6` (PostgreSQL) |
| Phoenix / LiveView | `~> 1.7` / `~> 1.0`, only for the dashboard |
| Igniter | `~> 0.7`, only for `mix udin_billing.install` |

Your user resource must have a UUID primary key.

---

## 3. Config

```elixir
# config/config.exs
config :udin_billing,
  repo: MyApp.Repo,                          # compile time
  user_resource: MyApp.Accounts.User,        # compile time
  admin_check: {MyApp.Billing, :admin?},     # true for admins (dashboard + Admin API)
  modes: [:one_time],                        # :free, :one_time, :recurring
  locales: ["ar", "en"],                     # default language first, its text is required
  currencies: ["USD"],                       # default: just default_currency
  default_currency: "USD",
  required_features: ["credits"]             # keys your code spends: can't be deleted
```

All settings:

| Key | Default | What it does |
|---|---|---|
| `repo`, `user_resource` | required | Your repo and user resource (compile time) |
| `admin_check` | required | `{mod, fun}` called with the actor |
| `modes` | `[:free, :one_time]` | Plan kinds allowed |
| `locales` | `["en"]` | Languages of plan and feature names |
| `currencies` / `default_currency` | `["EGP"]` / `"EGP"` | Currencies a plan may use |
| `required_features` | `[]` | Feature keys your code needs |
| `purchase_policy` | `:stack` | `:stack` buy again while active, each keeps its expiry. `:single_active` one at a time |
| `upgrade_policy` | `:fresh` | Plan switch mid cycle: `:fresh` full new counters, `:shift` minus what was used |
| `free_plan_with_subscription` | `:replace` | `:replace` subscription replaces Free, `:keep` adds Free on top |
| `hold_ttl` | `900` | Seconds a `reserve` holds units before it lapses |
| `checkout_ttl` | `3600` | Seconds an unpaid checkout stays open |
| `grace_access` | `true` | Keep switches on while the store retries a failed renewal |
| `allow_sandbox` | `false` | Count store test purchases. Never true in production |
| `providers` | `%{}` | Payment providers (section 6) |
| `dashboard` | `true` | Dashboard on or off |
| `developer_tools` | `true` | Show Features, Catalog, Webhooks and "Give a plan" |
| `dashboard_theme` | `:system` | `:light` or `:dark` to match your app |
| `admin_locale` | none | `{mod, fun}` returning the admin's language |
| `user_search` | none | `{mod, fun}` to find users by phone or email (section 8) |
| `user_labels` | none | `{mod, fun}` to show users as "phone · name" (section 8) |
| `dashboard_examples` | from catalog | Override examples in help texts |

Secrets go in `runtime.exs`. A wrong value raises at the first read with the key's name.

---

## 4. Check access

```elixir
access = UdinBilling.access(user.id)              # once per request or LiveView mount

UdinBilling.Access.enabled?(access, "export_pdf")     # true / false
UdinBilling.Access.remaining(access, "credits")       # 37, or :unlimited
UdinBilling.Access.can_spend?(access, "credits")      # remaining >= 1

UdinBilling.enabled?(user.id, "export_pdf")        # one switch, one query
UdinBilling.balance(user.id, "credits")            # {:ok, %{remaining: 37, limit: 100, resets_at: ~U[...]}}
```

Free plans need no purchase: the plan marked default applies to every user.

---

## 5. Spend counters

Every spend has a `reference`, so a retry never spends twice.

**Spend at once** (placing an order), inside your own transaction:

```elixir
case UdinBilling.consume(user.id, "credits", reference: "order:" <> order.id) do
  {:ok, _usages} -> :ok
  {:error, :insufficient_quota} -> {:error, :not_enough_credits}
end
```

**Hold, then keep or give back** (work that can fail, like an AI generation):

```elixir
{:ok, _} = UdinBilling.reserve(user.id, "ai_generations", reference: job.id)

case run_generation(job) do
  {:ok, _result} -> UdinBilling.commit(user.id, "ai_generations", reference: job.id)
  {:error, _} -> UdinBilling.release(user.id, "ai_generations", reference: job.id)
end
```

A hold nobody finishes lapses after `hold_ttl` and the unit returns. Option `amount: 2` spends more than one.

Errors: `:insufficient_quota`, `:unknown_counter`, `:already_committed`. Two requests at the same moment never spend the same unit (row lock per user).

---

## 6. Payments

### Paymob (one time plans: card, web checkout)

```elixir
# config/runtime.exs
config :udin_billing, :providers, %{
  "paymob" =>
    {UdinBilling.Providers.Paymob,
     secret_key: System.fetch_env!("PAYMOB_SECRET_KEY"),
     public_key: System.fetch_env!("PAYMOB_PUBLIC_KEY"),
     hmac_secret: System.fetch_env!("PAYMOB_HMAC_SECRET"),
     integrations: %{card: 1_234_567, wallet: 1_234_568},
     enabled_methods: [:card],
     notification_url: "https://myapp.com/billing/webhooks/paymob",
     redirection_url: "https://myapp.com/billing/return"}
}
```

```elixir
# router.ex, OUTSIDE browser/CSRF pipelines
forward "/billing/webhooks/paymob", UdinBilling.WebhookPlug, provider: "paymob"
```

Buy:

```elixir
{:ok, %{redirect_url: url}} =
  UdinBilling.checkout(user.id, plan.id, "paymob", %{
    locale: "en",
    customer: %{first_name: user.first_name, last_name: user.last_name, email: user.email, phone_number: user.phone}
  })

# send the user to url. Paymob calls the webhook, the purchase becomes paid.
```

On your return page, apply the signed result Paymob sends back too (it's checked like the webhook, applied once):

```elixir
UdinBilling.handle_webhook("paymob", params)
```

In the Paymob dashboard, set the integration's transaction callback to the same webhook URL, so refunds reach you.

### RevenueCat (store subscriptions and in app packs)

```elixir
config :udin_billing, :providers, %{
  "revenuecat" =>
    {UdinBilling.Providers.RevenueCat,
     api_key: System.fetch_env!("REVENUECAT_SECRET_API_KEY"),
     webhook_auth: System.fetch_env!("REVENUECAT_WEBHOOK_AUTH")}
}

forward "/billing/webhooks/revenuecat", UdinBilling.WebhookPlug, provider: "revenuecat"
```

The phone buys through the store SDK with **App User ID = your user id**, then calls your API, which calls:

```elixir
UdinBilling.sync_customer("revenuecat", user.id)   # after a purchase and on "Restore purchases"
```

The server always asks RevenueCat for the truth, never trusts the phone. Each plan lists its store product ids (`provider_product_ids: %{"revenuecat" => "pro_monthly"}`).

### What the library handles for you

| Case | Result |
|---|---|
| Wrong amount or currency | Refused, stored for an admin |
| Same webhook twice, or webhook and return page together | Applied once |
| Paid twice for one order | Second payment kept as **refund required**, grants nothing |
| Paid after the checkout was cancelled | Accepted under `:stack`, else refund required |
| Refund from the provider | Access ends, unused units withdrawn |
| Failed renewal | Store grace period respected (`grace_access`) |

### Close unpaid checkouts (hourly job)

```elixir
# Oban cron: {"0 * * * *", MyApp.Billing.CancelStaleCheckoutsWorker}
def perform(_job) do
  {:ok, _closed} = UdinBilling.Purchases.cancel_stale()   # older than checkout_ttl
  :ok
end
```

---

## 7. Plans and features: catalog file

Features the code uses live in git and load on every deploy. Plans are usually made by admins in the dashboard.

```json
{
  "format": "udin_billing.catalog",
  "version": 1,
  "features": [
    {"key": "credits", "kind": "counter", "name": {"en": "Credits", "ar": "رصيد"}, "sort_order": 0}
  ]
}
```

```bash
mix udin_billing.catalog.export --features-only > priv/billing/catalog.json
mix udin_billing.catalog.import --dry-run          # show changes
mix udin_billing.catalog.import                    # apply: by key and code, all or nothing, never deletes
mix udin_billing.catalog.import --deactivate-missing
```

In a release, call it from your `bin/migrate`: `UdinBilling.Catalog.import_file()` (`dry_run: true` to preview).

Plan rules you'll meet:
* A sold plan's price, kind, periods and features are locked. Use "Create new version".
* A recurring plan always gets a refill no longer than its billing period.
* Buyers keep the terms they bought, whatever is edited later.

---

## 8. Admin dashboard

```elixir
# router.ex
import UdinBilling.Web.Router

scope "/admin" do
  pipe_through [:browser, :require_admin]

  udin_billing_dashboard "/billing",
    on_mount: [{MyAppWeb.UserAuth, :mount_current_user}],
    layout: {MyAppWeb.Layouts, :billing}     # optional: your own sidebar around it
end
```

AshAuthentication apps pass `AshAuthentication.Phoenix.LiveSession.opts(on_mount: [...])` instead.

Pages: **Plans** (cards, compare, preview as buyers see it), **Plan editor**, **Features**, **Users** (balances, gifts), **Payments** (refunds needed first), **Webhooks** (failed first, replay), **Catalog** (export, import with preview). English and Arabic, right to left in Arabic. `?lang=ar` switches for one visit.

Make it fit your app:

```elixir
config :udin_billing,
  dashboard_theme: :light,
  admin_locale: {MyApp.Billing, :dashboard_locale},   # fn admin -> "ar" end
  user_search: {MyApp.Billing, :search_users},        # fn "jane@example.com" -> [%{id: id, label: "..."}] end
  user_labels: {MyApp.Billing, :user_labels}          # fn [ids] -> %{id => "..."} end, one query

# production: hide developer pages unless switched on
config :udin_billing, developer_tools: System.get_env("BILLING_DEV_TOOLS") == "on"
```

The same actions from code, each checking the admin: `UdinBilling.Admin` (`create_plan`, `grant_plan`, `user_overview`, `revenue`, `replay_provider_event`, `import_catalog`, ...).

---

## 9. React to changes (telemetry)

| Event | When |
|---|---|
| `[:udin_billing, :purchase, :paid \| :refund_required \| :failed \| :refunded \| :cancelled]` | a purchase changed status (`purchase_id`, `user_id`, `plan_id`) |
| `[:udin_billing, :subscription, :started \| :renewed \| :renewed_inactive_plan]` | a store subscription started or renewed (the last: renewed on a plan taken off sale) |
| `[:udin_billing, :units, :held \| :committed \| :released \| :rejected]` | units spent or held (`user_id`, `feature`, `reference`, `reason` on rejected) |
| `[:udin_billing, :webhook, :processed \| :ignored \| :duplicate \| :failed \| :error]` | each provider message |

Live screens: attach a handler that broadcasts on the user's PubSub topic, then reload on the message.

```elixir
:telemetry.attach_many("billing-updates", [[:udin_billing, :purchase, :paid]], fn _e, _m, %{user_id: id}, _ ->
  Phoenix.PubSub.broadcast(MyApp.PubSub, "billing:" <> id, {:billing, :changed})
end, nil)
```

---

## 10. Tests in your app

```elixir
# config/test.exs: a signed fake provider, no network
config :udin_billing, :providers, %{
  "paymob" => {UdinBilling.Providers.Fake, secret: "a-long-test-secret-value"}
}
```

```elixir
{:ok, purchase} = UdinBilling.start_purchase(user.id, plan.id, "paymob")
{:ok, _} = UdinBilling.confirm_payment(purchase.id, %{amount: plan.price, currency: plan.currency})
assert UdinBilling.Access.remaining(UdinBilling.access(user.id), "credits") == 100
```

Seeds and fixtures: create plans with `authorize?: false`.

---

## 11. Going live checklist

1. Dependency pinned to a tag (`tag: "v0.1.0"`), never a branch.
2. `mix ash.codegen` migration committed. `bin/migrate` also imports the catalog.
3. Provider secrets set. Webhook URLs set at the provider (https).
4. Hourly `cancel_stale` job scheduled.
5. `allow_sandbox` off in production.
6. Right after deploy: create the plans in the dashboard (if spending is required, users can't act until a plan exists).

---

## 12. Developing the library

```bash
git clone https://github.com/udin-io/udin_billing.git && cd udin_billing
mix deps.get
mix test          # creates the test database (PostgreSQL on localhost, postgres/postgres)
```

Before a pull request:

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix ash.codegen --check                  # resources and snapshots agree
mix gettext.extract --check-up-to-date   # every dashboard text is in the .po files
mix test
```

Layout:

| Path | What |
|---|---|
| `lib/udin_billing.ex` | The public API apps call |
| `lib/udin_billing/` | Resources (Plan, Feature, Purchase, Subscription, Grant, Usage, Account, ProviderEvent), spending (`Quotas`, `Access`), purchases, subscriptions, webhooks, `Admin`, `Config` |
| `lib/udin_billing/providers/` | Paymob, RevenueCat and the Fake provider for tests |
| `lib/udin_billing/web/` | The admin dashboard (LiveView), router macro, components |
| `lib/mix/tasks/` | `udin_billing.install`, `udin_billing.catalog.import` and `.export` |
| `priv/gettext/` | Dashboard translations, English and Arabic |
| `priv/test_repo/` | Migrations for the library's own test database |

Releases: bump `@version` in `mix.exs`, tag it (`v0.1.1`), and apps move their `tag:`.
