# frozen_string_literal: true

module DemoHelper
  # The panel's own badge vocabulary, reused for the cheat sheet so a persona's
  # listed verdict is coloured the same way the live banner will colour it.
  VERDICT_BADGE_CLASSES = { "accept" => "b-pass", "review" => "b-warn", "reject" => "b-fail" }.freeze

  def verdict_badge_class(verdict)
    VERDICT_BADGE_CLASSES.fetch(verdict.to_s, "b-info")
  end
end
