defmodule Reach.Test.ProtocolFormattingValue do
  defstruct [:path, raise?: false]
end

defimpl String.Chars, for: Reach.Test.ProtocolFormattingValue do
  def to_string(value) do
    File.write!(value.path, "called", [:append])
    if value.raise?, do: raise(ArgumentError, "protocol conversion failed")
    "status"
  end
end

defmodule Reach.Test.CompiledLazyDefault do
  def read, do: Application.get_env(:reach, :callback_mode, :use)
end
