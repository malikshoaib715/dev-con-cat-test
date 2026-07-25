# frozen_string_literal: true

module ApplicationHelper
  include Pagy::Frontend

  VERDICT_CLASSES = {
    "accept" => "bg-emerald-100 text-emerald-800 ring-emerald-600/20",
    "review" => "bg-amber-100 text-amber-800 ring-amber-600/20",
    "reject" => "bg-rose-100 text-rose-800 ring-rose-600/20"
  }.freeze

  NEUTRAL_BADGE_CLASSES = "bg-slate-100 text-slate-600 ring-slate-500/20"

  STATUS_CLASSES = {
    "completed" => "bg-slate-100 text-slate-700 ring-slate-500/20",
    "on_hold_insufficient_credits" => "bg-amber-100 text-amber-800 ring-amber-600/20",
    "past_due" => "bg-rose-100 text-rose-800 ring-rose-600/20",
    "suspended" => "bg-rose-100 text-rose-800 ring-rose-600/20"
  }.freeze

  # The three states the rubric asks a certificate to distinguish, said the same
  # way everywhere they are shown: a layer nobody bought, a layer with nothing to
  # judge, and a layer that could not answer are each named rather than left
  # blank — and none of them is ever painted as a check that passed.
  LAYER_STATE_LABELS = {
    "not_enabled" => "Not in plan",
    "not_applicable" => "N/A",
    "errored" => "Unavailable",
    "pending" => "Waiting",
    "processing" => "Running"
  }.freeze

  LAYER_STATE_CLASSES = {
    "not_enabled" => NEUTRAL_BADGE_CLASSES,
    "not_applicable" => NEUTRAL_BADGE_CLASSES,
    "errored" => "bg-amber-100 text-amber-800 ring-amber-600/20"
  }.freeze

  PANEL_VERDICT_CLASSES = {
    "pass" => "bg-emerald-100 text-emerald-800 ring-emerald-600/20",
    "warn" => "bg-amber-100 text-amber-800 ring-amber-600/20",
    "fail" => "bg-rose-100 text-rose-800 ring-rose-600/20",
    "skip" => NEUTRAL_BADGE_CLASSES
  }.freeze

  BADGE_CLASSES = "inline-flex items-center gap-1 rounded-full px-2 py-0.5 " \
                  "text-xs font-semibold ring-1 ring-inset"

  def verdict_badge(verdict)
    badge(verdict.presence&.upcase || "PENDING", VERDICT_CLASSES.fetch(verdict.to_s, NEUTRAL_BADGE_CLASSES))
  end

  def status_badge(status)
    badge(status.to_s.humanize, STATUS_CLASSES.fetch(status.to_s, NEUTRAL_BADGE_CLASSES))
  end

  def layer_state_badge(layer_result)
    return in_flight_badge(layer_result.status) if layer_result.status.in?(%w[pending processing])
    return completed_layer_badge(layer_result) if layer_result.status == "completed"

    badge(LAYER_STATE_LABELS.fetch(layer_result.status, layer_result.status.humanize),
          LAYER_STATE_CLASSES.fetch(layer_result.status, NEUTRAL_BADGE_CLASSES))
  end

  # An account spending nothing never runs out, and saying so is more honest than
  # a very large number of days.
  def runway_text(days_to_zero)
    return "∞" if days_to_zero.nil? || days_to_zero.infinite?

    "#{days_to_zero.round(1)} days"
  end

  # Highlights the section a page belongs to rather than the exact URL, so a lead
  # detail page still shows "Leads" as where the visitor is.
  def nav_link_to(name, path, badge_count: nil)
    active = request.path == path || request.path.start_with?("#{path}/")
    classes = active ? "font-semibold text-slate-900" : "text-slate-600 hover:text-slate-900"

    link_to(path, class: classes) do
      safe_join([ name, nav_count(badge_count) ].compact, " ")
    end
  end

  private

  def nav_count(count)
    return nil if count.nil? || count.zero?

    tag.span count, class: "rounded-full bg-amber-100 px-1.5 py-0.5 text-xs font-semibold text-amber-800"
  end

  def badge(text, classes)
    tag.span text, class: "#{BADGE_CLASSES} #{classes}"
  end

  def in_flight_badge(status)
    badge(safe_join([ tag.span(class: "size-1.5 animate-pulse rounded-full bg-slate-500"),
                      LAYER_STATE_LABELS.fetch(status) ]),
          NEUTRAL_BADGE_CLASSES)
  end

  # A completed layer is coloured by what it decided, not by the fact that it ran.
  def completed_layer_badge(layer_result)
    panel_verdict = layer_result.panel_verdict.to_s
    badge(panel_verdict.presence&.upcase || "DONE",
          PANEL_VERDICT_CLASSES.fetch(panel_verdict, NEUTRAL_BADGE_CLASSES))
  end
end
