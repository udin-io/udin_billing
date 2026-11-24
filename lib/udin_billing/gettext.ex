defmodule UdinBilling.Gettext do
  @moduledoc """
  The translations of the billing dashboard (English and Arabic), as standard gettext
  files in `priv/gettext`.

  ## Why gettext
  Both host apps already translate with gettext. Translators work in `.po` files, plural
  rules for each language (Arabic has six forms) come from gettext itself, and
  `mix gettext.extract --check-up-to-date` catches a text that was added without being
  extracted.

  ## One file per page
  Each dashboard page has its own domain (`plans`, `plan_form`, `features`, `users`,
  `webhooks`, `payments`, `catalog`). Words every page uses live in `default`, and
  library messages shown to admins live in `errors`.

  ## How the language is chosen
  The dashboard sets the language of its own LiveView process on every page
  (`UdinBilling.Web.Auth`): the admin's own locale, or `?lang=`. Texts that describe a
  plan to its buyers use the preview language instead (`UdinBilling.Web.Text`).

  ## No project words
  The texts never name one project's own things (reels, rides, bundles). Examples in help
  texts come from the project's catalog (`UdinBilling.Web.Examples`).
  """
  use Gettext.Backend, otp_app: :udin_billing
end
