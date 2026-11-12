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

    # Round 31A (C14): pin the current input snapshot on a freshly saved
    # fun_money row (the drift prompt's baseline).
    persist_fun_money_input_snapshot(allocation) if result

    # Round 25 (Item 2): a target row dresses the target account — ship the
    # fresh bank dialog for that account so its kebab flips to the REVERSE
    # action without a reload. Round 26 R2 (in-place staleness): the SOURCE
    # bank's holder goes stale too (its Remove allocated_count), and the
    # OPENED dialog is the target's own (the allocated-sub popup lives in
    # it) — ship the full affected set so the in-place swap replaces every
    # holder that changed.
    accounts = [
      row[:target_account_id] ? Current.family.accounts.find_by(id: row[:target_account_id]) : nil,
      allocation.account
    ].compact.uniq
    return render_flow_json(ok: result, allocation_changed: true, accounts: accounts, error_object: allocation) if json_request?

    if result
      redirect_to flow_plan_path(view: flow_view), notice: t(".saved")
    else
      redirect_to flow_plan_path(view: flow_view), alert: t(".save_failed")
    end
  end

  def update_allocation
    allocation = Current.family.plan_allocations.find(params[:id])
    # Round 26 R2 (in-place staleness): the save can move the row's source
    # bank and/or target account — capture the OLD source before the
    # attributes apply (the old + new sources' Remove allocated_count and
    # the target's kebab matrix can all go stale from one save).
    old_source = allocation.account
    allocation.assign_attributes(plan_allocation_params)

    result = begin
      allocation.save!
      true
    rescue ActiveRecord::RecordInvalid
      false
    end

    # Round 31A (C14): pin the current input snapshot on a freshly saved
    # fun_money row (the drift prompt's baseline).
    persist_fun_money_input_snapshot(allocation) if result

    accounts = [ allocation.target_account, allocation.account, old_source ].compact.uniq
    return render_flow_json(ok: result, allocation_changed: true, accounts: accounts, error_object: allocation) if json_request?

    if result
      redirect_to flow_plan_path(view: flow_view), notice: t(".saved")
    else
      redirect_to flow_plan_path(view: flow_view), alert: t(".save_failed")
    end
  end

  def destroy_allocation
    allocation = Current.family.plan_allocations.find(params[:id])
    # Round 25 (Item 2): the REVERSE of "Make Allocated Sub-Account" — a
    # destroyed target row unfreezes its dressed bank row, so ship the fresh
    # bank dialog for the target account (the kebab flips back to "Make
    # Allocated Sub-Account"; no stale reverse action after the in-place
    # delete). Round 26 R2 (in-place staleness): the SOURCE bank's holder
    # goes stale too (its Remove allocated_count) — ship both, captured
    # BEFORE the destroy.
    target_account = allocation.target_account
    source_account = allocation.account
    allocation.destroy!
    return render_flow_json(allocation_changed: true, accounts: [ target_account, source_account ].compact.uniq) if json_request?

    redirect_to flow_plan_path(view: flow_view), notice: t(".saved")
  end

  # Remove a bank from the plan (owner review round 3, R3, the "Remove"
  # button in the bank config dialog). Semantics: the bank's income edges and
  # plan markers (order / role / auto-transfer) are dropped, and its
  # allocations PERSIST without a source bank — the planner reports them
  # with status "unassigned" (the diagram's "No Assignment" marker) and the
  # allocation dialog can re-assign a source bank.
  # Round 27 R1: removal is a FULL plan removal — in one transaction the
  # bank's income edges, plan markers, sub-account link AND its membership
  # in every other account's auto_transfer_target_ids fan-out all leave the
  # plan. A lingering fan-out entry would keep the account drawn as a $0.00
  # bank row (the planner's bank_ids union includes fan-out membership)
  # while in_plan_account_ids drops it (no fan-out membership there) — the
  # invisible ghost row (owner report 2026-11-06). Guarded (422): an
  # account named by a target allocation or with child sub-accounts.
  def remove_account
    account = Current.family.accounts.find(params[:account_id])

    # Guardrails (Round 27 R1): reject BEFORE touching anything. An account
    # named by a target allocation is drawn as its dressed allocation-pillar
    # node (removing it would orphan that row); an account with child
    # sub-accounts would leave those children pointing at a bank that left
    # the plan. Both ship the 422 contract — the in-place JS renders the
    # error inline and keeps the dialog open.
    if Current.family.plan_allocations.where(target_account_id: account.id).exists?
      return reject_removal(account, t(".has_target_allocation"))
    end
    if Current.family.accounts.where(parent_account_id: account.id).exists?
      return reject_removal(account, t(".has_sub_accounts"))
    end

    result = begin
      ActiveRecord::Base.transaction do
        Current.family.income_account_allocations.where(account_id: account.id).destroy_all
        Current.family.plan_allocations.where(account_id: account.id).update_all(account_id: nil)
        # Round 11 issue 8: the sub-account link + fan-out targets leave the
        # plan with the bank (a removed bank is no longer anyone's child and
        # fans out to no one).
        account.update!(plan_order: nil, plan_role: nil, auto_transfer_to_account_id: nil,
                        parent_account_id: nil, auto_transfer_target_ids: [])
        # Round 27 R1: the reverse of the Round 11 link — drop the removed
        # account from EVERY other account's fan-out (order-preserving, the
        # sync_parent_fan_out unlink semantics), or the entry keeps it in
        # the planner's bank list after the row it names has left.
        remove_account_from_fan_outs(account)
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

  # Round 27 R1: the 422 contract for a guarded removal — set the error on
  # the record and ship the in-place errors payload (JSON) / the alert
  # redirect (HTML fallback).
  def reject_removal(account, message)
    account.errors.add(:base, message)
    return render_flow_json(ok: false, error_object: account) if json_request?

    redirect_to flow_plan_path(view: flow_view), alert: message
  end

  # Round 27 R1: drop `account` from every family account whose fan-out
  # still names it. The removed parent link is the common case; the scan
  # covers ANY parent so a stale entry (hand-edit / legacy array) is
  # cleaned too. Order-preserving subtraction — the same semantics as
  # sync_parent_fan_out's unlink branch — and save! re-validates the
  # shrunken array against auto_transfer_targets_consistent (a failed
  # save! rolls back the whole removal transaction).
  def remove_account_from_fan_outs(account)
    Current.family.accounts.pluck(:id, :auto_transfer_target_ids)
              .select { |parent_id, targets| Array(targets).include?(account.id) }
              .each do |parent_id, targets|
        parent = Current.family.accounts.find(parent_id)
        parent.auto_transfer_target_ids = Array(targets) - [account.id]
        parent.save!
      end
  end

  # "Add Bank Account" modal (Turbo frame): lists the family accounts not
  # yet on the map (no plan_order, no allocation) for the attach form, plus
  # the manual bank-creation form.
  def add_accounts_modal
    in_flow = Current.family.income_account_allocations.pluck(:account_id).to_set
    # Round 26 (item 4): the Add-Account guardrail — the offered list is the
    # family's accounts MINUS the income series' own source and MINUS every
    # account already placed in ANOTHER area: a top-level bank row (plan_order),
    # a sub-row (parent_account_id), or the dressed allocation pillar (a target
    # allocation). Offering one would let it be placed in a second area (the
    # owner's duplication, discover-A 5.1 — the Add-Account click created the
    # invisible double-placement row).
    dressed_target_ids = Current.family.plan_allocations
      .where.not(target_account_id: nil).pluck(:target_account_id).to_set
    @unassigned_accounts = flow_accounts.reject do |account|
      account.plan_order.present? || in_flow.include?(account.id) ||
        account.parent_account_id.present? || dressed_target_ids.include?(account.id)
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
    # Round 26 (item 4): defense in depth on the server — the modal's offer
    # filter (add_accounts_modal) is the first guard; this one rejects a
    # submission that names an account ALREADY placed by any placement (a
    # top-level bank row via plan_order, a sub-row via the parent link, the
    # dressed allocation pillar via a target allocation, or the income edge's
    # source) with the render_flow_json 422 contract instead of silently
    # placing it a second time. A mixed batch 422s as a whole: the in-place
    # UI shows the error inline in the dialog, and the modal can only offer
    # valid ids, so nothing partial or half-placed can slip through.
    placed_ids = Current.family.accounts.where.not(plan_order: nil).pluck(:id).to_set
    placed_ids.merge(Current.family.accounts.where.not(parent_account_id: nil).pluck(:id))
    placed_ids.merge(Current.family.income_account_allocations.pluck(:account_id))
    placed_ids.merge(Current.family.plan_allocations
      .where.not(target_account_id: nil).pluck(:target_account_id))
    if Array(params[:account_ids]).compact.map(&:to_s)
        .any? { |account_id| placed_ids.include?(account_id) }
      return render_flow_json(ok: false, error_object: nil)
    end

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
    # Round 26 R2 (in-place staleness): captured BEFORE the transaction —
    # when the parent link changes (the sub-account popup's Save / the
    # main-section "Parent Account" picker), the OLD and NEW parents'
    # holders go stale (their fan-out rows + Remove allocated_count), so
    # the response ships their fresh dialogs too (the R25 cosmetic note:
    # the new parent's dialog lagged one reload — same mechanism, fixed
    # here).
    old_parent_id = account.parent_account_id

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

    affected = [account]
    if result
      new_parent_id = account.parent_account_id
      if new_parent_id != old_parent_id
        affected += Current.family.accounts.where(id: [ old_parent_id, new_parent_id ].compact).to_a
      end
    end
    return render_flow_json(accounts: affected.uniq, ok: result, error_object: account) if json_request?

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
      # Round 27 (owner item 4): the bank dialog form now carries a hidden
      # view input, so the in-place response renders the dialog readouts in
      # the SUBMITTING view (Q7: the display unit follows the active view).
      @view = flow_view
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
            available_bank_logos: @available_bank_logos,
            # Round 27 (owner item 4): the read-only dialog context (same
            # locals as the page-load render — the re-rendered partial is
            # the only place the new context lands).
            view: @view,
            required_display_amount: (@bank_required_display || {})[account.id],
            income_amounts: @income_display_amounts,
            # Round 30: the per-income required-split readouts (the
            # greyed 50/50 / Proportional readouts + the stored percents
            # behind the Percent behavior's inputs).
            required_splits: (@bank_required_splits || {})[account.id]
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
          # Round 22 (N1): the swapped-in rows carry the ****last4 spans too.
          allocation_bank_rows: (accounts.any? || removed_account) ? render_to_string(partial: "plan_flows/allocation_bank_rows", locals: { bank_rows: @in_plan_accounts, account_last4s: @account_last4s }) : nil,
          bank_dialogs: bank_dialogs.presence,
          bank_removed: removed_account ? "bank:#{removed_account.id}" : nil,
          # Round 7: the Sankey's in-plan / account-name values are
          # page-load state; refresh them after every in-place write or a
          # removed bank is re-synthesized as a phantom floor node until the
          # next reload.
          sankey: {
            accounts: @flow_accounts.map { |account| [ account.id, account.name ] }.to_h,
            # Round 26 R2: the sankey inPlanValue excludes dressed accounts
            # (sankey_in_plan_ids) so a po-dressed account never re-synthesizes
            # a phantom bank row next to its allocation-pillar node.
            in_plan: sankey_in_plan_ids
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
      # Round 26 R2 (owner item 3, MOVE): the sankey-only inPlan list — the
      # full list minus the dressed allocation targets. Feeds ONLY the sankey
      # inPlanValue (show.html.erb data attr + the render_flow_json chrome
      # payload); a dressed account is drawn exactly once, as its own
      # allocation-pillar node, and must never re-enter the bank column.
      @sankey_in_plan_ids = sankey_in_plan_ids
      # Round 22 (N1): the masked last-4 map the allocation dialog bank rows
      # render next to each name (****NNNN, the Add Account modal style);
      # the same helper the plan-graph payload and that modal already use —
      # plain 4 digits from plaid_accounts.mask, nil when absent.
      @account_last4s = PaycheckFlowPlanner.account_last4s_for(Current.family)
      @unplanned_count = @flow_accounts.count - @in_plan_accounts.count
      @plan_allocations = Current.family.plan_allocations.includes(:account).order(:name)
      @over_plan_lines = over_plan_lines
      # Round 31A (Fun Money v2): the Un-Allocated discrepancy lines (the
      # second line group in _chrome_top.erb).
      @discrepancy_lines = discrepancy_lines
      set_bank_dialog_context
    end

    # Round 27 (owner item 4): the read-only "Pull From Incomes" dialog
    # context — the account's required base in the ACTIVE VIEW UNIT (Per
    # Paycheck: the monthly base prorated over the required-edge paychecks,
    # mirroring the planner's required_per_paycheck; Per Month: as-is; nil
    # when the bank has no required base) + the per-income amounts
    # (per-paycheck + the month's occurrence count) the dialog's client-side
    # auto-fill and ratio re-derivation need. READ-ONLY: nothing here is
    # submitted — the dialog still sends only the per-income
    # links[<id>][mode|value] rows (save_bank_links is byte-identical).
    # The planner file stays untouched: it is built with the SAME inputs
    # plan_graph uses, and its private graph_required_monthly /
    # required_edge_funding_counts are read via send.
    def set_bank_dialog_context
      return unless @graph
      month = @month || Date.current
      planner = PaycheckFlowPlanner.new(**PaycheckFlowPlanner.graph_inputs_for(family: Current.family, month: month))
      required_monthly = planner.send(:graph_required_monthly)
      funding_counts = planner.send(:required_edge_funding_counts)
      # R5 fix (BUG-1): graph_required_monthly hands back CENTS; the view
      # layer formats + renders dollars (ERB L552 formats this directly,
      # and the dialog's $/thousands-separator labels are the JS's job).
      # The integer per-paycheck division keeps the R1-R4 semantics
      # exactly — only the scale changes.
      # R28B (BUG-B): the fallback divisor when a bank has no stored
      # required edge — required_edge_funding_counts is then 0 and the
      # display would nil to "—" / $0.00 even though the bank's required
      # base (its allocation required amount, graph_required_monthly)
      # still exists. The base prorates over the paychecks per month of
      # the incomes linked to the bank (any edge mode) — the average
      # occurrences per linked income (one read each; the occurrence
      # counts are the dialog's own read-only income amounts, built from
      # the same @graph the page renders).
      income_occurrences = @graph[:incomes].each_with_object({}) do |income, counts|
        counts[income[:id]] = income[:occurrences].size
      end
      linked_series_by_bank = Current.family.income_account_allocations
                                           .pluck(:account_id, :income_series_id)
                                           .group_by { |account_id, _| account_id }
      # Round 30 fix-round (BUG-R30-1, display-only): both paycheck-view
      # branches divide by the AVERAGE occurrences per linked income (the
      # composite paycheck) -- pre-fix the stored-required-edge branch
      # divided by the SUM of occurrences across all required edges (2
      # linked incomes x 2 paychecks = 4 -> the SoFi Checking display read
      # 25.00 instead of 100.00/2 = 50.00, and the dialog's dollar->percent
      # conversion on that base 422'd above 100). Settlement is untouched:
      # the planner still prorates the monthly base over the edge sum
      # (D-RECON: the UI figure is display-only). The funding-sum line stays
      # as a defensive last resort (counts empty with funding > 0 is
      # unreachable -- every required-edge income is a linked series with
      # the same occurrence count -- but it keeps the pre-fix value for
      # that case).
      @bank_required_display = @in_plan_accounts.index_by(&:id).transform_values do |account|
        base = required_monthly[account.id]
        funding = funding_counts.fetch(account.id, 0)
        counts = Array(linked_series_by_bank[account.id])
                           .filter_map { |_, series_id| income_occurrences[series_id] }
                           .select(&:positive?)
        if flow_view == "paycheck"
          if counts.any?
            base / (BigDecimal(counts.sum) / counts.size) / 100.0
          elsif funding.positive?
            base / funding / 100.0
          else
            nil
          end
        else
          base.zero? ? nil : base / 100.0
        end
      end
      @income_display_amounts = {}
      @graph[:incomes].each do |income|
        count = income[:occurrences].size
        next if count.zero?
        @income_display_amounts[income[:id]] = {
          paycheck: format("%.2f", income[:total_month].to_d / count),
          occurrences: count
        }
      end
      # Round 30: the required-split readouts the dialog seeds — the greyed
      # per-income readouts (50/50 / Proportional behaviors) and the stored
      # percents behind the Percent behavior's inputs. Per account with >=2
      # required edges: each income's percent = the D-REOPEN behavior
      # derivation (see required_split_pcts), and `display` =
      # (required_display * percent / 100) in the ACTIVE VIEW UNIT, the LAST
      # income absorbing so the display column sums exactly to the displayed
      # required (the UI invariant). No absorb when a percent is 0.00 (a nil
      # stored inside a custom split — D-UNDER: the shortfall stays
      # visible, no silent renormalization).
      @bank_required_splits = {}
      @in_plan_accounts.each do |account|
        required_edges = Current.family.income_account_allocations
                                      .where(family_id: Current.family.id, account_id: account.id, mode: "required")
                                      .order(:income_series_id).to_a
        next if required_edges.size < 2

        # Round 30: the display absorb follows the dialog row order
        # (@income_series' name order — the JS recalc absorbs in DOM row
        # order, so the server seed and the client must agree on which
        # income is "last").
        name_order = @income_series.map(&:id)
        required_edges.sort_by! { |edge| name_order.index(edge.income_series_id) || name_order.size }

        display_base = @bank_required_display[account.id]
        next unless display_base

        percents = required_split_pcts(required_edges)
        dollars = percents.map { |pct| (display_base * pct / 100.0).round(2) }
        full = percents.all? { |pct| pct.positive? } && (percents.sum - 100).abs < 0.005
        dollars[-1] = (display_base - dollars[0..-2].sum).round(2) if full
        @bank_required_splits[account.id] = required_edges.each_with_index.map do |edge, i|
          [ edge.income_series_id,
            { percent: format("%.2f", percents[i]),
              display: "$" + format("%.2f", dollars[i]) } ]
        end.to_h
      end
    end

    # Round 30 (D-REOPEN, controller side): the percents the dialog seeds
    # from — the behavior derivation with the last income (income_series_id
    # order) absorbing the 2-dp residual: all-nil or each-within-1c-of-100/n
    # -> the equal split; each-within-1c of the strict income-proportional
    # percents (pp from @income_display_amounts' per-paycheck figures) ->
    # those; otherwise the stored percents (a nil inside a custom split ->
    # 0.00 — D-UNDER, never renormalized).
    def required_split_pcts(required_edges)
      vals = required_edges.map { |edge| edge.value }
      n = vals.size
      equal_each = 100.0 / n
      pp_each = required_edges.map do |edge|
        pp = @income_display_amounts[edge.income_series_id]
        pp ? BigDecimal(pp[:paycheck]) : BigDecimal(0)
      end
      pp_sum = pp_each.sum
      strict_each = pp_sum.positive? ? pp_each.map { |pp| BigDecimal(100) * pp / pp_sum } : nil

      if vals.all?(&:nil?) ||
         vals.each_index.all? { |i| vals[i].nil? || (vals[i].to_d - BigDecimal(equal_each)).abs <= 0.01 }
        rounded = (0...n).map { |_i| equal_each.round(2) }
        rounded[-1] = (100 - rounded[0..-2].sum).round(2)
        rounded
      elsif strict_each &&
            vals.each_index.all? { |i| !vals[i].nil? && (vals[i].to_d - strict_each[i]).abs <= 0.01 }
        rounded = strict_each.map { |pct| pct.round(2) }
        rounded[-1] = (100 - rounded[0..-2].sum).round(2)
        rounded
      else
        vals.map { |v| v.nil? ? 0.0 : v.to_f.round(2) }
      end
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
          account_id: series.account_id,
          # Round 26 R4 (item 7a): the bill's own category (nil when
          # untagged) so the dialog's prefill paths can preselect it
          # (openKnownAllocation reads data-known-category; the dialog's
          # category radios mirror it through #checkCategoryRadio).
          # ADDITIVE: this builder feeds the dialog render + the chrome.known
          # swap only — the /plan/flow/graph payload is a different builder
          # (PaycheckFlowPlanner.plan_graph), which stays untouched.
          category_id: series.category_id
        }
      end
    end

    # The model's validation errors, field-keyed, for the 422 in-place
    # response (the dialog renders them inline).
    def error_messages(record)
      return { base: [ t("plan_flows.common.save_failed") ] } if record.nil?

      out = record.errors.messages.each_with_object({}) { |(field, messages), h| h[field.to_s] = messages.map(&:to_s) }
      # R5 fix (BUG-7): a bank-links 422 fails on an
      # IncomeAccountAllocation validation, not on the account record —
      # the account carries no errors, so the 422 body used to be
      # {"errors":{}} with zero user feedback. save_bank_links rescues
      # the invalid allocation into @bank_link_errors; merge it in so the
      # dialog gets the real field messages (e.g.
      # {"value":["must be greater than 0"]}). (nil for the other 422
      # paths — the account's own errors are the source there.)
      if @bank_link_errors
        @bank_link_errors.messages.each do |field, messages|
          out[field.to_s] = out.fetch(field.to_s, []) + messages.map(&:to_s)
        end
      end
      out
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
          Current.family.accounts.where.not(auto_transfer_to_account_id: nil).pluck(:id) |
          # Round 26 (item 4): sub-rows (parent-linked accounts) are drawn from
          # the graph's bank rows (sub_account_links), so a sub-account keeps
          # its bank dialog even after its accidental second placement
          # (plan_order) is dropped — every drawn row stays fully interactive
          # (discover-A 5.5: without a dialog the sub row's clicks are no-ops).
          Current.family.accounts.where.not(parent_account_id: nil).pluck(:id)
      ).compact
    end

    # Round 26 R2 (owner item 3, MOVE): the sankey's inPlanValue must EXCLUDE
    # dressed accounts (plan_allocations.target_account_id). The sankey bank
    # column is graphBanks + (inPlan − graphBanks); Round 26 R1 already drops a
    # dressed account from graphBanks (the planner's bank_ids reject), so a
    # po-dressed account left in inPlan would synthesize a second, floor-valued
    # bank row next to its own allocation-pillar node — the CDP MOVE cycle's
    # double-draw. Everything else that reads in_plan_account_ids (the bank
    # dialog loop, the allocation bank-source radios, the sub-account popup,
    # #checkAccountRadio) keeps the FULL list: a po'd or parent-linked dressed
    # account still renders its bank dialog, so its kebab stays usable in-place.
    def sankey_in_plan_ids
      in_plan_account_ids -
        Current.family.plan_allocations.where.not(target_account_id: nil)
                                       .pluck(:target_account_id).uniq
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
          # Round 10 issue 4 + round 25 R2: a draft bucket row (savings /
          # fun_money) keeps the user-chosen mode — the generic merge above
          # already shapes value_cents / value_percent to the mode, so the
          # in-place preview matches what a save persists, for every mode
          # (value validation stays model-owned). The bucket-specific drops
          # stay for the hidden controls: cadence (round 3 owns bucket
          # cadence) and the detected-bill link (hidden for buckets) + the
          # gone auto-transfer flag.
          # (Plain if-guard: `expr if cond` returns nil when cond is false,
          # which would drop the row from the merge.)
          if %w[savings fun_money].include?(merged[:kind].to_s)
            merged = merged.merge(cadence: nil, recurring_transaction_id: nil,
              auto_transfer: false)
          end
          # Round 31A (Fun Money v2): the fun_money row's config in the
          # draft preview (fun_money kind only; the other kinds never
          # submit these, and the merge drops them — same scoping as the
          # sanitizer). attrs is a plain string-keyed hash, so the
          # percent helper gets a symbol-keyed slice.
          if merged[:kind].to_s == "fun_money"
            percents = fun_money_distribution_percents(
              distribution: attrs["distribution"],
              distribution_percents: attrs["distribution_percents"]
            )
            merged = merged.merge(
              ownership: attrs["ownership"].presence,
              distribution: attrs["distribution"].presence,
              matching: attrs["matching"].presence,
              distribution_params: percents.empty? ? nil : { "percents" => percents }
            )
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
    # round 20 U; round 25 R2): kind "savings" / "fun_money" are buckets
    # funded from an associated account — and round 25 R2 makes every mode
    # valid for buckets (the Mode selector is visible + functional for all
    # four kinds), so the user-chosen mode and its value survive to the
    # model (value validation stays model-owned; the DB check constraint
    # enforces the same shape at the edge). The associated account IS the
    # existing account_id field (the planner resolution and the Sankey band
    # both key off it, so no second column exists), and the dialog's hidden
    # controls still submit for bucket kinds — cadence / detected-bill link
    # / auto-transfer are dropped server-side (stale hidden values; the
    # model is the backstop).
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
        category_id: a[:category_id].presence,
        # Round 25 (Item 2): the account the row dresses (the bank dialog's
        # "Make Allocated Sub-Account" popup sends the opened account's id;
        # the allocation dialog carries it in a hidden input so an edit
        # never silently unfreezes a dressed row). Blank = a plain row.
        # Existence + family membership are model-validated (422 contract).
        target_account_id: a[:target_account_id].presence
      }
      # Round 25 R2: buckets keep the user-chosen mode + value — the generic
      # shaping above already sets value_cents for required/specific and
      # value_percent for percent, exactly what the model wants for every
      # kind. Only the dialog's HIDDEN bucket controls are dropped here:
      # cadence (round 3 owns bucket cadence), the detected-bill link
      # (hidden for buckets — a bucket is never a bill shape) and the gone
      # auto-transfer flag.
      if %w[savings fun_money].include?(row[:kind].to_s)
        row[:cadence] = nil
        row[:recurring_transaction_id] = nil
        row[:auto_transfer] = false
      end
      # Round 31A (Fun Money v2): the fun_money row's configuration —
      # fun_money kind ONLY. For the other kinds the values are dropped
      # (nil) — a row edited from fun_money back to another kind clears its
      # config, and the non-fun_money dialog path is byte-identical to the
      # pre-Round-31A one (the stop-rule property). The model's
      # fun_money_configuration is the backstop for hand-edited rows.
      # Blank/null ownership = the legacy Household behavior (the planner
      # treats NULL ownership as Household).
      if a[:kind].to_s == "fun_money"
        row[:ownership] = fun_money_config_value(a, :ownership)
        row[:distribution] = fun_money_config_value(a, :distribution)
        row[:matching] = fun_money_config_value(a, :matching)
        row[:distribution_params] = fun_money_distribution_params(a, a[:kind])
      else
        row[:ownership] = nil
        row[:distribution] = nil
        row[:matching] = nil
        row[:distribution_params] = nil
      end
      row
    end

    # Dialog value (major units, e.g. "300.00") in cents; blank or zero -> nil.
    def parse_value_cents(value)
      return nil if value.blank?

      cents = value.to_s.to_d * 100
      cents.zero? ? nil : cents
    end

    # Round 31A (Fun Money v2): the fun_money config value shaping — only
    # values the model accepts pass through; anything else is nil (the
    # model's fun_money_configuration is the 422 backstop, and the dialog
    # only ever submits these for kind "fun_money").
    FM_DISTRIBUTIONS = %w[equal rational percent individual_leftover].freeze
    FM_MATCHINGS = %w[equalize per_income].freeze

    def fun_money_config_value(a, key)
      value = a[key].to_s.presence
      return nil if value.blank?

      case key
      when :distribution then FM_DISTRIBUTIONS.include?(value) ? value : nil
      when :matching then FM_MATCHINGS.include?(value) ? value : nil
      else value
      end
    end

    # Round 31A (Fun Money v2): the per-member percents (distribution
    # "percent", C9) the dialog submits as
    # plan_allocation[distribution_percents][<user_id>] — stored in
    # distribution_params["percents"] (jsonb, string values). Blank for
    # every other distribution (a change away from "percent" clears the
    # percents). The C14 input snapshot
    # (distribution_params["inputs_snapshot"]) is written separately at
    # save time (persist_fun_money_input_snapshot).
    def fun_money_distribution_params(a, kind)
      return nil unless kind.to_s == "fun_money"

      percents = fun_money_distribution_percents(a)
      percents.empty? ? nil : { "percents" => percents }
    end

    def fun_money_distribution_percents(a)
      raw = a[:distribution_percents]
      source = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : (raw.is_a?(Hash) ? raw : {})
      return {} if a[:distribution].to_s != "percent"

      source.each_with_object({}) do |(user_id, value), out|
        value = value.to_s.strip
        next if value.blank?

        num = value.to_d rescue nil
        out[user_id.to_s] = value if num && num >= 0 && num <= 100
      end
    end

    # Round 31A (C14): after a successful fun_money row save, persist the
    # reconciliation's CURRENT input totals (per-income I_k / B_k / S_k
    # cents) into the row's distribution_params as the drift snapshot. The
    # planner compares the snapshot with the current inputs on every
    # plan_graph run -> inputs_stale (the amber prompt, never a red
    # mismatch). update_columns: the snapshot write must never re-trigger
    # the validation 422 path or touch updated_at.
    def persist_fun_money_input_snapshot(allocation)
      return unless allocation.kind == "fun_money"

      month = Date.current
      planner = PaycheckFlowPlanner.new(**PaycheckFlowPlanner.graph_inputs_for(family: Current.family, month: month))
      planner.plan_graph
      inputs = planner.fun_money_inputs
      return unless inputs

      params = allocation.distribution_params.to_h
      params["inputs_snapshot"] = inputs.transform_keys(&:to_s).transform_values do |entry|
        { "i" => entry["i"].to_i, "b" => entry["b"].to_i, "s" => entry["s"].to_i }
      end
      allocation.update_columns(distribution_params: params)
    end

    # Round 31A (Fun Money v2): the RED Un-Allocated lines — one per
    # discrepancy strictly above the 100-cent tolerance, naming the income
    # ("an income" fallback, S10) or the aggregate Household line (C6).
    # Pre-resolved server-side from the graph (same pattern as
    # over_plan_lines); rendered as the second line group in
    # _chrome_top.erb (no new endpoint).
    def discrepancy_lines
      @discrepancy_lines ||= (@graph[:discrepancies] || []).map do |row|
        { income: row[:income_name] || "an income", amount: row[:un_allocated_month] }
      end
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
      # Round 25 (owner-confirmed direction): the opened account becomes a
      # sub-account of the SELECTED bank — the ORIGINAL direction. Around
      # the parent change, keep the old/new parent's auto_transfer_target_ids
      # in sync so the split band draws and the child's allocations fund via
      # the fan-out pool. OLD is read BEFORE the update. ORDER MATTERS: the
      # parent field is written FIRST (the model validation on the child),
      # then the parents' fan-out arrays — a parent's save! re-validates
      # auto_transfer_targets_consistent, which requires every target to be
      # a child of THAT parent, so the child's parent must be persisted
      # before the target id is added (same transaction).
      if account_params.key?("parent_account_id")
        old_parent_id = account.parent_account_id
        new_parent_id = account_params["parent_account_id"].presence
        validate_parent_change(account, old_parent_id, new_parent_id)
        account.update!(parent_account_id: new_parent_id)
        sync_parent_fan_out(old_parent_id, new_parent_id, account)
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

    # Round 25: pre-checks for a sub-account (parent) change, run BEFORE any
    # write inside update_account's transaction. The error field matches the
    # model's sub_account_consistent (:parent_account) so the 422 contract
    # (render_flow_json -> {"errors": {...}}) is identical to the model's
    # own failures. The "has its own sub-accounts" rule has no model
    # counterpart (the chain is only caught when a grandchild saves), so it
    # is enforced here.
    def validate_parent_change(account, old_parent_id, new_parent_id)
      return if new_parent_id.blank? || new_parent_id == old_parent_id

      parent = Current.family.accounts.find_by(id: new_parent_id)
      return reject_parent_change(account, "must name a family account") if parent.nil?
      return reject_parent_change(account, "cannot be the account itself") if parent.id == account.id
      if parent.parent_account_id.present?
        return reject_parent_change(account, "depth-1 only: the parent is already a sub-account")
      end
      has_children = Current.family.accounts.where(parent_account_id: account.id).exists?
      if has_children
        return reject_parent_change(account, "cannot become a sub-account while it has sub-accounts of its own")
      end
    end

    # Round 25 (owner-confirmed direction): keep the parent's fan-out in
    # sync with the opened account's sub-account (parent) change — the
    # SELECTED bank becomes the opened account's parent, so:
    #   - link  (new parent P present, P != OLD): P.auto_transfer_target_ids
    #     gains `account.id` (order-preserving) -> the split band draws and
    #     the child's allocations fund via the fan-out pool.
    #   - unlink (new parent blank/nil, OLD present): the old parent's
    #     auto_transfer_target_ids loses `account.id`.
    #   - re-parent (both present, different): remove from OLD first, then
    #     add to P.
    # Runs AFTER the parent write (see the call site: the parents' save!
    # re-validates auto_transfer_targets_consistent, which requires the
    # child's parent to be persisted first), inside update_account's
    # transaction, so a failed save! rolls back the whole request.
    def sync_parent_fan_out(old_parent_id, new_parent_id, account)
      # Old parent: drop this account from its fan-out (unlink / re-parent).
      if old_parent_id.present? && old_parent_id != new_parent_id
        old_parent = Current.family.accounts.find_by(id: old_parent_id)
        if old_parent
          old_parent.auto_transfer_target_ids =
            Array(old_parent.auto_transfer_target_ids) - [account.id]
          old_parent.save!
        end
      end

      # New parent: add this account to its fan-out (link / re-parent).
      if new_parent_id.present? && new_parent_id != old_parent_id
        parent = Current.family.accounts.find_by(id: new_parent_id)
        parent.auto_transfer_target_ids =
          (Array(parent.auto_transfer_target_ids) + [account.id]).uniq
        parent.save!
      end
    end

    # The 422 contract for validate_parent_change: set a field error on the
    # account and raise so update_account's rescue renders the inline error
    # (same shape as the model's validation failures).
    def reject_parent_change(account, message)
      account.errors.add(:parent_account, message)
      raise ActiveRecord::RecordInvalid.new(account)
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

      begin
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
                    when "required"
                      # Round 30: the stored percent of the bank's required
                      # amount this income funds (2 dp major units, blank =
                      # nil = the equal split). The model validates the
                      # 0 < value <= 100 range (the 422 {errors} path).
                      row["value"].to_s.strip.presence
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
      # R5 fix (BUG-7): the failing validation lives on the
      # IncomeAccountAllocation (value numericity), not on the account —
      # capture its errors for error_messages (the 422 body used to be
      # {"errors":{}}) and re-raise so update_account's existing rescue
      # rolls the transaction back exactly as before.
      rescue ActiveRecord::RecordInvalid => invalid
        @bank_link_errors = invalid.record.errors
        raise
      end
    end

    def redirect_back_to_flow
      redirect_to flow_plan_path(view: flow_view, income: params[:income].presence)
    end
end
