# Paycheck Flow Planner (M2 PR#2b): the planning diagram — incomes -> banks
# -> allocations as a Sankey in the house Cashflow style. The diagram itself
# fetches /plan/flow/graph (PaycheckFlowPlanner.plan_graph); this controller
# renders the page shell, the dialogs, and the config writes.
class PlanFlowsController < ApplicationController
  include PreviewGateable
  before_action :require_preview_features!

  # Round 20d: custom bank-logo upload limits. SVG is excluded on purpose
  # (an uploaded SVG can carry scripts; the built-in vendored set ships its
  # own SVGs and is not user input). 1 MiB keeps the blob blobby but sane.
  BANK_LOGO_CONTENT_TYPES = %w[image/png image/jpeg image/webp image/gif].freeze
  BANK_LOGO_MAX_BYTES = 1_048_576

  def show
    @month = Date.current
    @view = flow_view
    @graph = PaycheckFlowPlanner.plan_graph(family: Current.family, month: @month)
    set_chrome_instance_vars
    # Static (non-plan-state) data the Sankey needs: account names and which
    # accounts are on the plan. The plan state itself comes from /plan/flow/graph.
    @account_names = @flow_accounts.map { |account| [ account.id, account.name ] }.to_h
    # "Known Allocations" list for the allocation dialog (owner round 2,
    # F3) — see #known_allocations (also feeds the in-place JSON chrome).
    @known_allocations = known_allocations
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.plan"), plan_path ],
      [ t(".title"), nil ]
    ]
  end

  # Planning diagram JSON (M2 PR#2b): the whole page state in one payload —
  # the saved state with draft rows merged over it (same draft pattern as
  # the preview action): the selected income's saved edges are replaced by
  # the form's edge rows, and the allocation rows merge per-id over the
  # saved set. No write.
  def graph
    @month = Date.current
    @graph = PaycheckFlowPlanner.plan_graph(family: Current.family, month: @month, draft: graph_draft.presence)
    render json: @graph
  end

  # Allocation dialog save (M2 PR#2b): upsert by (family, source bank, name)
  # — re-saving the same row from the dialog edits it in place instead of
  # duplicating. Invalid rows flash the house alert, no 500.
  def create_allocation
    row = plan_allocation_params
    allocation = Current.family.plan_allocations
                               .find_by(account: row[:account], name: row[:name]) ||
               Current.family.plan_allocations.build
    allocation.assign_attributes(row)

    result = begin
      allocation.save!
      true
    rescue ActiveRecord::RecordInvalid
      false
    end

    return render_flow_json(ok: result, allocation_changed: true, error_object: allocation) if json_request?

    if result
      redirect_to flow_plan_path(view: flow_view), notice: t(".saved")
    else
      redirect_to flow_plan_path(view: flow_view), alert: t(".save_failed")
    end
  end

  def update_allocation
    allocation = Current.family.plan_allocations.find(params[:id])
    allocation.assign_attributes(plan_allocation_params)

    result = begin
      allocation.save!
      true
    rescue ActiveRecord::RecordInvalid
      false
    end

    return render_flow_json(ok: result, allocation_changed: true, error_object: allocation) if json_request?

    if result
      redirect_to flow_plan_path(view: flow_view), notice: t(".saved")
    else
      redirect_to flow_plan_path(view: flow_view), alert: t(".save_failed")
    end
  end

  def destroy_allocation
    allocation = Current.family.plan_allocations.find(params[:id])
    allocation.destroy!
    return render_flow_json(allocation_changed: true) if json_request?

    redirect_to flow_plan_path(view: flow_view), notice: t(".saved")
  end

  # Remove a bank from the plan (owner review round 3, R3, the "Remove"
  # button in the bank config dialog). Semantics: the bank's income edges and
  # plan markers (order / role / auto-transfer) are dropped, and its
  # allocations PERSIST without a source bank — the planner reports them
  # with status "unassigned" (the diagram's "No Assignment" marker) and the
  # allocation dialog can re-assign a source bank.
  def remove_account
    account = Current.family.accounts.find(params[:account_id])

    result = begin
      ActiveRecord::Base.transaction do
        Current.family.income_account_allocations.where(account_id: account.id).destroy_all
        Current.family.plan_allocations.where(account_id: account.id).update_all(account_id: nil)
        # Round 11 issue 8: the sub-account link + fan-out targets leave the
        # plan with the bank (a removed bank is no longer anyone's child and
        # fans out to no one).
        account.update!(plan_order: nil, plan_role: nil, auto_transfer_to_account_id: nil,
                        parent_account_id: nil, auto_transfer_target_ids: [])
      end
      true
    rescue ActiveRecord::RecordInvalid
      false
    end

    # Round 4: a removed bank drops its config dialog element in the JS
    # (bank_removed) instead of shipping a dialog for a bank that left the plan.
    return render_flow_json(removed_account: account, ok: result, error_object: account) if json_request?

    if result
      redirect_to flow_plan_path(view: flow_view), notice: t(".removed")
    else
      redirect_to flow_plan_path(view: flow_view), alert: t(".save_failed")
    end
  end

  # "Add Bank Account" modal (Turbo frame): lists the family accounts not
  # yet on the map (no plan_order, no allocation) for the attach form, plus
  # the manual bank-creation form.
  def add_accounts_modal
    in_flow = Current.family.income_account_allocations.pluck(:account_id).to_set
    @unassigned_accounts = flow_accounts.reject do |account|
      account.plan_order.present? || in_flow.include?(account.id)
    end
    # Round 16 (owner note 4): the same last-4 the plan-flow payload carries,
    # so the "Add Bank Account" list shows ****8979-style suffixes too. nil
    # for every account without a mask (never fabricated).
    @account_last4s = PaycheckFlowPlanner.account_last4s_for(Current.family)
    # Full template (not a partial): a controller `render "prefix/name"`
    # resolves with partial: false and no underscore fallback, so the modal
    # content must be a real template — same shape as the house modal
    # (recurring_transactions/new.html.erb), frame requests drop the layout
    # so the shared #modal frame stays unique in the response.
    render "plan_flows/account_modal", layout: turbo_frame_request? ? false : nil
  end

  # "Add Bank Account" modal, part 1: attach existing family accounts to the
  # map by giving them a plan_order (max + 1..).
  def add_accounts
    base = Current.family.accounts.maximum(:plan_order).to_i
    added = []
    Array(params[:account_ids]).compact.map(&:to_s).each_with_index do |account_id, index|
      account = Current.family.accounts.find_by(id: account_id)
      next unless account

      account.update!(plan_order: base + index + 1)
      added << account
    end
    # Round 4 (ghost banks): the planner now renders plan-ordered banks with
    # no flow, and the response ships each new bank's config dialog so the
    # node is operable in place.
    return render_flow_json(accounts: added) if json_request?

    redirect_to flow_plan_path(view: flow_view), notice: t(".accounts_added")
  end

  # (create_account removed in owner round 2, F2: the flow page no longer
  # creates its own accounts — the Add Account modal only lists Sure's
  # existing accounts; "Add Manual Account" goes to the house account page.)

  # Center card edits: ownership label (Home/Shared | member) + plan_order.
  # The card's single dropdown submits "shared" or "user:<user_id>" so one
  # control writes both plan_ownership and plan_owner_user_id. M2 PR#2b adds
  # the bank-config fields: plan_role (savings bucket / credit card payoff /
  # loan payoff label), auto_transfer_to_account_id, and the linked-income
  # edges (upserted by income+account, per-edge mode/value — same semantics
  # as the edge editor save: checked rows win, unchecked are removed).
  def update_account
    account = Current.family.accounts.find(params[:account_id])
    ownership = params.dig(:account, :plan_ownership).to_s

    result = begin
      ActiveRecord::Base.transaction do
        if ownership.start_with?("user:") && family_user_ids.include?(ownership.delete_prefix("user:"))
          account.update!(plan_ownership: "user", plan_owner_user_id: ownership.delete_prefix("user:"))
        else
          account.update!(plan_ownership: "shared", plan_owner_user_id: nil)
        end

        apply_bank_config(account)
      end
      true
    rescue ActiveRecord::RecordInvalid
      false
    end

    return render_flow_json(accounts: [ account ], ok: result, error_object: account) if json_request?

    if result
      redirect_back_to_flow
    else
      redirect_to flow_plan_path(view: flow_view, income: params[:income].presence), alert: t(".save_failed")
    end
  end

  # Round 20d: custom bank-logo upload from the avatar popup in the bank
  # config dialog. Image-only content types (SVG deliberately excluded —
  # uploaded SVG is an XSS vector and the built-in set ships its own),
  # sane max size, per-account ActiveStorage attachment (account.logo).
  # JSON { logo_url } 200 / { errors } 422; the dialog shows the errors
  # inline. Non-JSON callers get the house redirect back to the flow.
  def upload_bank_logo
    account = Current.family.accounts.find(params[:account_id])
    upload = params[:image]

    errors = []
    unless upload.respond_to?(:read) && upload.respond_to?(:content_type)
      errors << t(".bank_logo_missing_file")
    else
      errors << t(".bank_logo_not_an_image") unless BANK_LOGO_CONTENT_TYPES.include?(upload.content_type.to_s)
      errors << t(".bank_logo_too_large") if upload.size.to_i <= 0 || upload.size.to_i > BANK_LOGO_MAX_BYTES
    end

    if errors.any?
      return render json: { errors: errors }, status: :unprocessable_entity if json_request?

      return redirect_to flow_plan_path(view: flow_view), alert: errors.join(" ")
    end

    filename = File.basename(upload.original_filename.to_s, ".*")
    filename = "bank-logo" if filename.blank? || filename == "." || filename == ".."
    account.logo.purge_later
    account.logo.attach(
      io: upload,
      filename: "#{filename[0, 40]}.#{File.extname(upload.original_filename.to_s)[1..].presence || "png"}",
      content_type: upload.content_type.to_s
    )
    render json: { logo_url: Rails.application.routes.url_helpers.rails_blob_path(account.logo, only_path: true) }
  end

  # Round 20d: remove the custom logo (the avatar falls back to the
  # built-in pick or the neutral circle server-side on the next save).
  def remove_bank_logo
    account = Current.family.accounts.find(params[:account_id])
    account.logo.purge_later if account.logo.attached?
    render json: { logo_url: nil }
  end

  # Income card edit: label the income to a family member (or clear the
  # label back to the account-owner fallback). M2 PR#2b adds
  # plan_max_account_links — the income's hard bank-link limit; blank clears.
  def update_income
    income = income_series.find { |series| series.id == params[:income_id] }
    return redirect_to flow_plan_path unless income

    result = begin
      ActiveRecord::Base.transaction do
        user_id = params.dig(:series, :plan_owner_user_id).presence
        if user_id.present? && family_user_ids.include?(user_id)
          income.update!(plan_owner_user_id: user_id)
        else
          income.update!(plan_owner_user_id: nil)
        end

        series_params = params.dig(:series)
        if series_params.respond_to?(:key?) && series_params.key?("plan_max_account_links")
          income.update!(plan_max_account_links: series_params["plan_max_account_links"].presence&.to_i)
        end
      end
      true
    rescue ActiveRecord::RecordInvalid
      false
    end

    return render_flow_json(income: income, ok: result, error_object: income) if json_request?

    if result
      redirect_back_to_flow
    else
      redirect_to flow_plan_path(view: flow_view), alert: t(".save_failed")
    end
  end

  private

    def flow_view
      %w[paycheck monthly].include?(params[:view].to_s) ? params[:view] : "paycheck"
    end

    # In-place diagram updates (owner review round 3, R1/R7): the page's
    # mutation forms submit as Accept: application/json fetches (data-turbo
    # disabled) instead of full-reload submissions, so the Sankey can tween
    # to the new layout in place. These requests get a JSON response:
    # 200 + the fresh plan-graph JSON + the re-rendered stale chrome
    # fragments on success, 422 + the model's field errors on a validation
    # failure. Plain HTML requests keep the redirect + flash behavior.
    def json_request?
      request.format == Mime[:json]
    end

    def render_flow_json(ok: true, allocation_changed: false, accounts: [], income: nil, removed_account: nil, error_object: nil)
      return render(json: { errors: error_messages(error_object) }, status: :unprocessable_entity) unless ok

      graph = PaycheckFlowPlanner.plan_graph(family: Current.family, month: Date.current)
      @graph = graph
      set_chrome_instance_vars
      @known_allocations = known_allocations

      # Round 4 (ghost banks): the bank config dialog for every affected bank,
      # so an in-place add/edit makes the (new) bank node operable without a
      # reload. A removed bank ships no dialog — the JS drops its element.
      bank_dialogs = removed_account ? nil : accounts.map do |account|
        {
          node_id: "bank:#{account.id}",
          html: render_to_string(partial: "plan_flows/bank_config_dialog", locals: {
            account: account,
            edges: Current.family.income_account_allocations.where(account_id: account.id).index_by(&:income_series_id),
            # Round 16: the picker's searchable logo list (same-origin
            # assets; client-side filtering, no endpoint).
            available_bank_logos: @available_bank_logos
          })
        }
      end

      render json: {
        graph: graph,
        chrome: {
          top: render_to_string(partial: "plan_flows/chrome_top"),
          overlays: render_to_string(partial: "plan_flows/chrome_overlays"),
          known: allocation_changed ? render_to_string(partial: "plan_flows/known_allocations", locals: { known_allocations: @known_allocations, known_hidden: @known_allocations_hidden }) : nil,
          # Round 21 T8: the allocation dialog's BANK SOURCE rows render
          # once at page load, so an in-place account change ships a fresh
          # fragment for #inPlaceSubmit to swap in place (the off-plan
          # row a dialog may append is out of scope here).
          allocation_bank_rows: (accounts.any? || removed_account) ? render_to_string(partial: "plan_flows/allocation_bank_rows", locals: { bank_rows: @in_plan_accounts }) : nil,
          bank_dialogs: bank_dialogs.presence,
          bank_removed: removed_account ? "bank:#{removed_account.id}" : nil,
          # Round 7: the Sankey's in-plan / account-name values are
          # page-load state; refresh them after every in-place write or a
          # removed bank is re-synthesized as a phantom floor node until the
          # next reload.
          sankey: {
            accounts: @flow_accounts.map { |account| [ account.id, account.name ] }.to_h,
            in_plan: in_plan_account_ids
          },
          income_dialog: income ? {
            node_id: "income:#{income.id}",
            html: render_to_string(partial: "plan_flows/income_config_dialog", locals: { series: income })
          } : nil
        }
      }
    end

    # The instance vars the page chrome (over-plan lines, empty states,
    # recommended list, dialogs) renders from — shared by `show` and the
    # in-place JSON responses so the server-rendered chrome never drifts.
    def set_chrome_instance_vars
      @family_users = family_users
      # Round 16: the usable bank-logo set (vendored file + label) the bank
      # config dialog's searchable picker filters over. The plan-graph
      # payload carries the same list at its root (available_bank_logos) so
      # the in-place JS path needs no extra source.
      @available_bank_logos = BankLogoSlugs.available
      @income_series = income_series
      @flow_accounts = flow_accounts
      @in_plan_account_ids = in_plan_account_ids
      @in_plan_accounts = @flow_accounts.select { |account| @in_plan_account_ids.include?(account.id) }
      @unplanned_count = @flow_accounts.count - @in_plan_accounts.count
      @plan_allocations = Current.family.plan_allocations.includes(:account).order(:name)
      @over_plan_lines = over_plan_lines
    end

    # "Known Allocations" list for the allocation dialog (owner round 2,
    # F3; round 8: only what is NOT already in the diagram): the bills /
    # auto-tracked subscriptions Sure already has, MINUS the ones a plan
    # allocation already links — those show in the diagram, so the dialog
    # offers only the rest. When every detected bill is planned,
    # @known_allocations_hidden is set so the empty list says
    # "already in the diagram" instead of implying nothing was detected.
    def known_allocations
      covered_ids = Current.family.plan_allocations.where.not(recurring_transaction_id: nil)
                                                 .pluck(:recurring_transaction_id).to_set
      scope = Current.family.recurring_transactions
                .where(status: :active, bill_type: %w[bill subscription installment])
                .where.not(account_id: nil)
      # Distinguish "nothing detected" from "everything detected is already
      # in the diagram" for the partial's empty-state message.
      @known_allocations_hidden = scope.where(id: covered_ids.to_a).exists?
      scope.where.not(id: covered_ids.to_a).order(:name, :id).map do |series|
        {
          id: series.id,
          name: series.display_name,
          cadence: PaycheckFlowPlanner.cadence_for(series),
          amount_cents: PaycheckFlowPlanner.to_family_cents(series.monthly_equivalent_amount, Current.family.currency),
          account_id: series.account_id
        }
      end
    end

    # The model's validation errors, field-keyed, for the 422 in-place
    # response (the dialog renders them inline).
    def error_messages(record)
      return { base: [ t("plan_flows.common.save_failed") ] } if record.nil?

      record.errors.messages.each_with_object({}) { |(field, messages), out| out[field.to_s] = messages.map(&:to_s) }
    end

    def family_users
      @family_users ||= Current.family.users.order(:created_at, :id)
    end

    def family_user_ids
      @family_user_ids ||= Current.family.users.pluck(:id).to_set
    end

    # The declared income series of the family, same scope as the Bills
    # income plan (bills_controller#load_paycheck_plan).
    def income_series
      @income_series ||= Current.family.recurring_transactions
                          .accessible_by(Current.user)
                          .where(bill_type: :income)
                          .where.not(status: %i[suggested ended])
                          .order(:name)
    end

    # Every family account, plan_order first (nulls last), then name.
    # plan_order is the "on the plan" marker (assigned by the add-accounts
    # forms); the Sankey node order is algorithmic, so it is never edited
    # from the page (spec A2).
    def flow_accounts
      @flow_accounts ||= Current.family.accounts
                              .visible
                              .order(Arel.sql("plan_order IS NULL"), :plan_order, :name)
    end

    # On the plan = an explicit plan_order marker, a linked income edge, a
    # plan allocation sourced from it, or a plan label (role / auto-transfer).
    # Unassigned allocations (round 3 R3: source bank removed) have a nil
    # account_id and must NOT pull a bank into the plan — a nil leaking into
    # this list becomes a phantom "Account" row in the diagram (round 7:
    # the owner's delete left a blank account row that survived reloads).
    def in_plan_account_ids
      (
        Current.family.accounts.where.not(plan_order: nil).pluck(:id) |
          Current.family.income_account_allocations.where.not(account_id: nil).pluck(:account_id) |
          Current.family.plan_allocations.where.not(account_id: nil).pluck(:account_id) |
          Current.family.accounts.where.not(plan_role: nil).pluck(:id) |
          Current.family.accounts.where.not(auto_transfer_to_account_id: nil).pluck(:id)
      ).compact
    end

    # The red overlay lines, pre-resolved server-side from the graph: one
    # line per flagged income, naming the flagged item (the fun money
    # allocation or the surplus line) and the gap.
    def over_plan_lines
      @graph[:over_plans].map do |over|
        income = @graph[:incomes].find { |row| row[:id] == over[:income_id] }
        # Round 11 issue 8 (Q3): a fan-out shortfall names the unsatisfied
        # BUCKET (a bank row, not an allocation) — nothing hidden about
        # which sub-account came up short.
        item = if over[:target] == "bucket" && over[:target_id]
          @graph[:banks].find { |row| row[:id] == over[:target_id] }&.dig(:name) || "a sub-account"
        elsif over[:target_id]
          @graph[:allocations].find { |row| row[:id] == over[:target_id] }&.dig(:name) || "fun money"
        else
          "the surplus line"
        end
        { income: income&.dig(:name) || "an income", item: item, amount: over[:shortfall_month] }
      end
    end

    def load_selected_income
      return nil unless params[:income].present?

      income_series.find { |series| series.id == params[:income] }
    end

    # The form's edge rows for one income, in center-column order:
    # { account_id => { mode:, value: (major units / 0.0-1.0), sort_index: } }.
    def draft_edges(_income)
      edges = params[:edges]
      rows = edges.respond_to?(:to_unsafe_h) ? edges.to_unsafe_h : {}
      return {} if rows.empty?
      flow_accounts.each_with_index.with_object({}) do |(account, index), draft|
        row = rows[account.id.to_s] || rows[account.id]
        next unless row.is_a?(Hash) && row["enabled"].present?

        mode = row["mode"].to_s
        next unless IncomeAccountAllocation.modes.include?(mode)

        raw = row["value"].to_s.strip
        draft[account.id] =
          case mode
          when "specific"
            { mode: mode, value: raw.presence, sort_index: index }
          when "percent"
            percent = raw.to_d / 100
            { mode: mode, value: percent.positive? && percent <= 1 ? percent : 0, sort_index: index }
          else
            { mode: mode, value: nil, sort_index: index }
          end
      end
    end

    # The plan-graph draft (M2 PR#2b), same shape as the preview action's:
    # the selected income's saved edges replaced by the form's edge rows,
    # and the allocation rows merged per-id over the saved set. Only the
    # sets the form actually carries are present — the planner applies each
    # draft key wholesale over the saved inputs.
    def graph_draft
      draft = {}

      income = load_selected_income
      if income && params[:edges].present?
        saved_edges = PaycheckFlowPlanner.edge_rows(Current.family)
        rows = draft_edges(income).map do |account_id, attrs|
          {
            income_id: income.id,
            account_id: account_id,
            mode: attrs[:mode],
            value_cents: attrs[:mode] == "specific" ? (attrs[:value].to_f * 100).round : nil,
            value_percent: attrs[:mode] == "percent" ? attrs[:value] : nil
          }
        end
        draft[:allocations] = saved_edges.reject { |edge| edge[:income_id] == income.id } + rows
      end

      if params[:allocations].present?
        draft[:plan_allocations] = merge_draft_allocation_rows
      end

      draft
    end

    # The form's unsaved allocation rows (params[:allocations], keyed by row
    # id) merged per-id over the saved set: an id in the form edits that
    # saved row, an unknown id is a new unsaved row, and saved rows absent
    # from the form survive untouched.
    def merge_draft_allocation_rows
      form_rows = params[:allocations].to_unsafe_h
      saved = PaycheckFlowPlanner.plan_allocation_rows(Current.family)
      form_ids = form_rows.keys.to_set

      saved.reject { |row| form_ids.include?(row[:id]) } +
        form_rows.map do |row_id, attrs|
          next unless attrs.is_a?(Hash)

          base = saved.find { |row| row[:id] == row_id } ||
                 { id: row_id, value_cents: nil, value_percent: nil, cadence: nil,
                   recurring_transaction_id: nil, auto_transfer: false,
                   category_id: nil }
          mode = attrs["mode"].to_s
          merged = base.merge(
            account_id: attrs["account_id"],
            name: attrs["name"].presence,
            kind: attrs["kind"],
            mode: mode,
            value_cents: %w[specific required].include?(mode) ? parse_value_cents(attrs["value"]) : nil,
            value_percent: mode == "percent" ? parse_value_percent(attrs["value_percent"]) : nil,
            cadence: attrs["cadence"].presence,
            recurring_transaction_id: attrs["recurring_transaction_id"].presence,
            auto_transfer: attrs["auto_transfer"].present?,
            # Round 16: the picker submits on every dialog save, so the
            # draft row carries the selection (blank = no category).
            category_id: attrs["category_id"].presence
          )
          # Round 10 issue 4: a draft savings row is the same savings-bucket
          # shape as the dialog (sanitized monthly figure, no hidden-field
          # leftovers) so the in-place preview matches what a save persists.
          # (Plain if-guard: `expr if cond` returns nil when cond is false,
          # which would drop the row from the merge.)
          if merged[:kind].to_s == "savings"
            merged = merged.merge(mode: "required",
              value_cents: parse_value_cents(attrs["value"]), value_percent: nil,
              cadence: nil, recurring_transaction_id: nil, auto_transfer: false)
          end
          merged
        end.compact
    end

    # The allocation dialog's row, planner-value shaped (value in major
    # units, percent in 0-100 — same conventions as the edge editor).
    def plan_allocation_params
      a = params[:plan_allocation]
      row = sanitize_plan_allocation_row(a)

      row
    end

    # The dialog row, shaped for persistence (owner round 10, issue 4;
    # round 20 U): kind "savings" is a savings bucket — a MONTHLY figure
    # (mode "required", value_cents) from an associated account. Round 20:
    # kind "fun_money" is the same shape (the dialog offers only name +
    # monthly amount for it), so both get the same server-side reshaping.
    # The associated account IS the existing account_id field (the planner
    # resolution and the Sankey band both key off it, so no second column
    # exists), but the dialog hides the mode / cadence / detected-bill
    # controls for these kinds, and hidden controls still submit — so those
    # stale values are dropped server-side and the mode is forced
    # "required".
    def sanitize_plan_allocation_row(a)
      mode = a[:mode].to_s
      row = {
        account: Current.family.accounts.find_by(id: a[:account_id]),
        name: a[:name].presence,
        kind: a[:kind],
        mode: mode,
        value_cents: %w[specific required].include?(mode) ? parse_value_cents(a[:value]) : nil,
        value_percent: mode == "percent" ? parse_value_percent(a[:value_percent]) : nil,
        cadence: a[:cadence].presence,
        recurring_transaction_id: a[:recurring_transaction_id].presence,
        auto_transfer: a[:auto_transfer].present?,
        # Round 16: the Sure category whose color the diagram uses; blank
        # clears (nil). Survives the savings-bucket reshaping below — the
        # picker is visible for every kind.
        category_id: a[:category_id].presence
      }
      # Round 10 issue 4 (savings) + round 20 (U, fun_money): a bucket is a
      # typed MONTHLY figure, never a bill shape, so the hidden controls'
      # stale values are dropped and the mode is forced "required".
      if %w[savings fun_money].include?(row[:kind].to_s)
        row[:mode] = "required"
        row[:value_cents] = parse_value_cents(a[:value])
        row[:value_percent] = nil
        row[:cadence] = nil
        row[:recurring_transaction_id] = nil
        row[:auto_transfer] = false
      end
      row
    end

    # Dialog value (major units, e.g. "300.00") in cents; blank or zero -> nil.
    def parse_value_cents(value)
      return nil if value.blank?

      cents = value.to_s.to_d * 100
      cents.zero? ? nil : cents
    end

    # Dialog percent (0-100, e.g. "10" = 10%) as a 0-1 fraction; blank or
    # zero -> nil.
    def parse_value_percent(value)
      return nil if value.blank?

      fraction = value.to_s.to_d / 100
      fraction.zero? ? nil : fraction
    end

    # Bank-config fields from the center card dialog (M2 PR#2b): plan_role,
    # auto_transfer_to_account_id, the linked-income edges, and round 11
    # issue 8's sub-account link + multi-target auto-transfer. Absent keys
    # are left alone, so the old two-field card form keeps working.
    def apply_bank_config(account)
      account_params = params.dig(:account)
      return unless account_params.respond_to?(:key?)

      if account_params.key?("plan_role")
        account.update!(plan_role: account_params["plan_role"].presence)
      end
      if account_params.key?("auto_transfer_to_account_id")
        account.update!(auto_transfer_to_account_id: account_params["auto_transfer_to_account_id"].presence)
      end
      if account_params.key?("parent_account_id")
        account.update!(parent_account_id: account_params["parent_account_id"].presence)
      end
      # Round 16: the logo picker (search + click-to-assign + clear). The
      # dialog's hidden input always submits the current value, so presence
      # = keep / assign, blank = clear. An unknown slug 422s through the
      # model validation (BankLogoSlugs.available — vendored files only).
      if account_params.key?("bank_logo_slug")
        account.update!(bank_logo_slug: account_params["bank_logo_slug"].presence)
      end
      # Round 11 issue 8: the checkbox submission order IS the band order —
      # the array is rebuilt from the param order, never re-sorted. The
      # "0" sent by an all-unchecked checkbox set is dropped.
      if account_params.key?("auto_transfer_target_ids")
        account.update!(auto_transfer_target_ids:
                          fan_out_target_ids(account_params["auto_transfer_target_ids"]))
      end
      save_bank_links(account) if params[:links].respond_to?(:to_unsafe_h) && params[:links].to_unsafe_h.any?
    end

    # The checked checkbox ids, in submission order (the diagram's band
    # order). `0` is the hidden-field sentinel for "none checked"; blank
    # entries are dropped. A validation failure raises and the update_account
    # rescue turns it into the 422 inline-error response.
    def fan_out_target_ids(raw)
      Array(raw).map { |value| value.to_s.strip.presence }
                .reject { |value| value == "0" }
                .compact
    end

    # Linked-income edges from the bank config dialog: the dialog lists
    # every income of the family, so the links param is complete — checked
    # rows upsert the edge (per-edge mode/value), unchecked existing rows
    # are removed. Same semantics as the edge editor save.
    def save_bank_links(account)
      links = params[:links].to_unsafe_h
      existing = Current.family.income_account_allocations
                               .where(account_id: account.id)
                               .index_by(&:income_series_id)

      links.each do |income_id, row|
        series = income_series.find { |s| s.id == income_id }
        next unless series

        row = row.to_unsafe_h if row.respond_to?(:to_unsafe_h)
        if row["enabled"].present?
          mode = row["mode"].to_s
          next unless IncomeAccountAllocation.modes.include?(mode)

          value = case mode
          when "specific"
            row["value"].to_s.strip.presence
          when "percent"
            percent = row["value"].to_s.strip.to_d / 100
            (percent.positive? && percent <= 1) ? percent : 0
          else
            nil
          end

          edge = existing.delete(series.id)
          if edge
            edge.update!(mode: mode, value: value)
          else
            IncomeAccountAllocation.create!(
              family: Current.family, income_series: series, account: account,
              mode: mode, value: value
            )
          end
        else
          existing.delete(series.id)&.destroy!
        end
      end
      # Remove only the edges of incomes the user can edit; edges on
      # non-editable incomes survive the dialog.
      editable_ids = income_series.map(&:id).to_set
      existing.each_value { |allocation| allocation.destroy! if editable_ids.include?(allocation.income_series_id) }
    end

    def redirect_back_to_flow
      redirect_to flow_plan_path(view: flow_view, income: params[:income].presence)
    end
end
