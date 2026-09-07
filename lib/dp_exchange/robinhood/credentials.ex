defmodule DpExchange.Robinhood.Credentials do
  @moduledoc """
  Wraps the `api_key`/`private_key` pair so it can sit in a `GenServer`'s state without
  printing in full the moment that process crashes.

  ## The incident this closes

  `Rest.get_top_of_book/3` itself is stateless — `Auth.headers/5`'s own moduledoc already
  says "signs one request, and keeps nothing." But `Feed` keeps a copy of `state.credentials`
  for its whole lifetime anyway: `start_poller/1` closes over it to build the `fetch`
  callback `Core.PollingFeed` calls on every tick, and a crash-restart (`init/1` running
  again from `Feed`'s own supervisor) needs the original value to rebuild that closure,
  since `PollingFeed`'s own state does not survive its parent's crash. OTP's default
  crash report prints a `GenServer`'s state in full on termination, and a **plain map**
  field prints every key including the raw Ed25519 seed — verified against a real crash
  of an equivalent process holding `%{api_key: "...", private_key: "..."}` as a bare
  state field.

  A struct whose `Inspect` is derived with `except:` naming both fields closes this:
  `Kernel.inspect/1` — which both the crash-report formatter and a `FunctionClauseError`'s
  printed argument list go through — honours a struct's `Inspect` protocol even nested
  inside an otherwise-plain state map. Wrapping once, in `Feed.init/1`, keeps
  `Rest.get_top_of_book/3` and `Auth.headers/5` working unchanged: a struct is a map, and
  `Auth.decode_seed/1` reads `credentials.private_key` the same way whether the struct or
  the original map is behind it.
  """

  @derive {Inspect, except: [:api_key, :private_key]}
  defstruct [:api_key, :private_key]

  @type t :: %__MODULE__{api_key: String.t() | nil, private_key: String.t() | nil}

  @doc """
  Wraps a raw credentials map for storage in process state.

  Any map is struct-ified with `Kernel.struct/2`, which ignores keys the struct does not
  declare rather than raising — matching how `Auth.headers/5` already reads this map, by
  pattern-matching only the keys it needs.
  """
  @spec wrap(map()) :: t()
  def wrap(%__MODULE__{} = credentials), do: credentials
  def wrap(credentials) when is_map(credentials), do: struct(__MODULE__, credentials)
end
