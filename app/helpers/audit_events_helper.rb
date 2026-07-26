# frozen_string_literal: true

# Shared by the lead timeline and both audit explorers: one way of rendering an
# event, so the same write reads identically wherever it is shown.
module AuditEventsHelper
  SUMMARY_KEYS = 4

  def audit_event_chip(event_type)
    tag.span event_type,
             class: "rounded bg-slate-100 px-1.5 py-0.5 font-mono text-xs text-slate-700"
  end

  # Who did it, in the terms the spine records: a signed-in person, a pixel acting
  # for a visitor, or the pipeline itself.
  def audit_actor(event)
    return "system" if event.actor_id.blank?

    "#{event.actor_type.humanize.downcase} ##{event.actor_id}"
  end

  # The first few payload keys, so a timeline is readable without opening every
  # row. The full payload is a click away in the <details> beside it.
  def audit_payload_summary(payload)
    return "—" if payload.blank?

    payload.first(SUMMARY_KEYS).map { |key, value| "#{key}: #{summarized_value(value)}" }.join(" · ")
  end

  def audit_payload_json(payload)
    JSON.pretty_generate(payload)
  end

  # The explorer's event_type select, grouped by the object each event is about,
  # built from the frozen taxonomy rather than a list kept beside it.
  def audit_event_type_groups
    Audit::Events::ALL.group_by { |event_type| event_type.split(".").first.humanize }.to_a
  end

  def audit_filter_fields
    [
      { name: :event_type, type: :grouped_select, label: "Event", groups: audit_event_type_groups },
      { name: :actor_type, type: :select, label: "Actor",
        options: AuditEvent::ACTOR_TYPES.map { |actor| [ actor.humanize, actor ] } },
      { name: :session_id, type: :text, label: "Session" },
      { name: :from, type: :date, label: "From" },
      { name: :to, type: :date, label: "To" }
    ]
  end

  # A subject is a link only where the reader has a page for it; everything else
  # is named without pretending to be clickable.
  def audit_subject_link(event)
    return "—" if event.subject.nil?

    case event.subject
    when Lead  then link_to event.subject.public_id, app_lead_path(event.subject), class: "hover:underline"
    when Pixel then link_to event.subject.public_id, app_pixel_path(event.subject), class: "hover:underline"
    else "#{event.subject_type} ##{event.subject_id}"
    end
  end

  private

  def summarized_value(value)
    case value
    when Hash then "{#{value.keys.join(', ')}}"
    when Array then value.join(", ").truncate(60)
    else value.to_s.truncate(60)
    end
  end
end
