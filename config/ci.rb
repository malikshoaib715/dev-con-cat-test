# Run using bin/ci

CI.run do
  step "Setup", "bin/rails db:test:prepare"

  step "Style: Ruby", "bin/rubocop --parallel"
  step "Security: Brakeman", "bin/brakeman --quiet --no-pager --exit-on-warn"
  step "Tests", "bin/rspec"
end
