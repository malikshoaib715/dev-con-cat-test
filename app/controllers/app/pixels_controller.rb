# frozen_string_literal: true

module App
  # Where a buyer creates the tag they paste onto their funnel, and decides which
  # detection layers it runs.
  class PixelsController < BaseController
    before_action :set_pixel, only: %i[show edit update destroy]
    before_action :set_layer_definitions

    def index
      # The account and its policies are preloaded so the whole table's effective
      # layers and costs resolve without a query per row.
      @pixels = policy_scope(current_account.pixels).ordered.includes(account: :layer_policies)
    end

    def show
      @snippet = Pixels::SnippetGenerator.call(pixel: @pixel, endpoint_base: request.base_url)
    end

    def new
      @pixel = current_account.pixels.new(enabled_layers: purchased_layer_keys)
      authorize @pixel
    end

    def edit; end

    def create
      @pixel = current_account.pixels.new(pixel_attributes)
      authorize @pixel

      return render :new, status: :unprocessable_content unless @pixel.save

      record_change(Audit::Events::PIXEL_CREATED)
      redirect_to app_pixel_path(@pixel), notice: "Pixel created."
    end

    def update
      return render :edit, status: :unprocessable_content unless @pixel.update(pixel_attributes)

      record_change(Audit::Events::PIXEL_UPDATED)
      redirect_to app_pixel_path(@pixel), notice: "Pixel updated."
    end

    # `dependent: :restrict_with_error` refuses a pixel that has captured leads,
    # and that refusal is shown rather than rescued away: the leads are evidence,
    # and deleting the pixel they came through would orphan their provenance.
    def destroy
      return redirect_to app_pixels_path, notice: "Pixel deleted." if @pixel.destroy

      redirect_to app_pixel_path(@pixel), alert: @pixel.errors.full_messages.to_sentence
    end

    private

    # Loaded once for every action: the registry is what the form offers, what the
    # chips name, and what the cost readout adds up. Views do no querying of their
    # own (§18.1).
    def set_layer_definitions
      @layer_definitions = LayerDefinition.ordered.to_a
      @layer_costs = @layer_definitions.to_h { |definition| [ definition.key, definition.cost_credits ] }
    end

    def set_pixel
      @pixel = current_account.pixels.find_by!(public_id: params[:id])
      authorize @pixel
    end

    def pixel_attributes
      permitted = params.expect(pixel: [ :name, :active, :allowed_domains, { enabled_layers: [] } ])

      permitted.to_h.symbolize_keys.merge(
        allowed_domains: domains_from(permitted[:allowed_domains]),
        enabled_layers: purchased_only(permitted[:enabled_layers])
      )
    end

    # The form only offers layers the account bought, but the form is the
    # visitor's to edit — an account cannot enable a module it does not pay for by
    # posting one, so the intersection is taken again here.
    def purchased_only(submitted)
      Array(submitted).map(&:to_s) & purchased_layer_keys
    end

    def purchased_layer_keys
      @purchased_layer_keys ||= Layers::Registry.keys & current_account.layer_policies.enabled.pluck(:layer_key)
    end
    helper_method :purchased_layer_keys

    # A textarea, one domain per line: asking a buyer to comma-separate hostnames
    # is how a trailing space ends up in an allowlist and every submission from a
    # perfectly legitimate domain starts being refused.
    def domains_from(submitted)
      submitted.to_s.split("\n").map(&:strip).reject(&:blank?)
    end

    # Every admin mutation is queryable (§6), and the payload carries what
    # actually changed rather than the whole record.
    def record_change(event_type)
      Audit::Recorder.record!(
        event_type,
        subject: @pixel,
        payload: { changes: @pixel.previous_changes.except("created_at", "updated_at") }
      )
    end
  end
end
