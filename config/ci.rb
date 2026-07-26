# Run using bin/ci

CI.run do
  step "Setup", "bin/rails db:test:prepare"
  # The built stylesheet is a gitignored artifact, so a pristine clone has none —
  # and every spec that renders the layout would fail on the missing asset.
  step "Assets: Tailwind", "bin/rails tailwindcss:build"

  step "Style: Ruby", "bin/rubocop --parallel"
  step "Security: Brakeman", "bin/brakeman --quiet --no-pager --exit-on-warn"
  step "Tests", "bin/rspec"
end
