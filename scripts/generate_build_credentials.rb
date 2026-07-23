#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"

module WillDeepBuildCredentials
  DOTENV_KEYS = %w[
    WILLDEEP_CLIENT_LOGIN_SECRET
    AIPIPE_API_KEY
    AIPIPE_ENDPOINT
    AIPIPE_TOPIC
  ].freeze

  module_function

  def dotenv_values(path)
    return {} unless File.file?(path)

    allowed = DOTENV_KEYS.to_h { |key| [key, true] }
    File.readlines(path, chomp: true).each_with_object({}) do |raw_line, values|
      line = raw_line.strip
      next if line.empty? || line.start_with?("#")

      assignment = line.sub(/\Aexport\s+/, "")
      key, raw_value = assignment.split("=", 2)
      key = key.to_s.strip
      next unless allowed[key] && raw_value

      values[key] = unquote(raw_value)
    end
  end

  def unquote(value)
    raw = value.to_s.strip
    return raw if raw.length < 2
    return raw unless %w[" '].include?(raw[0]) && raw[-1] == raw[0]

    raw[1...-1]
  end

  def resolved_values(environment:, env_file:)
    dotenv = dotenv_values(env_file)
    DOTENV_KEYS.to_h do |key|
      environment_value = environment.fetch(key, "").to_s.strip
      value = environment_value.empty? ? dotenv.fetch(key, "").to_s.strip : environment_value
      [key, value]
    end
  end

  def swift_source(values)
    <<~SWIFT
      import Foundation

      enum SomeIMGeneratedClientLoginSecret {
          static let value = #{JSON.generate(values.fetch("WILLDEEP_CLIENT_LOGIN_SECRET"))}
      }

      enum AIPipeGeneratedBuildConfiguration {
          static let apiKey = #{JSON.generate(values.fetch("AIPIPE_API_KEY"))}
          static let endpoint = #{JSON.generate(values.fetch("AIPIPE_ENDPOINT"))}
          static let topic = #{JSON.generate(values.fetch("AIPIPE_TOPIC"))}
      }
    SWIFT
  end

  def write(output:, env_file:, environment: ENV)
    values = resolved_values(environment: environment, env_file: env_file)
    File.write(output, swift_source(values))
  end

  def run(argv)
    options = {}
    OptionParser.new do |parser|
      parser.on("--output PATH") { |value| options[:output] = File.expand_path(value) }
      parser.on("--env-file PATH") { |value| options[:env_file] = File.expand_path(value) }
    end.parse!(argv)

    abort "missing --output" unless options[:output]
    abort "missing --env-file" unless options[:env_file]

    write(output: options.fetch(:output), env_file: options.fetch(:env_file))
  end
end

WillDeepBuildCredentials.run(ARGV) if $PROGRAM_NAME == __FILE__
