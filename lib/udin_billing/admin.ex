defmodule UdinBilling.Admin do
  @moduledoc """
  Everything an admin dashboard needs, for any app: the feature catalog, plans and their
  feature values, a user's billing panel, lists, and revenue.

  ## Authorization
  Every function takes the acting user and first checks the app's `:admin_check`
  (`UdinBilling.Config.admin?/1`), returning `{:error, :forbidden}` for anyone else.
  Queries also run with the actor, so resource policies apply as well.

  ## Lists: filters and pages
  List functions take `filters` (keyword) and `opts`:
    * filters: `user_id`, `plan_id`, `status` (atom or list), `kind`, `feature_key`,
      `provider`, `from` / `to` (`inserted_at`, `to` exclusive), `paid_from` / `paid_to`.
    * `opts[:page]`, e.g. `[limit: 20, offset: 40, count: true]` → `Ash.Page.Offset`;
      without it, a plain list. `opts[:sort]` (default newest first), `opts[:load]`.
  An unknown filter raises, so a typo is never silently ignored.
  """
  require Ash.Query

  alias UdinBilling.{
    Access,
    Config,
    Feature,
    Plan,
    ProviderEvent,
    Purchase,
    Purchases,
    Subscription,
    Usage
  }

  @type actor :: term()
  @type result(value) :: {:ok, value} | {:error, :forbidden | term()}
  @type list_result :: result([struct()] | Ash.Page.Offset.t())

  # -- feature catalog --------------------------------------------------------

  @doc "Lists the feature catalog in display order."
  @spec list_features(actor()) :: list_result()
  def list_features(actor), do: list(Feature, actor, [], sort: [sort_order: :asc, key: :asc])

  @doc """
  Adds a feature: `%{key: "share_recipe", kind: :switch, name: %{"en" => "Share recipes", "ar" => "مشاركة الوصفات"}}`
  or a `:counter` like `"reel_imports"`. It's off/0 in every plan until set there.
  """
  @spec create_feature(map(), actor()) :: result(struct())
  def create_feature(attrs, actor) do
    with :ok <- authorize(actor), do: Ash.create(Feature, attrs, actor: actor)
  end

  @doc "Renames or re-describes a feature (its key and kind are fixed)."
  @spec update_feature(struct(), map(), actor()) :: result(struct())
  def update_feature(feature, attrs, actor) do
    with :ok <- authorize(actor) do
      feature |> Ash.Changeset.for_update(:update, attrs, actor: actor) |> Ash.update()
    end
  end

  @doc "Deletes a feature no plan uses."
  @spec delete_feature(struct(), actor()) :: :ok | {:error, term()}
  def delete_feature(feature, actor) do
    with :ok <- authorize(actor), do: Ash.destroy(feature, actor: actor)
  end

  # -- plans ------------------------------------------------------------------

  @doc "Lists plans, including inactive ones (default sort: `sort_order`, then price)."
  @spec list_plans(actor(), keyword(), keyword()) :: list_result()
  def list_plans(actor, filters \\ [], opts \\ []),
    do: list(Plan, actor, filters, Keyword.put_new(opts, :sort, sort_order: :asc, price: :asc))

  @doc "Fetches one plan."
  @spec get_plan(Ecto.UUID.t(), actor()) :: result(struct())
  def get_plan(plan_id, actor) do
    with :ok <- authorize(actor), do: Ash.get(Plan, plan_id, actor: actor)
  end

  @doc """
  Creates a plan. `attrs` are `UdinBilling.Plan` fields plus `features`, a map of catalog
  key to value: `%{"reel_imports" => 15, "share_recipe" => true, "rides" => :unlimited}`.
  """
  @spec create_plan(map(), actor()) :: result(struct())
  def create_plan(attrs, actor) do
    with :ok <- authorize(actor), do: Ash.create(Plan, attrs, actor: actor)
  end

  @doc """
  Updates a plan. Passing `features` replaces all its feature values; leaving it out keeps
  them. Existing buyers keep the terms they bought.
  """
  @spec update_plan(struct(), map(), actor()) :: result(struct())
  def update_plan(plan, attrs, actor) do
    with :ok <- authorize(actor) do
      plan |> Ash.Changeset.for_update(:update, attrs, actor: actor) |> Ash.update()
    end
  end

  @doc "Puts a plan back on sale."
  @spec activate_plan(struct(), actor()) :: result(struct())
  def activate_plan(plan, actor), do: run_update(plan, :activate, actor)

  @doc """
  Takes a plan off sale. Buyers keep it until their paid period ends and it doesn't renew
  where we control renewal (see `UdinBilling.Subscriptions`).
  """
  @spec deactivate_plan(struct(), actor()) :: result(struct())
  def deactivate_plan(plan, actor), do: run_update(plan, :deactivate, actor)

  @doc """
  Replaces `old_plan` with a new version: creates a plan from `attrs` and takes the old
  one off sale, in one transaction (both or neither). This is how a sold plan's price or
  contents change. The old plan's buyers keep it until their paid period ends; it doesn't
  renew where the library controls renewal. The new version needs its own store product
  ids (product ids are unique across plans).
  """
  @spec replace_plan(struct(), map(), actor()) :: result(%{new: struct(), old: struct()})
  def replace_plan(old_plan, attrs, actor) do
    with :ok <- authorize(actor) do
      UdinBilling.Transaction.run([Plan, UdinBilling.PlanFeature], fn ->
        with {:ok, new} <- Ash.create(Plan, attrs, actor: actor),
             {:ok, old} <-
               old_plan
               |> Ash.Changeset.for_update(:deactivate, %{}, actor: actor)
               |> Ash.update() do
          {:ok, %{new: new, old: old}}
        end
      end)
    end
  end

  @doc """
  A plan as a table row: localized name, kind, price, validity and cycle, every catalog
  feature's value (missing ones show as off/0), status and dates.
  """
  @spec plan_row(struct(), [struct()], String.t()) :: map()
  def plan_row(plan, catalog, locale \\ UdinBilling.Config.default_locale()) do
    %{
      id: plan.id,
      code: plan.code,
      name: Plan.localized(plan, :name, locale),
      kind: plan.kind,
      period: Plan.period_label(plan),
      validity: period(plan.validity_unit, plan.validity_count),
      cycle: period(plan.cycle_unit, plan.cycle_count),
      price: plan.price,
      currency: plan.currency,
      features: Map.new(catalog, &{&1.key, Map.get(plan.features, &1.key, default_value(&1))}),
      status: plan.status,
      metadata: plan.metadata,
      inserted_at: plan.inserted_at,
      updated_at: plan.updated_at
    }
  end

  # -- users ------------------------------------------------------------------

  @doc """
  Gives `user_id` a one-time plan for free (support gesture, compensation): a paid purchase
  of amount 0 from provider `"admin"`, with `reason` and the admin's id in its metadata.
  """
  @spec grant_plan(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), actor()) :: result(struct())
  def grant_plan(user_id, plan_id, reason, actor) do
    with :ok <- authorize(actor) do
      Purchases.record_paid(user_id, plan_id, "admin", "admin:" <> Ecto.UUID.generate(),
        amount: Decimal.new(0),
        metadata: %{"reason" => reason, "granted_by" => actor_id(actor)}
      )
    end
  end

  @user_search_limit 10

  @doc """
  Finds users by what the admin typed, through the app's `:user_search` hook (see
  `UdinBilling.Config`): a phone number, an email, whatever the app supports.

  Returns `{:ok, matches}` with at most #{@user_search_limit} `%{id: id, label: label}`,
  `{:error, :not_configured}` when the app has no hook, or `{:error, :forbidden}` for a
  non admin. Raises when the hook answers anything but a list of such maps, so a broken
  hook is found at once instead of showing "no user found".
  """
  @spec search_users(String.t(), actor()) ::
          result([%{id: Ecto.UUID.t(), label: String.t()}]) | {:error, :not_configured}
  def search_users(query, actor) do
    with :ok <- authorize(actor),
         {module, function} <- Config.user_search() || {:error, :not_configured} do
      matches = apply(module, function, [query])
      {:ok, matches |> validate_matches!(module, function) |> Enum.take(@user_search_limit)}
    end
  end

  defp validate_matches!(matches, module, function) when is_list(matches) do
    Enum.map(matches, fn
      %{id: id, label: label} when is_binary(id) and is_binary(label) ->
        %{id: id, label: label}

      other ->
        raise ArgumentError,
              ":udin_billing :user_search #{inspect(module)}.#{function}/1 returned " <>
                "#{inspect(other)} in its list, expected %{id: user_id, label: text}"
    end)
  end

  defp validate_matches!(other, module, function) do
    raise ArgumentError,
          ":udin_billing :user_search #{inspect(module)}.#{function}/1 returned " <>
            "#{inspect(other)}, expected a list of %{id: user_id, label: text}"
  end

  @doc """
  Labels for `user_ids` from the app's `:user_labels` hook (see `UdinBilling.Config`), in
  one call: `{:ok, %{user_id => label}}`. Ids the app doesn't label are left out, so
  callers fall back to the id. Without the hook it's `{:ok, %{}}`, and a non admin gets
  `{:error, :forbidden}`. Raises when the hook answers anything but a map of texts.
  """
  @spec user_labels([Ecto.UUID.t()], actor()) :: result(%{Ecto.UUID.t() => String.t()})
  def user_labels(user_ids, actor) do
    with :ok <- authorize(actor) do
      case {Config.user_labels(), Enum.uniq(user_ids)} do
        {nil, _ids} -> {:ok, %{}}
        {_hook, []} -> {:ok, %{}}
        {{module, function}, ids} -> {:ok, call_labels!(module, function, ids)}
      end
    end
  end

  defp call_labels!(module, function, ids) do
    case apply(module, function, [ids]) do
      labels when is_map(labels) ->
        Map.filter(labels, fn
          {id, label} when is_binary(id) and is_binary(label) -> true
          entry -> invalid_labels!(module, function, entry)
        end)

      other ->
        invalid_labels!(module, function, other)
    end
  end

  defp invalid_labels!(module, function, value) do
    raise ArgumentError,
          ":udin_billing :user_labels #{inspect(module)}.#{function}/1 returned " <>
            "#{inspect(value)}, expected a map of %{user_id => text}"
  end

  @doc """
  One user's read-only billing panel: each counter's balance and reset time,
  the switches that are on, and the plans granting them.
  """
  @spec user_overview(Ecto.UUID.t(), actor(), keyword()) :: result(map())
  def user_overview(user_id, actor, opts \\ []) do
    with :ok <- authorize(actor) do
      access = Access.load(user_id, opts)

      {:ok,
       %{
         counters: access.counters,
         switches: access.switches |> MapSet.to_list() |> Enum.sort(),
         sources:
           Enum.map(
             access.sources,
             &Map.take(&1, [:kind, :plan_id, :purchase_id, :subscription_id, :anchor, :ends_at])
           )
       }}
    end
  end

  @doc "Lists purchases, newest first."
  @spec list_purchases(actor(), keyword(), keyword()) :: list_result()
  def list_purchases(actor, filters \\ [], opts \\ []), do: list(Purchase, actor, filters, opts)

  @doc "Lists subscriptions, newest first."
  @spec list_subscriptions(actor(), keyword(), keyword()) :: list_result()
  def list_subscriptions(actor, filters \\ [], opts \\ []),
    do: list(Subscription, actor, filters, opts)

  @doc "Lists the usage history (holds, commits, releases), newest first."
  @spec list_usages(actor(), keyword(), keyword()) :: list_result()
  def list_usages(actor, filters \\ [], opts \\ []), do: list(Usage, actor, filters, opts)

  @doc "Lists stored provider messages; `status: :failed` shows the ones needing a human."
  @spec list_provider_events(actor(), keyword(), keyword()) :: list_result()
  def list_provider_events(actor, filters \\ [], opts \\ []),
    do: list(ProviderEvent, actor, filters, opts)

  @doc "Applies a stored provider message again after its cause was fixed."
  @spec replay_provider_event(Ecto.UUID.t(), actor()) :: result(UdinBilling.Webhooks.outcome())
  def replay_provider_event(id, actor) do
    with :ok <- authorize(actor), do: UdinBilling.Webhooks.replay(id)
  end

  # -- catalog (features + plans as one file) ---------------------------------

  @doc "The current features and plans as catalog JSON text (see `UdinBilling.Catalog`)."
  @spec export_catalog(actor()) :: result(String.t())
  def export_catalog(actor) do
    with :ok <- authorize(actor),
         do: {:ok, UdinBilling.Catalog.encode(UdinBilling.Catalog.export())}
  end

  @doc """
  What importing catalog JSON text would change (`dry_run: true`), or applies it.
  Takes `UdinBilling.Catalog.apply_catalog/2`'s options.
  """
  @spec import_catalog(String.t(), actor(), keyword()) ::
          result(UdinBilling.Catalog.changes()) | {:error, [String.t()]}
  def import_catalog(json, actor, opts \\ []) do
    with :ok <- authorize(actor),
         {:ok, catalog} <- UdinBilling.Catalog.decode(json) do
      if opts[:dry_run],
        do: {:ok, UdinBilling.Catalog.changes(catalog)},
        else: UdinBilling.Catalog.apply_catalog(catalog, opts)
    end
  end

  # -- reporting --------------------------------------------------------------

  @doc """
  Money from one-time purchases received in `[from, to)`, per currency, at the amounts
  actually paid: `gross`, `refunded`, `awaiting_refund` (paid after a checkout was
  cancelled), `net` (gross − refunded − awaiting refund), and counts. Gifts count with
  amount 0. Store subscription revenue is reported by the stores. Rows are streamed in
  batches, so long ranges stay light on memory.
  """
  @spec revenue(actor(), DateTime.t(), DateTime.t()) :: result([map()])
  def revenue(actor, from, to) do
    with {:ok, purchases} <- paid_between(actor, from, to, []) do
      {:ok,
       purchases
       |> Enum.reduce(%{}, fn purchase, acc ->
         {currency, _amount} = received(purchase)

         Map.update(
           acc,
           currency,
           add_revenue(new_revenue(currency), purchase),
           &add_revenue(&1, purchase)
         )
       end)
       |> Map.values()
       |> Enum.map(
         &%{&1 | net: &1.gross |> Decimal.sub(&1.refunded) |> Decimal.sub(&1.awaiting_refund)}
       )
       |> Enum.sort_by(& &1.currency)}
    end
  end

  @doc "Purchases per plan and currency in `[from, to)`, best sellers first (late payments excluded)."
  @spec sales_by_plan(actor(), DateTime.t(), DateTime.t()) :: result([map()])
  def sales_by_plan(actor, from, to) do
    with {:ok, purchases} <- paid_between(actor, from, to, [:plan]) do
      {:ok,
       purchases
       |> Stream.reject(&(&1.status == :refund_required))
       |> Enum.reduce(%{}, fn p, acc ->
         Map.update(acc, {p.plan_id, p.currency}, new_sale(p), &add_sale(&1, p))
       end)
       |> Map.values()
       |> Enum.sort_by(& &1.purchases, :desc)}
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp authorize(actor), do: if(Config.admin?(actor), do: :ok, else: {:error, :forbidden})

  defp run_update(record, action, actor) do
    with :ok <- authorize(actor) do
      record |> Ash.Changeset.for_update(action, %{}, actor: actor) |> Ash.update()
    end
  end

  defp list(resource, actor, filters, opts) do
    with :ok <- authorize(actor) do
      resource
      |> Ash.Query.new()
      |> apply_filters(filters)
      |> Ash.Query.sort(Keyword.get(opts, :sort, inserted_at: :desc))
      |> Ash.Query.load(Keyword.get(opts, :load, []))
      |> Ash.read(Keyword.merge([actor: actor], Keyword.take(opts, [:page])))
    end
  end

  defp apply_filters(query, filters), do: Enum.reduce(filters, query, &apply_filter(&2, &1))

  defp apply_filter(query, {:user_id, id}), do: Ash.Query.filter(query, user_id == ^id)
  defp apply_filter(query, {:plan_id, id}), do: Ash.Query.filter(query, plan_id == ^id)
  defp apply_filter(query, {:feature_key, key}), do: Ash.Query.filter(query, feature_key == ^key)
  defp apply_filter(query, {:kind, kind}), do: Ash.Query.filter(query, kind == ^kind)

  defp apply_filter(query, {:provider, provider}),
    do: Ash.Query.filter(query, provider == ^to_string(provider))

  defp apply_filter(query, {:status, list}) when is_list(list),
    do: Ash.Query.filter(query, status in ^list)

  defp apply_filter(query, {:status, status}), do: Ash.Query.filter(query, status == ^status)
  defp apply_filter(query, {:from, from}), do: Ash.Query.filter(query, inserted_at >= ^from)
  defp apply_filter(query, {:to, to}), do: Ash.Query.filter(query, inserted_at < ^to)
  defp apply_filter(query, {:paid_from, from}), do: Ash.Query.filter(query, paid_at >= ^from)
  defp apply_filter(query, {:paid_to, to}), do: Ash.Query.filter(query, paid_at < ^to)

  defp apply_filter(_query, {key, _value}),
    do: raise(ArgumentError, "unsupported admin filter #{inspect(key)}")

  # Purchases whose money arrived in the range, streamed in batches. Refunded and
  # refund-required ones were paid too: they count in gross and again below.
  defp paid_between(actor, from, to, load) do
    with :ok <- authorize(actor) do
      {:ok,
       Purchase
       |> Ash.Query.filter(
         status in [:paid, :refunded, :refund_required] and paid_at >= ^from and paid_at < ^to
       )
       |> Ash.Query.load(load)
       |> Ash.stream!(actor: actor, batch_size: 500)}
    end
  end

  # Late payments keep the provider-reported figures in metadata; otherwise the paid
  # amount equals the copied price, because confirmation refuses any mismatch.
  defp received(%{metadata: %{"paid_amount" => amount, "paid_currency" => currency}}),
    do: {currency, Decimal.new(amount)}

  defp received(%{currency: currency, amount: amount}), do: {currency, amount}

  defp new_revenue(currency) do
    zero = Decimal.new(0)

    %{
      currency: currency,
      gross: zero,
      refunded: zero,
      awaiting_refund: zero,
      net: zero,
      purchases: 0,
      refunds: 0
    }
  end

  defp add_revenue(row, purchase) do
    {_currency, amount} = received(purchase)
    row = %{row | gross: Decimal.add(row.gross, amount), purchases: row.purchases + 1}

    case purchase.status do
      :refunded -> %{row | refunded: Decimal.add(row.refunded, amount), refunds: row.refunds + 1}
      :refund_required -> %{row | awaiting_refund: Decimal.add(row.awaiting_refund, amount)}
      :paid -> row
    end
  end

  defp new_sale(p),
    do: %{
      plan_id: p.plan_id,
      plan_code: p.plan.code,
      currency: p.currency,
      purchases: 1,
      gross: p.amount
    }

  defp add_sale(row, p),
    do: %{row | purchases: row.purchases + 1, gross: Decimal.add(row.gross, p.amount)}

  defp period(nil, _count), do: nil
  defp period(unit, count), do: %{unit: unit, count: count}

  defp default_value(%Feature{kind: :switch}), do: false
  defp default_value(%Feature{kind: :counter}), do: 0

  defp actor_id(%{id: id}), do: id
  defp actor_id(_actor), do: nil
end
