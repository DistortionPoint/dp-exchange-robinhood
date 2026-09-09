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

  ## The wrap lives in `child_spec/1`, so bypassing it bypasses the redaction

  `child_spec/1` is where `wrap_opt/1` is applied, because a supervisor captures the
  `{module, :start_link, [opts]}` MFA before `start_link/1` or `init/1` ever runs — see
  `wrap_opt/1`'s own doc. A consumer who uses the supported `{DpExchange.X, credentials:
  ...}` child form gets the redaction for free.

  **A consumer who builds the child spec themselves does not**, and upgrading this package
  will not change that: their supervisor stores the raw map and OTP renders it on the next
  crash, with nothing from this package on that path to intervene. It is a real path with a
  real reason — a caller needing a delivery target other than the supervisor has to reach
  `start_link/1` directly — so `wrap/1` and `wrap_opt/1` are **public** for it. Reported by
  a consumer who went looking for their canary in supervisor state after upgrading and
  found it; the natural assumption, "upgraded, therefore redacted", is wrong there.

  The same applies to a host that *reshapes* a credential before handing it over — mapping
  its own key names into this venue's and returning a bare map re-introduces the leak
  downstream of anything this package can reach.
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

  @doc """
  Wraps the `:credentials` entry of an options keyword list, IN PLACE and only when that
  key is actually present.

  This is what keeps a raw secret out of a **supervisor's stored child spec**, and it has
  to be applied in `child_spec/1` — nowhere later is early enough. A supervisor holds the
  `{module, :start_link, [opts]}` MFA it was handed, and OTP writes that argument list
  through `inspect/1` into the `Start Call:` line of the report it logs whenever the child
  terminates. Wrapping inside `start_link/1` or `init/1` does nothing for it: by then the
  raw list has already been captured by the supervisor above.

  dp-exchange-core issue #29 — a consumer found live API keys in cleartext in ordinary
  application logs, produced by any child crash at all, and nearly pasted them into a
  GitHub issue while reporting a different bug.
  """
  @spec wrap_opt(keyword()) :: keyword()
  def wrap_opt(opts) do
    case Keyword.fetch(opts, :credentials) do
      {:ok, credentials} when is_map(credentials) ->
        Keyword.put(opts, :credentials, wrap(credentials))

      _absent_or_not_a_map ->
        opts
    end
  end
end
