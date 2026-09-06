# frozen_string_literal: true

module SwiftTestingSummary
  def self.passed_count(output)
    plain = output.gsub(/\e\[[\d;]*m/, "")
    plain.scan(/^[✔✓] Test run with (\d+) tests?(?: in \d+ suites?)? passed\b/)
      .flatten.last&.to_i || 0
  end
end
