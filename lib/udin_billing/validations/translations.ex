defmodule UdinBilling.Validations.Translations do
  @moduledoc """
  Validates a translated text attribute (see `UdinBilling.Translations`): only configured
  languages; every configured language when `required: true` or when any text is given.
  """
  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :attribute) do
      {:ok, attribute} when is_atom(attribute) -> {:ok, opts}
      _ -> {:error, "attribute option is required"}
    end
  end

  @impl true
  def validate(changeset, opts, _context) do
    attribute = opts[:attribute]

    case UdinBilling.Translations.validate(
           Ash.Changeset.get_attribute(changeset, attribute),
           Keyword.get(opts, :required, false)
         ) do
      :ok -> :ok
      {:error, message} -> {:error, field: attribute, message: message}
    end
  end
end
