#!/usr/bin/env ruby
# scripts/add_test_target.rb
#
# Idempotent script that adds a `COOL-TUNNELTests` unit-test target to
# COOL-TUNNEL.xcodeproj, wires it into the existing `COOL-TUNNEL`
# scheme's TestAction, and adds every `*.swift` file under
# `COOL-TUNNELTests/` to the target's Sources build phase. Re-running
# is a no-op once the target exists.
#
# Why a script and not a hand-edited pbxproj diff:
#
#   project.pbxproj is a complex property-list-shaped graph of UUIDs.
#   Hand-edits are error-prone and reviewers can't sanity-check the
#   UUIDs. xcodeproj's API gives us a high-level, idempotent path —
#   the script can be re-run to add new test files later, and the
#   resulting pbxproj diff is review-friendly because it follows the
#   same UUID conventions Xcode itself uses.
#
# Dependency:
#
#   gem install --user-install xcodeproj
#
# Usage:
#
#   scripts/add_test_target.rb

require "xcodeproj"

REPO_ROOT = File.expand_path(File.join(__dir__, ".."))
PROJECT_PATH = File.join(REPO_ROOT, "COOL-TUNNEL.xcodeproj")
TESTS_DIR = "COOL-TUNNELTests"
TEST_TARGET_NAME = "COOL-TUNNELTests"
APP_TARGET_NAME = "COOL-TUNNEL"
SCHEME_NAME = "COOL-TUNNEL"

project = Xcodeproj::Project.open(PROJECT_PATH)

app_target = project.targets.find { |t| t.name == APP_TARGET_NAME }
abort("could not find app target '#{APP_TARGET_NAME}' in project") if app_target.nil?

test_target = project.targets.find { |t| t.name == TEST_TARGET_NAME }
if test_target.nil?
  puts "info: creating new unit-test target '#{TEST_TARGET_NAME}'"
  test_target = project.new_target(
    :unit_test_bundle,
    TEST_TARGET_NAME,
    :osx,
    "14.0",        # deployment target — matches the app
    project.products_group,
    :swift
  )
  test_target.add_dependency(app_target)

  # Match the app target's bundle-ID convention. Plenty of
  # Xcode-generated test targets append `.Tests` and Apple's test
  # tooling is happy with that.
  app_settings = app_target.build_configurations.first.build_settings
  app_bundle_id = app_settings["PRODUCT_BUNDLE_IDENTIFIER"] || "space.coolwhite.naive"

  test_target.build_configurations.each do |config|
    config.build_settings.merge!({
      "PRODUCT_BUNDLE_IDENTIFIER" => "#{app_bundle_id}.Tests",
      "BUNDLE_LOADER" => "$(TEST_HOST)",
      "TEST_HOST" =>
        "$(BUILT_PRODUCTS_DIR)/Cool Tunnel.app/Contents/MacOS/Cool Tunnel",
      "MACOSX_DEPLOYMENT_TARGET" => "14.0",
      "SWIFT_VERSION" => "6.0",
      "CODE_SIGN_STYLE" => "Automatic",
      "CODE_SIGNING_ALLOWED" => "NO",
      "GENERATE_INFOPLIST_FILE" => "YES",
      "PRODUCT_NAME" => "$(TARGET_NAME)",
      "LD_RUNPATH_SEARCH_PATHS" => [
        "$(inherited)",
        "@executable_path/../Frameworks",
        "@loader_path/../Frameworks",
      ],
    })
  end
else
  puts "info: unit-test target '#{TEST_TARGET_NAME}' already exists; refreshing sources"
end

# Group for the test files. Re-uses an existing group named
# COOL-TUNNELTests if one is already wired up.
tests_group = project.main_group.find_subpath(TESTS_DIR, true)
tests_group.set_source_tree("<group>")
tests_group.set_path(TESTS_DIR)

# Find existing references for `*.swift` under the group to support
# idempotent re-runs.
existing_paths = tests_group.files.map(&:path)

# Add every `*.swift` under `COOL-TUNNELTests/` that isn't already in.
swift_files = Dir.glob(File.join(REPO_ROOT, TESTS_DIR, "*.swift")).sort
swift_files.each do |abs|
  rel = File.basename(abs)
  next if existing_paths.include?(rel)
  file_ref = tests_group.new_reference(rel)
  test_target.source_build_phase.add_file_reference(file_ref)
  puts "info: added #{TESTS_DIR}/#{rel} to #{TEST_TARGET_NAME} Sources"
end

# Wire the test target into the existing shared scheme so
# `xcodebuild test -scheme COOL-TUNNEL` actually runs it.
schemes_dir = File.join(PROJECT_PATH, "xcshareddata", "xcschemes")
scheme_path = File.join(schemes_dir, "#{SCHEME_NAME}.xcscheme")

if File.exist?(scheme_path)
  scheme = Xcodeproj::XCScheme.new(scheme_path)
  already_in_test_action = scheme.test_action.testables.any? do |testable|
    testable.buildable_references.any? do |ref|
      ref.target_name == TEST_TARGET_NAME
    end
  end
  if already_in_test_action
    puts "info: scheme '#{SCHEME_NAME}' already references #{TEST_TARGET_NAME}"
  else
    testable = Xcodeproj::XCScheme::TestAction::TestableReference.new(test_target)
    scheme.test_action.add_testable(testable)
    scheme.save_as(PROJECT_PATH, SCHEME_NAME, true)
    puts "info: added #{TEST_TARGET_NAME} to scheme '#{SCHEME_NAME}' TestAction"
  end
else
  # Shared scheme didn't exist; create one.
  scheme = Xcodeproj::XCScheme.new
  scheme.configure_with_targets(app_target, test_target)
  scheme.save_as(PROJECT_PATH, SCHEME_NAME, true)
  puts "info: created shared scheme '#{SCHEME_NAME}' with test target"
end

project.save
puts "ok: project.pbxproj updated"
