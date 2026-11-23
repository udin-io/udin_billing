defmodule UdinBilling.Web.FeatureForm do
  @moduledoc """
  Converts between a catalog feature and the dashboard's feature form
  (`UdinBilling.Web.FeaturesLive`).

  A feature's `key` and `kind` are fixed once created (plans and app code refer to the
  key; changing a switch into a counter would break existing plan values), so only new
  features take them. Name and description have one field per configured language.
  """
  use Gettext, backend: UdinBilling.Gettext

  import UdinBilling.Web.Fields, only: [put: 3, put_required: 5, put_translations: 4, text: 1]

  alias UdinBilling.Web.Fields

  @kinds %{"switch" => :switch, "counter" => :counter}

  @type params :: %{String.t() => term()}

  @doc "Kind choices as `{label, value}`."
  @spec kind_options() :: [{String.t(), String.t()}]
  def kind_options,
    do: [
      {dgettext("features", "Switch (on or off)"), "switch"},
      {dgettext("features", "Counter (a number of units)"), "counter"}
    ]

  @doc "Form params for `feature`, or for a new one when nil."
  @spec from_feature(struct() | nil) :: params()
  def from_feature(nil) do
    %{
      "key" => "",
      "kind" => "switch",
      "name" => Fields.blank_translations(),
      "description" => Fields.blank_translations(),
      "sort_order" => "0"
    }
  end

  def from_feature(feature) do
    %{
      "key" => feature.key,
      "kind" => Atom.to_string(feature.kind),
      "name" => Fields.translation_params(feature.name),
      "description" => Fields.translation_params(feature.description),
      "sort_order" => to_string(feature.sort_order)
    }
  end

  @doc """
  Attributes for `UdinBilling.Admin.create_feature/2` (`new?: true`, with key and kind) or
  `update_feature/3`, or `{:error, %{field => message}}`.
  """
  @spec to_attrs(params(), boolean()) :: {:ok, map()} | {:error, %{String.t() => String.t()}}
  def to_attrs(params, new?) do
    {%{}, %{}}
    |> put_identity(params, new?)
    |> put_translations(:name, params["name"], true)
    |> put_translations(:description, params["description"], false)
    |> put(:sort_order, Fields.integer(params["sort_order"]) || 0)
    |> case do
      {attrs, errors} when errors == %{} ->
        {:ok, attrs}

      {_attrs, errors} ->
        {:error, Map.new(errors, fn {field, text} -> {field, localize(text)} end)}
    end
  end

  # Messages from `UdinBilling.Web.Fields` are English at the source. This form shows them
  # in the admin's language, so they are rendered here, inside the LiveView process.
  defp localize("required"), do: dgettext("features", "This is required.")

  defp localize("fill every language or leave all empty"),
    do: dgettext("features", "Fill in every language, or leave them all empty.")

  defp localize(other), do: other

  defp put_identity(acc, params, true) do
    acc
    |> put_required(
      :key,
      text(params["key"]),
      "key",
      dgettext(
        "features",
        "This is required. Use lowercase letters, numbers and underscores, and start with a letter."
      )
    )
    |> put_required(
      :kind,
      Map.get(@kinds, params["kind"]),
      "kind",
      dgettext("features", "Choose a switch or a counter.")
    )
  end

  defp put_identity(acc, _params, false), do: acc
end
