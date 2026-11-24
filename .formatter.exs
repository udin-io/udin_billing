# Used by "mix format"
[
  import_deps: [:ash, :ash_postgres, :spark, :reactor, :phoenix],
  plugins: [Spark.Formatter, Phoenix.LiveView.HTMLFormatter],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs,heex}"]
]
