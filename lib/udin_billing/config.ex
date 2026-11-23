defmodule UdinBilling.Config do
  @moduledoc """
  Reads the `:udin_billing` application environment.

  ## Why
  The same package runs in several apps (Family-Corp, ReelsChef). Every difference
  between them is a value here or a row in the database (plans, features), so no app
  patches the package.

  ## Keys
    * `:repo` (compile time) - the app's `AshPostgres.Repo`.
    * `:user_resource` (compile time) - the app's user Ash resource (UUID primary key).
    * `:admin_check` - `{module, function}` called with the actor; `true` for admins.
    * `:modes` - plan kinds the app allows: any of `:free`, `:one_time`, `:recurring`.
      Default `[:free, :one_time]`.
    * `:purchase_policy` - `:stack` (default; buy while a plan is active, each keeps its
      own expiry) or `:single_active` (one active one-time purchase at a time).
    * `:upgrade_policy` - when a subscriber switches plan mid-cycle: `:fresh` (default;
      the new plan's full counters) or `:shift` (new counters minus this cycle's use).
    * `:hold_ttl` - seconds a reservation holds units before it lapses (default 900).
    * `:checkout_ttl` - seconds a pending checkout stays open (default 3600).
    * `:default_currency` - ISO 4217 code for plans without one (default `"EGP"`).
    * `:grace_access` - while a store retries a failed renewal payment (its grace period):
      `true` (default) keeps the plan's switches on; `false` ends access at the paid
      period's end until the payment succeeds. Counters never get a new, unpaid cycle.
      Read on every access check, so a change applies at once.
    * `:admin_locale` - `{module, function}` called with the signed-in admin; returns their
      language (`"ar"`) or nil. The dashboard shows in it. Without it, the admin's own
      `locale` field is used when it has one. A language not in `:locales` is ignored.
    * `:dashboard_examples` - a map that replaces any example the dashboard's help texts
      show (`:feature`, `:feature_key`, `:plan_name`, `:plan_code`, `:price`, `:amount`,
      `:currency`). They come from the project's own catalog unless set here.
    * `:dashboard_theme` - `:system` (default) follows the operating system's light or dark
      setting, `:light` or `:dark` pins the dashboard to one, so it matches the host app's
      own pages (Family-Corp's admin is always light).
    * `:user_search` - `{module, function}` the dashboard's Users page calls with what the
      admin typed (anything that isn't a user id). It returns up to 10 matches as
      `[%{id: user_id, label: "Ahmed · +201001234567"}]`. The app decides which fields to
      search and how to normalize them (phone formats, case). Without it, only ids work.
    * `:user_labels` - `{module, function}` called once per dashboard page with the user ids
      it shows; returns `%{user_id => "+201001234567 · Ahmed"}`. Payments shows the label
      in place of the id, and the Users page shows it above the found user. Without it, ids
      are shown.
    * `:locales` - languages of plan and feature texts, default locale first, e.g.
      `["en", "ar"]` (default `["en"]`). The default locale's text is required.
    * `:allow_sandbox` - accept store sandbox/test purchases (default `false`; set `true`
      only outside production, or testers get paid plans free).
    * `:providers` - payment providers by name, e.g.
      `%{"revenuecat" => {UdinBilling.Providers.RevenueCat, api_key: ..., webhook_auth: ...}}`.
      Secrets belong in `runtime.exs`.
  """

  @type mode :: :free | :one_time | :recurring

  @doc "Plan kinds the app has enabled."
  @spec modes() :: [mode()]
  def modes, do: get(:modes, [:free, :one_time])

  @doc "True when plan kind `mode` is enabled."
  @spec mode_enabled?(mode()) :: boolean()
  def mode_enabled?(mode), do: mode in modes()

  @doc "`:stack` or `:single_active`. Raises on anything else."
  @spec purchase_policy() :: :stack | :single_active
  def purchase_policy, do: one_of!(:purchase_policy, :stack, [:stack, :single_active])

  @doc "`:fresh` or `:shift`. Raises on anything else."
  @spec upgrade_policy() :: :fresh | :shift
  def upgrade_policy, do: one_of!(:upgrade_policy, :fresh, [:fresh, :shift])

  @doc "Seconds a reservation holds units. Raises unless a positive integer."
  @spec hold_ttl() :: pos_integer()
  def hold_ttl, do: positive!(:hold_ttl, 900)

  @doc "Seconds a pending checkout stays open. Raises unless a positive integer."
  @spec checkout_ttl() :: pos_integer()
  def checkout_ttl, do: positive!(:checkout_ttl, 3600)

  @doc """
  The currencies plans may use (`config :udin_billing, currencies: ["EGP", "USD"]`).
  Without the setting: only `default_currency/0`.
  """
  @spec currencies() :: [String.t(), ...]
  def currencies do
    case get(:currencies, nil) do
      nil ->
        [get(:default_currency, "EGP")]

      [_ | _] = codes ->
        if Enum.all?(codes, &(is_binary(&1) and &1 =~ ~r/\A[A-Z]{3}\z/)),
          do: codes,
          else: invalid!(:currencies, codes, ~s(uppercase ISO 4217 codes, e.g. ["EGP", "USD"]))

      other ->
        invalid!(:currencies, other, ~s(a non-empty list, e.g. ["EGP"]))
    end
  end

  @doc """
  Currency for new plans: `:default_currency`, or the first of `:currencies`. Must be one
  of `currencies/0`.
  """
  @spec default_currency() :: String.t()
  def default_currency do
    currencies = currencies()
    default = get(:default_currency, hd(currencies))

    if default in currencies,
      do: default,
      else:
        invalid!(
          :default_currency,
          default,
          "one of the configured currencies #{inspect(currencies)}"
        )
  end

  @doc "Languages of plan and feature texts; the first is the default."
  @spec locales() :: [String.t(), ...]
  def locales do
    case get(:locales, ["en"]) do
      [_ | _] = locales ->
        if Enum.all?(locales, &is_binary/1),
          do: locales,
          else: invalid!(:locales, locales, "a list of locale strings")

      other ->
        invalid!(:locales, other, "a non-empty list like [\"en\", \"ar\"]")
    end
  end

  @doc "The default language: the first of `locales/0`."
  @spec default_locale() :: String.t()
  def default_locale, do: hd(locales())

  @doc "Whether a subscription keeps access during the store's grace period."
  @spec grace_access?() :: boolean()
  def grace_access? do
    case get(:grace_access, true) do
      value when is_boolean(value) -> value
      value -> invalid!(:grace_access, value, "true or false")
    end
  end

  @doc """
  What happens to the free plan while a subscription grants access: `:replace` (default;
  the subscription's own features and counters only) or `:keep` (the free plan adds on top).
  """
  @spec free_plan_with_subscription() :: :replace | :keep
  def free_plan_with_subscription,
    do: one_of!(:free_plan_with_subscription, :replace, [:replace, :keep])

  @doc """
  Feature keys the app's code depends on (e.g. `["rides"]`). They can't be deleted in the
  dashboard and a catalog import that would leave one missing is refused. Default `[]`.
  """
  @spec required_features() :: [String.t()]
  def required_features do
    case get(:required_features, []) do
      keys when is_list(keys) ->
        if Enum.all?(keys, &is_binary/1),
          do: keys,
          else: invalid!(:required_features, keys, ~s(a list of keys like ["rides"]))

      other ->
        invalid!(:required_features, other, ~s(a list of keys like ["rides"]))
    end
  end

  @doc """
  Whether the admin dashboard is on (default true). Read on every page load, so an app can
  turn it on in production only while configuring, e.g.
  `config :udin_billing, dashboard: System.get_env("BILLING_DASHBOARD") == "on"` in
  runtime.exs, without a new build.
  """
  @spec dashboard_enabled?() :: boolean()
  def dashboard_enabled? do
    case get(:dashboard, true) do
      value when is_boolean(value) -> value
      value -> invalid!(:dashboard, value, "true or false")
    end
  end

  @doc """
  Whether the dashboard shows the developer pages (Features, Catalog, Webhooks) and
  "Give a plan" (default true). Off, admins see only Plans and Users: they manage bundles
  and view credits. Read on every page load, e.g. in runtime.exs:
  `config :udin_billing, developer_tools: System.get_env("BILLING_DEV_TOOLS") == "on"`.
  """
  @spec developer_tools?() :: boolean()
  def developer_tools? do
    case get(:developer_tools, true) do
      value when is_boolean(value) -> value
      value -> invalid!(:developer_tools, value, "true or false")
    end
  end

  @doc "Whether store sandbox purchases count. Must stay false in production."
  @spec allow_sandbox?() :: boolean()
  def allow_sandbox?, do: get(:allow_sandbox, false) == true

  @doc "The `{module, opts}` configured for provider `name`."
  @spec provider(String.t() | atom()) ::
          {:ok, {module(), keyword()}} | {:error, :unknown_provider}
  def provider(name) do
    case Map.fetch(get(:providers, %{}), to_string(name)) do
      {:ok, {module, opts}} when is_atom(module) and is_list(opts) -> {:ok, {module, opts}}
      _ -> {:error, :unknown_provider}
    end
  end

  @doc "Calls the app's admin check for `actor`; false when unconfigured or not exactly `true`."
  @spec admin?(term()) :: boolean()
  def admin?(nil), do: false

  def admin?(actor) do
    case get(:admin_check, nil) do
      {module, function} -> apply(module, function, [actor]) == true
      nil -> false
    end
  end

  @doc """
  The language the dashboard shows in for `actor`: the app's `:admin_locale` hook, or the
  actor's own `locale` field. Nil when there is none or the app doesn't offer it.
  """
  @spec admin_locale(term()) :: String.t() | nil
  def admin_locale(actor) do
    raw =
      case get(:admin_locale, nil) do
        {module, function} -> apply(module, function, [actor])
        nil -> if is_map(actor), do: Map.get(actor, :locale)
      end

    locale = if raw, do: to_string(raw)
    if locale in locales(), do: locale
  end

  @doc """
  The dashboard's colour theme: `:system` (default), `:light` or `:dark`. Raises on any
  other value.
  """
  @spec dashboard_theme() :: :system | :light | :dark
  def dashboard_theme, do: one_of!(:dashboard_theme, :system, [:system, :light, :dark])

  @doc """
  The app's user search for the dashboard (`{module, function}`), or nil when the app has
  none. Raises on any other value.
  """
  @spec user_search() :: {module(), atom()} | nil
  def user_search, do: hook!(:user_search)

  @doc """
  The app's user labels for the dashboard (`{module, function}`), or nil when the app has
  none. Raises on any other value.
  """
  @spec user_labels() :: {module(), atom()} | nil
  def user_labels, do: hook!(:user_labels)

  defp get(key, default), do: Application.get_env(:udin_billing, key, default)

  defp one_of!(key, default, allowed) do
    case get(key, default) do
      value when is_atom(value) ->
        if value in allowed, do: value, else: invalid!(key, value, inspect(allowed))

      value ->
        invalid!(key, value, inspect(allowed))
    end
  end

  defp hook!(key) do
    case get(key, nil) do
      nil -> nil
      {module, function} = hook when is_atom(module) and is_atom(function) -> hook
      value -> invalid!(key, value, "{module, function} or nil")
    end
  end

  defp positive!(key, default) do
    case get(key, default) do
      value when is_integer(value) and value > 0 -> value
      value -> invalid!(key, value, "a positive integer")
    end
  end

  defp invalid!(key, value, expected) do
    raise ArgumentError,
          "invalid :udin_billing #{inspect(key)}: #{inspect(value)}, expected #{expected}"
  end
end
