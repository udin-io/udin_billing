# The package has no supervision tree of its own (hosts own their repo), so the test
# repo is started here.
{:ok, _} = UdinBilling.TestRepo.start_link()
{:ok, _} = UdinBilling.Test.Web.Endpoint.start_link()

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(UdinBilling.TestRepo, :manual)
