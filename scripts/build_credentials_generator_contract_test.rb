#!/usr/bin/env ruby
# frozen_string_literal: true

require "tmpdir"
require_relative "generate_build_credentials"

failures = []

check = lambda do |name, &block|
  block.call
  puts "PASS #{name}"
rescue StandardError => e
  failures << "#{name}: #{e.message}"
  warn "FAIL #{name}: #{e.message}"
end

assert = lambda do |condition, message|
  raise message unless condition
end

check.call("environment values take precedence over dotenv") do
  Dir.mktmpdir("willdeep-build-credentials") do |directory|
    env_file = File.join(directory, ".env.local")
    output = File.join(directory, "BuildCredentials.generated.swift")
    File.write(
      env_file,
      <<~ENV
        WILLDEEP_CLIENT_LOGIN_SECRET=dotenv-login
        AIPIPE_API_KEY=dotenv-aipipe
        AIPIPE_ENDPOINT=https://dotenv.example/api/v1
        AIPIPE_TOPIC=dotenv-topic
      ENV
    )

    WillDeepBuildCredentials.write(
      output: output,
      env_file: env_file,
      environment: {
        "AIPIPE_API_KEY" => "environment-aipipe",
        "AIPIPE_TOPIC" => "environment-topic",
      }
    )

    source = File.read(output)
    assert.call(source.include?('"environment-aipipe"'), "environment API key was not generated")
    assert.call(source.include?('"environment-topic"'), "environment topic was not generated")
    assert.call(source.include?('"dotenv-login"'), "dotenv login secret fallback was not generated")
    assert.call(source.include?('"https://dotenv.example/api/v1"'), "dotenv endpoint fallback was not generated")
    assert.call(!source.include?("dotenv-aipipe"), "dotenv API key incorrectly overrode the environment")
  end
end

check.call("missing optional values generate empty Swift constants") do
  Dir.mktmpdir("willdeep-build-credentials") do |directory|
    output = File.join(directory, "BuildCredentials.generated.swift")
    WillDeepBuildCredentials.write(
      output: output,
      env_file: File.join(directory, "missing.env"),
      environment: {}
    )

    source = File.read(output)
    assert.call(source.scan('= ""').length == 4, "expected four empty generated constants")
  end
end

abort failures.join("\n") unless failures.empty?
puts "build_credentials_generator_contract_test: pass checks=2"
