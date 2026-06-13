Pod::Spec.new do |spec|
  spec.name         = "AIPipe"
  spec.version      = "1.0.0"
  spec.summary      = "AIPipe iOS/macOS SDK for exception and log reporting"
  spec.description  = <<-DESC
    AIPipe SDK for iOS and macOS. Capture exceptions and logs, automatically report to AIPipe server for AI analysis.
  DESC

  spec.homepage     = "https://github.com/xurenlu/aipipe"
  spec.license      = { :type => "MIT", :file => "LICENSE" }
  spec.author       = { "AIPipe" => "support@aipipe.io" }
  
  spec.ios.deployment_target = "11.0"
  spec.osx.deployment_target = "10.13"
  
  spec.source       = { :git => "https://github.com/xurenlu/aipipe.git", :tag => "#{spec.version}" }
  spec.source_files = "AIPipe/**/*.{h,m}"
  spec.public_header_files = "AIPipe/*.h"
  
  spec.requires_arc = true
  spec.frameworks = "Foundation"
end

