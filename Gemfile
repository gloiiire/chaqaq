source "https://rubygems.org"

# Pin fastlane to the 2.x line so a major version bump never lands
# mid-pipeline. Bundler will resolve the exact patch in Gemfile.lock,
# checked in alongside this file so the CI and a local Mac install
# behave identically.
gem "fastlane", "~> 2.225"

# Cocoapods is unused by Pinkha (every Swift dep ships through SwiftPM)
# but some fastlane plugins assume it's there. Listing it explicitly is
# cheaper than discovering a missing-dep error in CI.
# Uncomment if a plugin starts complaining.
# gem "cocoapods", "~> 1.16"

plugins_path = File.join(File.dirname(__FILE__), "fastlane", "Pluginfile")
eval_gemfile(plugins_path) if File.exist?(plugins_path)
