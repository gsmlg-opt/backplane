defmodule Backplane.SkillProtocol do
  @moduledoc """
  Host-independent Skill document and bundle protocol primitives.
  """

  @protocol_version "1"
  @bundle_profile "backplane.skill-bundle.v1"

  def protocol_version, do: @protocol_version
  def bundle_profile, do: @bundle_profile
end
