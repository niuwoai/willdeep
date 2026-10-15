# frozen_string_literal: true

# Exercise the pinned plugin's planning and backend dispatch with local doubles.
# No provider is selected and the injected backend never opens a connection.
module VideoStudioReferenceProbe
  class Backend
    attr_reader :calls

    def initialize
      @calls = []
    end

    def name = "offline-reference-contract"

    def generate(**arguments)
      @calls << arguments
      raise ImageBackend::Error.new("offline_contract", "Intentional local stub", retryable: false)
    end
  end

  module_function

  def call(plugin_root:, generation_class: nil)
    require File.join(plugin_root, "server/lib/image_generation")
    generation_class ||= ImageGeneration
    store = Struct.new(:media_root).new("/offline-reference-contract")
    generator = generation_class.new(drama_service: store, host: nil,
      backend_selector: -> { raise "Provider selection is forbidden" },
      sleeper: ->(_) { raise "Unexpected second request" })
    slots = %w[a b].map do |name|
      { "semanticType" => "prop", "assetID" => name, "assetName" => name,
        "fileName" => "#{name}.png", "filePath" => "/offline-reference-contract/#{name}.png",
        "mediaURL" => "willdeep-plugin://bundle/__media__/#{name}.png" }
    end
    shot = { "id" => "shot", "startPrompt" => "Offline contract" }
    drama = { "characters" => [], "episodes" => [{ "id" => "episode", "shots" => [shot] }] }
    plan = with_compiled_slots(slots) do
      generator.send(:frame_plan, drama, { "episodeID" => "episode", "shotID" => "shot" }, "start")
    end
    backend = Backend.new
    generator.send(:run, plan.merge("size" => "1x1"), backend, ["offline"], 1, {}, "start", "contract")
    expected = slots.map { |slot| slot.fetch("filePath") }
    received = backend.calls.first&.fetch(:reference_paths, nil)
    { ok: plan["references"] == expected && received == expected && backend.calls.length == 1,
      planned_paths: plan["references"], backend_paths: received,
      mock_requests: backend.calls.length, real_provider_requests: 0 }
  end

  def with_compiled_slots(slots)
    original = ReferencePackage.method(:compile)
    compiled = { "ok" => true, "slots" => slots, "subjects" => [], "warnings" => [],
      "dropped" => [], "overLimit" => false }
    ReferencePackage.define_singleton_method(:compile) { |*_, **_| compiled }
    yield
  ensure
    ReferencePackage.define_singleton_method(:compile, original) if original
  end
end
