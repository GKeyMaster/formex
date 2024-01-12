defmodule Formex.Validator do
  alias Formex.Form
  alias Formex.FormCollection
  alias Formex.FormNested

  @moduledoc """
  Validator behaviour.

  In Formex you can use any validation library. Of course, if proper adapter is already implemented.

  # Available adapters:

  * `Formex.Validator.Simple`
  * [Vex](https://github.com/jakub-zawislak/formex_vex)
  * [Ecto.Changeset](https://github.com/jakub-zawislak/formex_ecto)

  # Installation

  Setting default validator:

  `config/config.exs`
  ```
  config :formex,
    validator: Formex.Validator.Vex
  ```

  Using another validator in a specific form type

  ```
  def build_form(form) do
    form
    |> add(:name, :text_input)
    # ...
  end

  def validator, do: Formex.Validator.Vex
  ```

  If you want to translate errors messages, set a translation function in config:

  ```
  config :formex,
    translate_error: &AppWeb.ErrorHelpers.translate_error/1
  ```

  or, if you can't use function capture in config
  (for example with Distillery, [issue #12](https://github.com/jakub-zawislak/formex/issues/12)),
  set this option in every form type:

  ```
  def build_form(form) do
    form
    |> add(:name, :text_input)
    # ...
  end

  def translate_error, do: &AppWeb.ErrorHelpers.translate_error/1
  ```

  The `&AppWeb.ErrorHelpers.translate_error/1` is a function generated by Phoenix in
  `/lib/app_web/views/error_helpers.ex`. You can also set your own similar function.

  # Implementing adapter for another library

  See implementation for [Vex](https://github.com/jakub-zawislak/formex_vex) for example.

  """

  @callback validate(form :: Formex.Form.t()) :: List.t()

  @spec validate(Form.t()) :: Form.t()
  def validate(form) do
    validator = get_validator(form)

    form =
      form
      |> validator.validate
      |> add_invalid_select_errors
      |> translate_errors

    items =
      form.items
      |> Enum.map(fn item ->
        case item do
          collection = %FormCollection{} ->
            %{
              collection
              | forms:
                  Enum.map(collection.forms, fn nested ->
                    if FormCollection.to_be_removed(item, nested) do
                      %{nested | form: %{nested.form | valid?: true}}
                    else
                      %{nested | form: validate(nested.form)}
                    end
                  end)
            }

          nested = %FormNested{} ->
            %{nested | form: validate(nested.form)}

          _ ->
            item
        end
      end)

    form = %{form | items: items}

    Map.put(form, :valid?, valid?(form))
  end

  #

  @doc false
  def translate_errors(form) do
    translate_error =
      form.type.translate_error || Application.get_env(:formex, :translate_error) ||
        fn {msg, _opts} -> msg end

    errors =
      form.errors
      |> Enum.map(fn {key, suberrors} ->
        suberrors = Enum.map(suberrors, &translate_error.(&1))

        {key, suberrors}
      end)

    %{form | errors: errors}
  end

  @spec get_validator(form :: Form.t()) :: any
  defp get_validator(form) do
    form.type.validator || Application.get_env(:formex, :validator)
  end

  @spec valid?(Form.t()) :: boolean
  defp valid?(form) do
    valid? =
      Enum.reduce_while(form.errors, true, fn {_k, v}, _acc ->
        if Enum.count(v) > 0,
          do: {:halt, false},
          else: {:cont, true}
      end)

    valid? && nested_valid?(form) && collections_valid?(form)
  end

  @spec nested_valid?(Form.t()) :: boolean
  defp nested_valid?(form) do
    form
    |> Form.get_nested()
    |> Enum.reduce_while(true, fn item, _acc ->
      if item.form.valid?,
        do: {:cont, true},
        else: {:halt, false}
    end)
  end

  @spec collections_valid?(Form.t()) :: boolean
  defp collections_valid?(form) do
    form
    |> Form.get_collections()
    |> Enum.reduce_while(true, fn collection, _acc ->
      collection.forms
      |> Enum.reduce_while(true, fn item, _sub_acc ->
        if item.form.valid?,
          do: {:cont, true},
          else: {:halt, false}
      end)
      |> case do
        true -> {:cont, true}
        false -> {:halt, false}
      end
    end)
  end

  @spec add_invalid_select_errors(Form.t()) :: Form.t()
  defp add_invalid_select_errors(form) do
    select_errors =
      form.items
      |> Enum.filter(&(&1.type in [:select, :multiple_select]))
      |> Enum.map(fn item ->
        if item.data[:invalid_select] do
          {item.name, [{"invalid value", []}]}
        end
      end)
      |> Enum.filter(& &1)

    add_errors(form, select_errors)
  end

  @spec add_errors(Form.t(), List.t()) :: Form.t()
  defp add_errors(form, new_errors) do
    new_errors =
      Keyword.merge(form.errors, new_errors, fn _k, field_errors1, field_errors2 ->
        field_errors1 ++ field_errors2
      end)

    %{form | errors: new_errors}
  end
end