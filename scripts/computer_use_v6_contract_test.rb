#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "timeout"

ROOT = Pathname.new(__dir__).parent
HELPER = ROOT.join("ComputerUseHelper", "main.swift")
SCANNER = ROOT.join(
  "ComputerUseHelper",
  "SensitiveAccessibilityScanner.swift"
)
BRIDGE = ROOT.join("Xedit", "AgentComputerUseBridge.swift")
PROJECT = ROOT.join("Xedit.xcodeproj", "project.pbxproj")
DEFAULT_MARKDOWN_REPORT = "/tmp/xedit-computer-use-v6-contract.md"
DEFAULT_JSON_REPORT = "/tmp/xedit-computer-use-v6-contract.json"
HELPER_BINARY = "/tmp/willdeep-computer-use-v6-contract-helper"
MODULE_CACHE = "/tmp/willdeep-computer-use-v6-contract-module-cache"

markdown_path = Pathname.new(ARGV[0] || DEFAULT_MARKDOWN_REPORT)
json_path = Pathname.new(ARGV[1] || DEFAULT_JSON_REPORT)
helper_source = HELPER.read
scanner_source = SCANNER.read
bridge_source = BRIDGE.read
project_source = PROJECT.read
build_tree_source = helper_source[
  /private func buildTree\(.*?private func isSecureInputElement/m
] || ""
mutation_wrapper_source = helper_source[
  /private func withControlMutation<T>\(.*?private func beginControlMutation/m
] || ""
preview_source = helper_source[
  /private func captureControlPreview\(.*?private func waitFor/m
] || ""
state_source = helper_source[
  /private func getAppState\(.*?private func captureControlPreview/m
] || ""
checks = []

record = lambda do |name, ok, detail|
  checks << { name: name, ok: ok, detail: detail }
end

record.call(
  "protocol-v6",
  helper_source.include?('protocolVersion = "willdeep-computer-use.v6"') &&
    bridge_source.include?('expectedProtocolVersion = "willdeep-computer-use.v6"'),
  "Helper and Bridge agree on protocol v6"
)

lifecycle_actions = %w[
  start_control_session pause_control_session resume_control_session
  end_control_session
]
record.call(
  "single-lease-lifecycle",
  lifecycle_actions.all? { |action| helper_source.include?(%Q{"#{action}"}) } &&
    helper_source.include?("controlLeaseBusy") &&
    bridge_source.include?("controlLeaseID"),
  "lease lifecycle and conflict rejection are present"
)

record.call(
  "cancellation-generation-guard",
  bridge_source.include?("withTaskCancellationHandler") &&
    bridge_source.include?("abortGeneration") &&
    bridge_source.include?("generation responseGeneration") &&
    bridge_source.include?("outputBuffer.removeAll"),
  "cancellation, timeout, stdout and termination are generation-scoped"
)

record.call(
  "snapshot-coordinate-guard",
  helper_source.include?("snapshot_id is missing or no longer current") &&
    helper_source.include?("target window moved, resized, or changed") &&
    helper_source.include?("maximumWindowCaptureLongEdge = 1_568") &&
    helper_source.include?(".boundsIgnoreFraming") &&
    helper_source.include?("coordinate_space must be screenshot; arbitrary screen coordinates are forbidden.") &&
    !helper_source.include?('case "screen":'),
  "pixel actions use only the active downscaled window snapshot and reject stale or screen-space geometry"
)

record.call(
  "ax-window-identity",
  helper_source.include?("accessibilityWindow(") &&
    helper_source.include?("stableAccessibilityWindow(") &&
    helper_source.include?("windowBindingScore(") &&
    helper_source.include?("axWindowNumberAttribute") &&
    helper_source.include?("ElementReference") &&
    helper_source.include?("elementReference.windowID == snapshot.windowID") &&
    helper_source.include?("layer == 0"),
  "tree, refs, screenshots and visible layer-0 CGWindow identity are bound together"
)

record.call(
  "activation-verification",
  helper_source.include?("activateAndWaitUntilFrontmost(") &&
    helper_source.include?("raiseAccessibilityWindow(") &&
    helper_source.include?("NSWorkspace.shared.frontmostApplication") &&
    helper_source.include?("applicationActivationAttemptCount"),
  "application activation is verified, retried, and backed by AXRaise"
)

record.call(
  "physical-input-yield",
  helper_source.include?("CGEvent.tapCreate") &&
    helper_source.include?("syntheticEventUserDataTag") &&
    helper_source.include?("targetIsFrontmost") &&
    helper_source.include?("topmostVisibleWindow") &&
    helper_source.include?("physicalInputEpoch") &&
    helper_source.include?("validateControlEpochLocked") &&
    helper_source.include?("withControlMutation") &&
    helper_source.include?('"event": "user_input"') &&
    bridge_source.include?("userInputNotification") &&
    bridge_source.include?("handleUnsolicitedEvent"),
  "real input advances the epoch, pauses the topmost target and invalidates in-flight observations/actions"
)

mutation_precheck = mutation_wrapper_source.index(
  "try validateRegisteredMutation"
)
mutation_call = mutation_wrapper_source.index(
  "outcome = .success(try mutation())"
)
mutation_postcheck = mutation_wrapper_source.index(
  "closeControlMutation"
)
record.call(
  "mutation-input-preemption",
  helper_source.include?("private struct ActiveMutation") &&
    helper_source.include?("activeMutation = ActiveMutation(") &&
    !mutation_wrapper_source.include?("physicalInputEpochLock.lock()") &&
    mutation_precheck &&
    mutation_call &&
    mutation_postcheck &&
    mutation_precheck < mutation_call &&
    mutation_call < mutation_postcheck &&
    helper_source.scan("validateMutationProgress(epoch)").length >= 10,
  "mutation registers briefly, holds no physical-input lock across AX/CG calls, and validates before, between and after calls"
)

record.call(
  "trusted-parent-boundary",
  helper_source.include?("verifyTrustedParentProcess") &&
    helper_source.include?('hostBundle.bundleIdentifier == "com.willdeep.app"') &&
    helper_source.include?("expectedExecutableURL.path == parentExecutableURL.path"),
  "the privileged helper accepts protocol input only from its containing WillDeep executable"
)

record.call(
  "development-control-targets",
  helper_source.include?("ensureAllowedControlPID") &&
    helper_source.include?("ensureAllowedControlApplication") &&
    helper_source.include?('"com.willdeep.app"') &&
    scanner_source.include?("terminalSurfaceRestrictionsEnabled = false") &&
    helper_source.include?('"com.apple.terminal"') &&
    helper_source.include?('"com.googlecode.iterm2"') &&
    helper_source.include?('"dev.warp.warp"') &&
    helper_source.include?('"org.alacritty"') &&
    helper_source.include?('"net.kovidgoyal.kitty"') &&
    helper_source.include?('"com.github.wez.wezterm"'),
  "WillDeep and its parent remain rejected while the development switch allows terminal applications"
)

record.call(
  "display-capture-session-embargo",
  helper_source.include?("displayCaptureBlocked") &&
    helper_source.include?("hasControlSession = controlSession != nil"),
  "full-display capture cannot bypass an active or paused control session"
)

record.call(
  "secure-input-redaction",
  helper_source.include?('result["value_redacted"] = true') &&
    helper_source.include?("secureInputRejected") &&
    helper_source.include?("rejectSecureFocusedElement") &&
    scanner_source.include?('"seed phrase"') &&
    scanner_source.include?('"private key"') &&
    scanner_source.include?('"验证码"') &&
    build_tree_source.include?("redactsContent: isSensitiveContent") &&
    build_tree_source.include?("ancestorRedacted: isSensitiveContent") &&
    helper_source.scan("guard !isSecureInputElement(element)").length >= 3,
  "secure and protected AX fields recursively omit values and reject reads or writes independently of the temporarily unmasked screenshot path"
)

record.call(
  "unmasked-window-capture",
  state_source.include?("sensitiveFrames: []") &&
    preview_source.include?("sensitiveFrames: []") &&
    !state_source.include?("SensitiveAccessibilityScanner.scan") &&
    !preview_source.include?("SensitiveAccessibilityScanner.scan") &&
    !helper_source.include?('"sensitive_accessibility_scan_incomplete"') &&
    !preview_source.include?('result["screenshot"] = NSNull()') &&
    helper_source.include?("redactedWindowCapture"),
  "window screenshots bypass AX privacy scanning and redaction while preserving the existing capture coordinate space"
)

record.call(
  "ordinary-editable-visible",
  !helper_source.include?("isEditableTextElement") &&
    build_tree_source.include?(
      'result[normalizedAttributeName(attribute)] = printable(value)'
    ) &&
    !build_tree_source.include?(
      "isEditableContent"
    ),
  "ordinary non-sensitive editable AXValue and pixels remain visible outside takeover"
)

record.call(
  "ax-impact-declaration",
  helper_source.include?("validateHighImpactActionDeclaration") &&
    helper_source.include?("actionDeclarationMismatch") &&
    helper_source.include?("actual AX category=") &&
    helper_source.include?('"permission_change"') &&
    helper_source.include?('"account_change"'),
  "actual AX Send/Delete/Pay/Authorize/Account metadata must match declared consequence and target label"
)

record.call(
  "clipboard-and-multiclick-guards",
  helper_source.include?("clipboardAccessRejected") &&
    helper_source.include?("isClipboardShortcut") &&
    helper_source.include?("copyActionNames(element)") &&
    helper_source.include?(".mouseEventClickState") &&
    helper_source.include?("for clickState in 1...clicks"),
  "Helper rejects keyboard/AX clipboard paths and tags every multi-click event with the correct click state"
)

record.call(
  "semantic-ref-without-screen-recording",
  helper_source.include?("if requiresCoordinateImage,") &&
    helper_source.include?('"include_screenshot":') &&
    helper_source.include?("snapshot.coordinateImageSize != nil") &&
    scanner_source.include?("terminalSurfaceRestrictionsEnabled = false"),
  "semantic AX refs remain actionable without Screen Recording and terminal surfaces stay open during development"
)

record.call(
  "ax-first-observation",
  helper_source.include?('let includeScreenshot = bool(arguments, "include_screenshot", default: false)') &&
    helper_source.include?('"include_screenshot": false'),
  "initial and post-action state refreshes inspect the AX tree before any opt-in screenshot fallback"
)

record.call(
  "background-target-window-preview",
  helper_source.include?('case "capture_control_preview"') &&
    preview_source.include?('"preserved_active_snapshot": true') &&
    preview_source.include?('"target_frontmost": isFrontmost(app)') &&
    preview_source.include?("captureWindow(") &&
    !preview_source.include?("invalidateSnapshot()") &&
    !preview_source.include?("activateAndWaitUntilFrontmost(") &&
    !state_source.include?("activateAndWaitUntilFrontmost("),
  "target-window preview and AX state reads work without foreground activation or ref invalidation"
)

compile_command = [
  "xcrun",
  "swiftc",
  "-module-cache-path",
  MODULE_CACHE,
  "-target",
  "arm64-apple-macos13.7",
  "-D",
  "WILLDEEP_COMPUTER_USE_CONTRACT_TEST",
  "-framework",
  "AppKit",
  "-framework",
  "ApplicationServices",
  "-framework",
  "CoreGraphics",
  "-framework",
  "ImageIO",
  HELPER.to_s,
  SCANNER.to_s,
  "-o",
  HELPER_BINARY
]
compile_stdout, compile_stderr, compile_status = Open3.capture3(*compile_command)
compile_detail = compile_status.success? ? "Helper compiled" : compile_stderr.lines.last(5).join.strip
record.call("helper-compiles", compile_status.success?, compile_detail)

def exchange(stdin, stdout, request, events)
  stdin.puts(JSON.generate(request))
  stdin.flush
  loop do
    raw_line = stdout.gets
    raise "Helper stdout closed before #{request.fetch("id")}" unless raw_line

    response = JSON.parse(raw_line)
    if response["event"]
      events << response
      next
    end
    return response if response["id"] == request.fetch("id")
  end
end

if compile_status.success?
  runtime_checks = {}
  events = []
  Open3.popen3(HELPER_BINARY) do |stdin, stdout, stderr, wait_thread|
    window_binding = exchange(
      stdin,
      stdout,
      {
        "id" => "contract-window-binding",
        "action" => "contract_window_binding",
        "arguments" => {}
      },
      events
    )
    runtime_checks["window-binding"] =
      window_binding["ok"] &&
      window_binding.dig("result", "exact_match") == true &&
      window_binding.dig("result", "titlebar_adjustment_match") == true &&
      window_binding.dig("result", "overlay_rejected") == true &&
      window_binding.dig("result", "shifted_window_rejected") == true

    permissions = exchange(
      stdin,
      stdout,
      { "id" => "permissions", "action" => "permissions", "arguments" => {} },
      events
    )
    runtime_checks["permissions"] =
      permissions["ok"] && permissions.dig("result", "protocol_version") == "willdeep-computer-use.v6"

    allowed_terminal = exchange(
      stdin,
      stdout,
      {
        "id" => "allowed-terminal",
        "action" => "start_control_session",
        "control_lease_id" => "lease-terminal",
        "arguments" => { "app" => "com.apple.Terminal" }
      },
      events
    )
    runtime_checks["allowed-terminal"] =
      allowed_terminal["ok"] &&
      allowed_terminal.dig("result", "control_lease_id") == "lease-terminal"

    ended_terminal = exchange(
      stdin,
      stdout,
      {
        "id" => "end-terminal",
        "action" => "end_control_session",
        "control_lease_id" => "lease-terminal",
        "arguments" => {}
      },
      events
    )
    runtime_checks["end-terminal"] =
      ended_terminal["ok"] &&
      ended_terminal.dig("result", "ended") == true

    forbidden_parent = exchange(
      stdin,
      stdout,
      {
        "id" => "forbidden-parent",
        "action" => "start_control_session",
        "control_lease_id" => "lease-parent",
        "arguments" => { "pid" => Process.pid }
      },
      events
    )
    runtime_checks["forbidden-parent"] =
      forbidden_parent["ok"] == false &&
      forbidden_parent["error"].to_s.include?("not allowed to control")

    started = exchange(
      stdin,
      stdout,
      {
        "id" => "start-a",
        "action" => "start_control_session",
        "control_lease_id" => "lease-a",
        "arguments" => { "app" => "com.apple.TextEdit" }
      },
      events
    )
    runtime_checks["start"] =
      started["ok"] && started.dig("result", "control_lease_id") == "lease-a"

    display_capture = exchange(
      stdin,
      stdout,
      {
        "id" => "capture-display",
        "action" => "capture_display",
        "arguments" => {}
      },
      events
    )
    runtime_checks["display-capture-embargo"] =
      display_capture["ok"] == false &&
      display_capture["error"].to_s.include?("disabled while")

    conflict = exchange(
      stdin,
      stdout,
      {
        "id" => "start-b",
        "action" => "start_control_session",
        "control_lease_id" => "lease-b",
        "arguments" => { "app" => "com.apple.TextEdit" }
      },
      events
    )
    runtime_checks["conflict"] =
      conflict["ok"] == false && conflict["error"].to_s.include?("another active lease")

    paused = exchange(
      stdin,
      stdout,
      {
        "id" => "pause",
        "action" => "pause_control_session",
        "control_lease_id" => "lease-a",
        "arguments" => {}
      },
      events
    )
    runtime_checks["pause"] = paused["ok"] && paused.dig("result", "paused") == true

    resumed = exchange(
      stdin,
      stdout,
      {
        "id" => "resume",
        "action" => "resume_control_session",
        "control_lease_id" => "lease-a",
        "arguments" => {}
      },
      events
    )
    runtime_checks["resume"] = resumed["ok"] && resumed.dig("result", "paused") == false

    ended = exchange(
      stdin,
      stdout,
      {
        "id" => "end",
        "action" => "end_control_session",
        "control_lease_id" => "lease-a",
        "arguments" => {}
      },
      events
    )
    runtime_checks["end"] = ended["ok"] && ended.dig("result", "ended") == true

    shutdown = exchange(
      stdin,
      stdout,
      { "id" => "shutdown", "action" => "shutdown", "arguments" => {} },
      events
    )
    runtime_checks["shutdown-response"] =
      shutdown["ok"] && shutdown.dig("result", "shutdown") == true
    stdin.close
    begin
      Timeout.timeout(3) { wait_thread.value }
      runtime_checks["shutdown-exit"] = true
    rescue Timeout::Error
      runtime_checks["shutdown-exit"] = false
      Process.kill("TERM", wait_thread.pid)
    end
    stderr.read
  end
  failed_runtime_checks = runtime_checks.reject { |_, ok| ok }.keys
  runtime_detail = if failed_runtime_checks.empty?
    "window-binding/permissions/lease/pause/resume/end/shutdown passed"
  else
    "failed=#{failed_runtime_checks.join(",")}"
  end
  record.call(
    "tcc-free-runtime",
    failed_runtime_checks.empty?,
    runtime_detail
  )
end

status = checks.all? { |check| check[:ok] } ? "pass" : "fail"
payload = { status: status, checks: checks }
json_path.write(JSON.pretty_generate(payload) + "\n")

markdown = [
  "# Computer Use v6 Contract Report",
  "",
  "**Status:** #{status.upcase}",
  "",
  "| Check | Result | Detail |",
  "| --- | --- | --- |"
]
checks.each do |check|
  result = check[:ok] ? "PASS" : "FAIL"
  detail = check[:detail].to_s.gsub("|", "\\|").gsub("\n", " ")
  markdown << "| #{check[:name]} | #{result} | #{detail} |"
end
markdown_path.write(markdown.join("\n") + "\n")

puts "computer_use_v6_contract: #{status} checks=#{checks.length}"
puts "reports: #{markdown_path} #{json_path}"
exit(status == "pass" ? 0 : 1)
