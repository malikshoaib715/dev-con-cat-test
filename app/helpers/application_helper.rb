# frozen_string_literal: true

module ApplicationHelper
  include Pagy::Frontend

  VERDICT_CLASSES = {
    "accept" => "bg-emerald-100 text-emerald-800 ring-emerald-600/20",
    "review" => "bg-amber-100 text-amber-800 ring-amber-600/20",
    "reject" => "bg-rose-100 text-rose-800 ring-rose-600/20"
  }.freeze

  NEUTRAL_BADGE_CLASSES = "bg-slate-100 text-slate-600 ring-slate-500/20"

  def verdict_badge(verdict)
    classes = VERDICT_CLASSES.fetch(verdict.to_s, NEUTRAL_BADGE_CLASSES)
    tag.span verdict.presence&.upcase || "PENDING",
             class: "inline-flex items-center rounded-full px-2 py-0.5 " \
                    "text-xs font-semibold ring-1 ring-inset #{classes}"
  end
end
