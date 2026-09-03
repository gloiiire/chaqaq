#!/usr/bin/env ruby
# frozen_string_literal: true

# Patches app/Pinkha.xcodeproj to register the Icon Composer bundle
# (`app/Pinkha.icon`) as the app icon. xcodegen doesn't know how to write
# the special `wrapper.icon` file type that actool needs, so we re-do that
# pass with the `xcodeproj` gem after every regen.
#
# Idempotent — running it twice does nothing the second time. Wired as
# `options.postGenCommand` in app/project.yml, so xcodegen runs it itself
# after every regen; the run-on-*.sh scripts also call it explicitly.
#
# Usage : ./utilities/scripts/patch-app-icon.rb

begin
  require "xcodeproj"
rescue LoadError
  # The CI runner has no `xcodeproj` gem, and it does not need one: the app
  # icon plays no part in the test run. Failing here would be worse than
  # skipping, because xcodegen aborts `generate` when its postGenCommand
  # exits non-zero — a missing gem would take the whole Swift job down.
  #
  # Genuine patch failures below still exit 1. Only the gem's absence is
  # tolerated, and it says so out loud rather than passing silently.
  warn "⚠ xcodeproj gem unavailable — app-icon patch skipped."
  warn "  Fine for tests; a locally built app would ship the blank icon."
  warn "  Install with: gem install xcodeproj"
  exit 0
end

# Walk up to the repo root (the directory containing `app/`) — works whether
# this script lives at scripts/ or utilities/scripts/ in the tree.
require "shellwords"
ROOT          = `git -C #{Shellwords.escape(__dir__)} rev-parse --show-toplevel`.strip
PROJECT_PATH  = File.join(ROOT, "app", "Pinkha.xcodeproj")
ICON_NAME     = "Pinkha.icon"
ICON_BASENAME = File.basename(ICON_NAME, ".icon") # → "Pinkha"
TARGET_NAME   = "Pinkha"

unless File.exist?(PROJECT_PATH)
  warn "✗ #{PROJECT_PATH} not found — run xcodegen first."
  exit 1
end

icon_path = File.join(ROOT, "app", ICON_NAME)
unless File.exist?(icon_path)
  warn "✗ #{icon_path} not found — drop your Icon Composer bundle there first."
  exit 1
end

project = Xcodeproj::Project.open(PROJECT_PATH)
target  = project.targets.find { |t| t.name == TARGET_NAME }

unless target
  warn "✗ target '#{TARGET_NAME}' not found in #{PROJECT_PATH}"
  exit 1
end

# 1. File reference — created with the `wrapper.icon` file type so actool
#    treats the bundle as an app icon, not a generic folder. xcodegen
#    couldn't emit this; that's the whole reason this script exists.
existing_ref = project.files.find { |f| f.path == ICON_NAME }
file_ref =
  if existing_ref
    if existing_ref.last_known_file_type != "wrapper.icon"
      existing_ref.last_known_file_type = "wrapper.icon"
      puts "→ updated file type on existing #{ICON_NAME} reference"
    end
    existing_ref
  else
    ref = project.main_group.find_subpath("app", true).new_file(ICON_NAME)
    ref.last_known_file_type = "wrapper.icon"
    puts "→ added file reference for #{ICON_NAME}"
    ref
  end

# 2. Resources build phase — make sure the icon is copied into the bundle.
resources_phase = target.resources_build_phase
unless resources_phase.files_references.include?(file_ref)
  resources_phase.add_file_reference(file_ref)
  puts "→ added #{ICON_NAME} to Resources build phase"
end

# 3. Build setting — tells actool which icon set to use for the app icon.
target.build_configurations.each do |config|
  current = config.build_settings["ASSETCATALOG_COMPILER_APPICON_NAME"]
  next if current == ICON_BASENAME

  config.build_settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = ICON_BASENAME
  puts "→ set ASSETCATALOG_COMPILER_APPICON_NAME=#{ICON_BASENAME} on '#{config.name}'"
end

project.save
puts "✓ Pinkha.xcodeproj patched for Icon Composer bundle '#{ICON_NAME}'."
