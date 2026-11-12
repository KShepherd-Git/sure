# Paycheck Flow Planner: the planning diagram — incomes -> banks
# -> allocations as a Sankey in the house Cashflow style. The diagram itself
# fetches /plan/flow/graph (PaycheckFlowPlanner.plan_graph); this controller
# renders the page shell, the dialogs, and the config writes.
class PlanFlowsController < ApplicationController
  include PreviewGateable
  before_action :require_preview_features!
  # resolve ?scenario= for every action
  # whose state it scopes. Absent / blank / "default" = the Default (live)
  # path — @scenario stays nil and every downstream branch is the live one
  # (the structural no-op invariants). Unknown ids: JSON callers get the
  # 404 contract, HTML callers get the house redirect + alert.
  before_action :load_scenario, only: [
    :show, :graph,
    :create_allocation, :update_allocation, :destroy_allocation,
    :update_account, :update_income, :update_paycheck_config
  ]

  # custom bank-logo upload limits. SVG is excluded on purpose
  # (an uploaded SVG can carry scripts; the built-in vendored set ships its
  # own SVGs and is not user input). 1 MiB keeps the blob blobby but sane.
  BANK_LOGO_CONTENT_TYPES = %w[image/png image/jpeg image/webp image/gif].freeze
  BANK_LOGO_MAX_BYTES = 1_048_576

  def show
    @month = Date.current
    @view = flow_view
    # the Per-Paycheck divisor unit (?paycheck_unit=). "income"
    # (DEFAULT): each Per Paycheck figure divides by how many times THAT
    # income lands in the month (the payload's per-income occurrences).
    # "family": the old family composite — divide by the month's total
    # paycheck count (primary 2 + secondary 2 = 4). Display-only; the settlement
    # math (the planner) is untouched.
    @paycheck_unit = paycheck_unit
    # (Flow Scenarios): the active scenario's snapshot is the draft's
    # base set (the design — no form draft on page load, same as today).
    # @scenario nil -> the call is token-for-token today's (Default is
    # byte-identical, the hard rule).
    @graph = @scenario ?
      PaycheckFlowPlanner.plan_graph(family: Current.family, month: @month, draft: scenario_draft) :
      PaycheckFlowPlanner.plan_graph(family: Current.family, month: @month)
    set_chrome_instance_vars
    # Static (non-plan-state) data the Sankey needs: account names and which
    # accounts are on the plan. The plan state itself comes from /plan/flow/graph.
    @account_names = @flow_accounts.map { |account| [ account.id, account.name ] }.to_h
    # "Known Allocations" list for the allocation dialog (
    # ) — see #known_allocations (also feeds the in-place JSON chrome).
    @known_allocations = known_allocations
    # (Direct Deposit): the per-member paycheck-config tabs (one
    # per EXISTING member) — member, their labeled income series (or
    # the empty state), the saved config, derived monthly + next-4.
    @paycheck_config_tabs = paycheck_config_tabs
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.plan"), plan_path ],
      [ t(".title"), nil ]
    ]
  end

  # Planning diagram JSON: the whole page state in one payload —
  # the saved state with draft rows merged over it (same draft pattern as
  # the preview action): the selected income's saved edges are replaced by
  # the form's edge rows, and the allocation rows merge per-id over the
  # saved set. No write.
  def graph
    @month = Date.current
    # the scenario's snapshot rows are
    # the draft's base set; the form's unsaved dialog rows win over them
    # .
    draft = graph_draft.presence
    draft = scenario_draft.merge(draft || {}) if @scenario
    @graph = PaycheckFlowPlanner.plan_graph(family: Current.family, month: @month, draft: draft.presence)
    # Additive top-level key ONLY for an active scenario — the Default
    # payload is byte-identical to the legacy one (no :scenario key).
    render json: @scenario ? @graph.merge(scenario: { id: @scenario.id, name: @scenario.name }) : @graph
  end

  # Allocation dialog save: upsert by (family, source bank, name)
  # re-saving the same row from the dialog edits it in place instead of
  # duplicating. Invalid rows flash the house alert, no 500.
  def create_allocation
    row = plan_allocation_params
    if @scenario
      # the dialog row merges into the scenario's
      # snapshot (the live path's upsert key: account + name), validated
      # with the real PlanAllocation model — the 422 contract is identical
      # to a live save. No live table is touched.
      result, allocation, saved_row = scenario_save_plan_allocation(row: row)
      persist_fun_money_input_snapshot_scenario(allocation, saved_row) if result
      accounts = [
        row[:target_account_id] ? Current.family.accounts.find_by(id: row[:target_account_id]) : nil,
        row[:account]
      ].compact.uniq
      return render_flow_json(ok: result, allocation_changed: true, accounts: accounts, error_object: allocation) if json_request?

      if result
        redirect_to flow_plan_path(scenario: @scenario.id, view: flow_view), notice: t(".saved")
      else
        redirect_to flow_plan_path(scenario: @scenario.id, view: flow_view), alert: t(".save_failed")
      end
    end
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

    # pin the current input snapshot on a freshly saved
    # fun_money row (the drift prompt's baseline).
    persist_fun_money_input_snapshot(allocation) if result

    # a target row dresses the target account — ship the
    # fresh bank dialog for that account so its kebab flips to the REVERSE
    # action without a reload. (in-place staleness): the SOURCE
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
    if @scenario
      # the update path addresses the snapshot row by
      # id (the live path's RecordNotFound contract is mirrored: unknown
      # id -> 404 JSON / the house redirect).
      row = plan_allocation_params
      result, allocation, saved_row = scenario_save_plan_allocation(row: row, id: params[:id])
      return not_found_allocation_redirect unless allocation.present?
      persist_fun_money_input_snapshot_scenario(allocation, saved_row) if result
      accounts = [
        row[:target_account_id] ? Current.family.accounts.find_by(id: row[:target_account_id]) : nil,
        row[:account]
      ].compact.uniq
      return render_flow_json(ok: result, allocation_changed: true, accounts: accounts, error_object: allocation) if json_request?

      if result
        redirect_to flow_plan_path(scenario: @scenario.id, view: flow_view), notice: t(".saved")
      else
        redirect_to flow_plan_path(scenario: @scenario.id, view: flow_view), alert: t(".save_failed")
      end
    end
    allocation = Current.family.plan_allocations.find(params[:id])
    # (in-place staleness): the save can move the row's source
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

    # pin the current input snapshot on a freshly saved
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
    if @scenario
      # the snapshot row leaves the scenario's edge /
      # allocation sets — nothing live is destroyed. The account set ships
      # the same way as the live path so the bank dialogs re-render.
      snapshot = @scenario.snapshot # jsonb reads deserialize fresh — capture once
      rows = snapshot["plan_allocations"] || []
      row = rows.find { |r| r["id"] == params[:id] }
      return not_found_allocation_redirect unless row

      snapshot["plan_allocations"] = rows.reject { |r| r["id"] == row["id"] }
      @scenario.update!(snapshot: snapshot, snapshotted_at: Time.current)
      accounts = [
        Current.family.accounts.find_by(id: row["target_account_id"]),
        Current.family.accounts.find_by(id: row["account_id"])
      ].compact.uniq
      return render_flow_json(allocation_changed: true, accounts: accounts) if json_request?

      redirect_to flow_plan_path(scenario: @scenario.id, view: flow_view), notice: t(".saved")
    end
    allocation = Current.family.plan_allocations.find(params[:id])
    # the REVERSE of "Make Allocated Sub-Account" — a
    # destroyed target row unfreezes its dressed bank row, so ship the fresh
    # bank dialog for the target account (the kebab flips back to "Make
    # Allocated Sub-Account"; no stale reverse action after the in-place
    # delete). (in-place staleness): the SOURCE bank's holder
    # goes stale too (its Remove allocated_count) — ship both, captured
    # BEFORE the destroy.
    target_account = allocation.target_account
    source_account = allocation.account
    allocation.destroy!
    return render_flow_json(allocation_changed: true, accounts: [ target_account, source_account ].compact.uniq) if json_request?

    redirect_to flow_plan_path(view: flow_view), notice: t(".saved")
  end

  # Remove a bank from the plan (the "Remove"
  # button in the bank config dialog). Semantics: the bank's income edges and
  # plan markers (order / role / auto-transfer) are dropped, and its
  # allocations PERSIST without a source bank — the planner reports them
  # with status "unassigned" (the diagram's "No Assignment" marker) and the
  # allocation dialog can re-assign a source bank.
  # removal is a FULL plan removal — in one transaction the
  # bank's income edges, plan markers, sub-account link AND its membership
  # in every other account's auto_transfer_target_ids fan-out all leave the
  # plan. A lingering fan-out entry would keep the account drawn as a $0.00
  # bank row (the planner's bank_ids union includes fan-out membership)
  # while in_plan_account_ids drops it (no fan-out membership there) — the
  # invisible ghost row (reported defect). Guarded (422): an
  # account named by a target allocation or with child sub-accounts.
  def remove_account
    account = Current.family.accounts.find(params[:account_id])

    # Guardrails: reject BEFORE touching anything. An account
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
        # the sub-account link + fan-out targets leave the
        # plan with the bank (a removed bank is no longer anyone's child and
        # fans out to no one).
        account.update!(plan_order: nil, plan_role: nil, auto_transfer_to_account_id: nil,
                        parent_account_id: nil, auto_transfer_target_ids: [])
        # the reverse of the link — drop the removed
        # account from EVERY other account's fan-out (order-preserving, the
        # sync_parent_fan_out unlink semantics), or the entry keeps it in
        # the planner's bank list after the row it names has left.
        remove_account_from_fan_outs(account)
      end
      true
    rescue ActiveRecord::RecordInvalid
      false
    end

    # a removed bank drops its config dialog element in the JS
    # (bank_removed) instead of shipping a dialog for a bank that left the plan.
    return render_flow_json(removed_account: account, ok: result, error_object: account) if json_request?

    if result
      redirect_to flow_plan_path(view: flow_view), notice: t(".removed")
    else
      redirect_to flow_plan_path(view: flow_view), alert: t(".save_failed")
    end
  end

  # the 422 contract for a guarded removal — set the error on
  # the record and ship the in-place errors payload (JSON) / the alert
  # redirect (HTML fallback).
  def reject_removal(account, message)
    account.errors.add(:base, message)
    return render_flow_json(ok: false, error_object: account) if json_request?

    redirect_to flow_plan_path(view: flow_view), alert: message
  end

  # drop `account` from every family account whose fan-out
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
        parent.auto_transfer_target_ids = Array(targets) - [ account.id ]
        parent.save!
      end
  end

  # "Add Bank Account" modal (Turbo frame): lists the family accounts not
  # yet on the map (no plan_order, no allocation) for the attach form, plus
  # the manual bank-creation form.
  def add_accounts_modal
    in_flow = Current.family.income_account_allocations.pluck(:account_id).to_set
    # the Add-Account guardrail — the offered list is the
    # family's accounts MINUS the income series' own source and MINUS every
    # account already placed in ANOTHER area: a top-level bank row (plan_order),
    # a sub-row (parent_account_id), or the dressed allocation pillar (a target
    # allocation). Offering one would let it be placed in a second area (the
    # duplication, discover-A 5.1 — the Add-Account click created the
    # invisible double-placement row).
    dressed_target_ids = Current.family.plan_allocations
      .where.not(target_account_id: nil).pluck(:target_account_id).to_set
    @unassigned_accounts = flow_accounts.reject do |account|
      account.plan_order.present? || in_flow.include?(account.id) ||
        account.parent_account_id.present? || dressed_target_ids.include?(account.id)
    end
    # the same last-4 the plan-flow payload carries,
    # so the "Add Bank Account" list shows ****1234-style suffixes too. nil
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
    # defense in depth on the server — the modal's offer
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
    # (ghost banks): the planner now renders plan-ordered banks with
    # no flow, and the response ships each new bank's config dialog so the
    # node is operable in place.
    return render_flow_json(accounts: added) if json_request?

    redirect_to flow_plan_path(view: flow_view), notice: t(".accounts_added")
  end

  # (create_account removed in , : the flow page no longer
  # creates its own accounts — the Add Account modal only lists Sure's
  # existing accounts; "Add Manual Account" goes to the house account page.)

  # Center card edits: ownership label (Home/Shared | member) + plan_order.
  # The card's single dropdown submits "shared" or "user:<user_id>" so one
  # control writes both plan_ownership and plan_owner_user_id. adds
  # the bank-config fields: plan_role (savings bucket / credit card payoff /
  # loan payoff label), auto_transfer_to_account_id, and the linked-income
  # edges (upserted by income+account, per-edge mode/value — same semantics
  # as the edge editor save: checked rows win, unchecked are removed).
  def update_account
    account = Current.family.accounts.find(params[:account_id])
    if @scenario
      # a scenario save touches ONLY the snapshot's edge
      # rows (the form's links section). The structural account fields
      # (ownership / plan role / auto-transfer / sub-account links) are live
      # family structure — the design: scenarios do not snapshot family
      # structure — so they are left untouched here. The leftover guardrail
      # and the model value validations run against the SCENARIO's edge set
      # (the same 422 contract as the live path).
      result = begin
        save_scenario_bank_links(account)
        true
      rescue ActiveRecord::RecordInvalid
        false
      end
      return render_flow_json(accounts: [ account ], ok: result, error_object: account) if json_request?

      if result
        redirect_to flow_plan_path(scenario: @scenario.id, view: flow_view)
      else
        redirect_to flow_plan_path(scenario: @scenario.id, view: flow_view), alert: t(".save_failed")
      end
    end
    ownership = params.dig(:account, :plan_ownership).to_s
    # (in-place staleness): captured BEFORE the transaction —
    # when the parent link changes (the sub-account popup's Save / the
    # main-section "Parent Account" picker), the OLD and NEW parents'
    # holders go stale (their fan-out rows + Remove allocated_count), so
    # the response ships their fresh dialogs too (the cosmetic note:
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

    affected = [ account ]
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

  # custom bank-logo upload from the avatar popup in the bank
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

  # remove the custom logo (the avatar falls back to the
  # built-in pick or the neutral circle server-side on the next save).
  def remove_bank_logo
    account = Current.family.accounts.find(params[:account_id])
    account.logo.purge_later if account.logo.attached?
    render json: { logo_url: nil }
  end

  # Income card edit: label the income to a family member (or clear the
  # label back to the account-holder fallback). adds
  # plan_max_account_links — the income's hard bank-link limit; blank clears.
  def update_income
    if @scenario
      # the scenario income dialog carries the snapshot's
      # income-policy override (enabled / zeroed / gross) — NOT a live
      # series edit (the structural fields stay live, the design). The
      # effective policy row is validated (the gross must be a positive
      # amount — the 422 contract via the income's in-memory errors).
      income = income_series.find { |series| series.id == params[:income_id] }
      return redirect_to flow_plan_path(scenario: @scenario.id) unless income

      policy = params.dig(:income_policy) || {}
      # The enabled field uses the house hidden-false + checked-true
      # checkbox pattern: CHECKED submits both values (Rack parses the
      # duplicate key as an array), UNCHECKED submits the hidden "false"
      # alone. A single .to_s on that array would read "false" for a
      # checked box — so normalize through Array and test membership
      # (the "1"/"0" flat convention stays accepted too).
      enabled_vals = policy["enabled"]
      enabled = enabled_vals.nil? ||
                Array(enabled_vals).any? { |v| %w[true 1].include?(v.to_s) }
      zeroed = Array(policy["zeroed"]).any? { |v| %w[true 1].include?(v.to_s) }
      gross_raw = policy["gross"].to_s.strip
      gross_cents = gross_raw.blank? ? nil : (gross_raw.to_d * 100).round

      if gross_raw.present? && (!gross_cents || gross_cents <= 0)
        message = t("plan_flows.income_config_dialog.gross_override_invalid")
        income.errors.add(:base, message)
        return render_flow_json(income: income, ok: false, error_object: income) if json_request?
        return redirect_to flow_plan_path(scenario: @scenario.id), alert: message
      end

      snapshot = @scenario.snapshot # jsonb reads deserialize fresh — capture once
      rows = snapshot["incomes"] ||= []
      row = rows.find { |r| r["series_id"] == income.id } ||
            { "series_id" => income.id, "enabled" => true, "zeroed" => false, "gross_per_paycheck_cents" => nil }
      row["enabled"] = enabled
      row["zeroed"] = zeroed
      row["gross_per_paycheck_cents"] = gross_cents
      rows << row unless rows.include?(row)
      @scenario.update!(snapshot: snapshot, snapshotted_at: Time.current)

      return render_flow_json(income: income, ok: true) if json_request?
      redirect_to flow_plan_path(scenario: @scenario.id)
    end
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

  # (Direct Deposit): save one member's paycheck config (gross /
  # frequency / anchor) against the member's labeled income series. The
  # planner overlay derives the pay dates from the house Schedule engine —
  # NO occurrences are written ( : the allocation "wanted" amounts are
  # immutable to this write). v1: a member with no labeled income series
  # gets a 422 (the dialog shows the empty state + the bills link instead).
  def update_paycheck_config
    member = family_users.find { |user| user.id == params[:user_id] }
    unless member
      return render(json: { errors: { base: [ "not found" ] } }, status: :not_found) if json_request?
      return redirect_to flow_plan_path
    end

    series = member_labeled_income_series(member)
    if series.nil?
      config = paycheck_config_for(member)
      config.errors.add(:base, :no_labeled_series)
      return render_flow_json(ok: false, error_object: config) if json_request?
      return redirect_to flow_plan_path(view: flow_view), alert: t(".no_series")
    end

    if @scenario
      # the config merges into the scenario's snapshot
      # copy (the live family_paycheck_configs table is untouched). The
      # EFFECTIVE config is validated with the real model — the 422
      # contract is identical to a live save.
      config = FamilyPaycheckConfig.new
      config.assign_attributes(
        family: Current.family,
        user: member,
        recurring_transaction: series,
        gross_per_paycheck_cents: paycheck_gross_cents(params),
        frequency: paycheck_frequency(params),
        anchor_date: params.dig(:paycheck_config, :anchor_date).presence
      )
      result = config.valid?
      if result
        row = {
          "user_id" => member.id,
          "recurring_transaction_id" => config.recurring_transaction_id,
          "gross_per_paycheck_cents" => config.gross_per_paycheck_cents,
          "frequency" => config.frequency,
          "anchor_date" => config.anchor_date&.to_date&.iso8601
        }
        snapshot = @scenario.snapshot # jsonb reads deserialize fresh — capture once
        rows = snapshot["paycheck_configs"] ||= []
        if (old = rows.find { |c| c["user_id"] == member.id })
          rows[rows.index(old)] = row
        else
          rows << row
        end
        @scenario.update!(snapshot: snapshot, snapshotted_at: Time.current)
      end
      return render_flow_json(ok: result, error_object: config, paycheck_config_member: member) if json_request?

      if result
        redirect_to flow_plan_path(scenario: @scenario.id, view: flow_view), notice: t(".saved")
      else
        redirect_to flow_plan_path(scenario: @scenario.id, view: flow_view), alert: t(".save_failed")
      end
    end

    config = paycheck_config_for(member)
    config.assign_attributes(
      family: Current.family,
      user: member,
      recurring_transaction: series,
      gross_per_paycheck_cents: paycheck_gross_cents(params),
      frequency: paycheck_frequency(params),
      anchor_date: params.dig(:paycheck_config, :anchor_date).presence
    )
    result = config.save
    return render_flow_json(ok: result, error_object: config, paycheck_config_member: member) if json_request?

    if result
      redirect_back_to_flow
    else
      redirect_to flow_plan_path(view: flow_view), alert: t(".save_failed")
    end
  end

  # -----------------------------------------------------------------------
  # the scenario CRUD + reset.
  # The picker is the only client (server-rendered menu + the create
  # dialog); the JSON contract is the design's, the HTML fallback is the
  # house redirect. "default" / unknown ids 404 (JSON) or redirect + alert
  # (HTML) — same contract on rename / delete / reset.
  # -----------------------------------------------------------------------

  # GET /plan/flow/scenarios — the picker's row list (the design index).
  def flow_scenarios
    render json: {
      ok: true,
      scenarios: Current.family.plan_scenarios.order(:created_at, :id)
                                           .map { |scenario| scenario_payload(scenario) },
      active_id: active_scenario_id
    }
  end

  # POST /plan/flow/scenarios — { name, source: 'current' | 'fresh' } ->
  # 201 { ok, scenario, graph } (the graph so the picker can switch without
  # a round-trip) / 422 { ok: false, errors } (the model's field errors).
  def flow_scenario_create
    name = params[:name].to_s.strip
    source = params[:source].to_s
    scenario = PlanScenario.new(
      family: Current.family,
      name: name,
      # The API vocabulary is 'current' / 'fresh'; anything else falls
      # through to the model's inclusion validation (422 'is invalid').
      source: source == "fresh" ? "fresh" : (source == "current" ? "reuse_current" : source)
    )
    unless scenario.valid?
      return render(json: { ok: false, errors: error_messages(scenario) }, status: :unprocessable_entity) if json_request?
      return redirect_to flow_plan_path, alert: scenario.errors.full_messages.to_sentence
    end

    scenario.snapshot = source == "fresh" ?
      PlanScenarioSnapshot.fresh(Current.family) :
      PlanScenarioSnapshot.reuse_current(Current.family)
    scenario.snapshotted_at = source == "fresh" ? nil : Time.current
    scenario.save!

    if json_request?
      render json: { ok: true, scenario: scenario_payload(scenario), graph: scenario_plan_graph(scenario) },
             status: :created
    else
      redirect_to flow_plan_path(scenario: scenario.id)
    end
  end

  # PATCH /plan/flow/scenarios/:id — { name } rename. 404 on 'default' /
  # unknown (the design); 422 { ok: false, errors } on the model's name
  # errors (blank / too long / reserved / case-insensitive collision).
  def flow_scenario_rename
    scenario = find_scenario_or_404
    return unless scenario

    scenario.name = params[:name].to_s.strip
    unless scenario.valid?
      return render(json: { ok: false, errors: error_messages(scenario) }, status: :unprocessable_entity) if json_request?
      return redirect_to flow_plan_path(scenario: scenario.id), alert: scenario.errors.full_messages.to_sentence
    end
    scenario.save!
    if json_request?
      render json: { ok: true, scenario: scenario_payload(scenario) }
    else
      redirect_to flow_plan_path(scenario: scenario.id)
    end
  end

  # DELETE /plan/flow/scenarios/:id — 404 on 'default' / unknown; 422 when
  # the request's own context IS this scenario (the design's backstop — the
  # picker's UX switches to Default first, so the backstop rarely fires).
  def flow_scenario_destroy
    scenario = find_scenario_or_404
    return unless scenario

    if active_scenario_id == scenario.id
      message = t("plan_flows.show.errors.scenario_active_delete")
      return render(json: { ok: false, errors: { scenario: [ message ] } }, status: :unprocessable_entity) if json_request?
      return redirect_to flow_plan_path, alert: message
    end

    scenario.destroy!
    if json_request?
      render json: { ok: true, deleted: scenario.id }
    else
      redirect_to flow_plan_path
    end
  end

  # POST /plan/flow/scenarios/:id/reset — REBUILD the scenario's snapshot
  # from its source (the design decision ): 'reuse_current' re-snapshots the
  # current live plan; 'fresh' re-derives the empty plan over the family's
  # current incomes. All in-scenario edits are discarded. 404 on
  # 'default' / unknown (same contract as rename).
  def flow_scenario_reset
    scenario = find_scenario_or_404
    return unless scenario

    snapshot = scenario.source == "reuse_current" ?
      PlanScenarioSnapshot.reuse_current(Current.family) :
      PlanScenarioSnapshot.fresh(Current.family)
    # update_columns: the rebuild is a state write, not a rename — skip the
    # name/source validations (they would be no-ops anyway).
    scenario.update_columns(snapshot: snapshot, snapshotted_at: scenario.source == "reuse_current" ? Time.current : nil)

    if json_request?
      render json: { ok: true, scenario: scenario_payload(scenario), graph: scenario_plan_graph(scenario) }
    else
      redirect_to flow_plan_path(scenario: scenario.id)
    end
  end

  # the scenario lookup shared by rename / delete / reset — the design
  # 404 contract ('default' and unknown ids alike). JSON: the 404 body;
  # HTML: the house redirect + alert (the UI never addresses 'default').
  def find_scenario_or_404
    id = params[:id].to_s
    scenario = id.blank? || id == PlanScenario::RESERVED_NAME ?
      nil :
      Current.family.plan_scenarios.find_by(id: id)

    unless scenario
      if json_request?
        render json: { ok: false, error: "unknown scenario" }, status: :not_found
      else
        redirect_to flow_plan_path, alert: t("plan_flows.show.scenario_missing")
      end
      return nil
    end
    scenario
  end

  # the scenario's picker row (the design shape) + the request's active
  # scenario id (nil for Default / unknown) + the scenario's plan graph
  # (the create / reset responses ship it so the UI can switch in place).
  def scenario_payload(scenario)
    snapshot = scenario.snapshot || {}
    {
      id: scenario.id,
      name: scenario.name,
      source: scenario.source,
      snapshot_count: {
        allocations: (snapshot["plan_allocations"] || []).size,
        edges: (snapshot["allocations"] || []).size,
        configs: (snapshot["paycheck_configs"] || []).size
      },
      snapshotted_at: scenario.snapshotted_at&.iso8601,
      created_at: scenario.created_at&.iso8601,
      updated_at: scenario.updated_at&.iso8601
    }
  end

  def active_scenario_id
    id = params[:scenario].presence
    return nil if id.nil? || id == PlanScenario::RESERVED_NAME
    Current.family.plan_scenarios.exists?(id: id) ? id : nil
  end

  def scenario_plan_graph(scenario)
    PaycheckFlowPlanner.plan_graph(
      family: Current.family, month: Date.current,
      draft: PaycheckFlowPlanner.scenario_draft(
        family: Current.family, month: Date.current, snapshot: scenario.snapshot
      )
    )
  end

  private

    # the active scenario for this
    # request. Blank / "default" = the Default (live plan) — the structural
    # no-op path where every scenario branch below is skipped and the
    # output is byte-identical to today. Unknown ids: the JSON contract is
    # the 404 (the sankey's graph fetch sends Accept: json, so a stale
    # ?scenario= in a URL never 500s the diagram); HTML callers (a
    # hand-typed ?scenario=) get the house redirect + alert (the design).
    def load_scenario
      @scenario = nil
      id = params[:scenario].presence
      return if id.nil? || id == PlanScenario::RESERVED_NAME

      @scenario = Current.family.plan_scenarios.find_by(id: id)
      return if @scenario

      if json_request?
        render json: { ok: false, error: "unknown scenario" }, status: :not_found
      else
        # The the design key lives under show (the page's canonical home);
        # reference it absolutely so every scoped action shares it.
        redirect_to flow_plan_path, alert: t("plan_flows.show.scenario_missing")
      end
    end

    # the planner draft for the active scenario (the design) — the
    # snapshot's stored rows symbolized to the planner's key shape, over the
    # live income base with the snapshot's paycheck-config copy + income
    # policy re-applied. nil-safe: @scenario must be non-nil (callers gate).
    def scenario_draft
      PaycheckFlowPlanner.scenario_draft(
        family: Current.family, month: Date.current, snapshot: @scenario.snapshot
      )
    end

    # the snapshot's edge rows (string-keyed) for the draft base —
    # the scenario-mode twin of the live PaycheckFlowPlanner.edge_rows read
    # in graph_draft / merge_draft_allocation_rows. Rows go through the
    # planner's scenario_row normalizer (symbol keys + BigDecimal numerics —
    # the jsonb round-trip stringifies BigDecimals) because the merged
    # drafts bypass scenario_draft.
    def scenario_snapshot_allocations
      (@scenario.snapshot["allocations"] || []).map { |row| PaycheckFlowPlanner.scenario_row(row) }
    end

    # the snapshot's plan-allocation rows for the draft base (the
    # scenario-mode twin of plan_allocation_rows).
    def scenario_snapshot_plan_allocations
      (@scenario.snapshot["plan_allocations"] || []).map { |row| PaycheckFlowPlanner.scenario_row(row) }
    end

    # a snapshot edge row wrapped with the model-like accessors the
    # bank config dialog reads (.mode / .value — the model's major-unit
    # conventions: specific -> dollars, percent -> the 0-1 fraction,
    # required -> the 0-100 major-unit percent, leftover -> nil).
    ScenarioEdge = Struct.new(:mode, :value, :income_series_id, :account_id)

    # the scenario's edge rows for one account, indexed by income
    # series id — the snapshot twin of the live index_by(&:income_series_id)
    # read in render_flow_json / the page-load bank dialog render.
    def scenario_edges_for_account(account_id)
      (@scenario.snapshot["allocations"] || [])
        .select { |row| row["account_id"] == account_id }
        .index_by { |row| row["income_id"] }
        .transform_values do |row|
          value = case row["mode"]
          when "specific" then row["value_cents"].to_d / 100
          when "percent" then row["value_percent"].to_d
          when "required" then row["required_percent"].to_d
          else nil
          end
          ScenarioEdge.new(row["mode"], value, row["income_id"], row["account_id"])
        end
    end

    # the scenario's plan-allocation rows as UNSAVED PlanAllocation
    # instances — the allocation dialog partial and the empty-state CTA read
    # model accessors, which work on unsaved records (the values are the
    # snapshot's; nothing is persisted). The snapshot order is the
    # snapshot-time order (plan_allocation_rows' natural order), so the
    # dialog list is byte-stable against the snapshot.
    def scenario_plan_allocations
      (@scenario.snapshot["plan_allocations"] || []).map do |row|
        allocation = PlanAllocation.new(
          id: row["id"],
          family_id: Current.family.id,
          account_id: row["account_id"],
          name: row["name"], kind: row["kind"], mode: row["mode"],
          value_cents: row["value_cents"], value_percent: row["value_percent"],
          cadence: row["cadence"], recurring_transaction_id: row["recurring_transaction_id"],
          auto_transfer: row["auto_transfer"], category_id: row["category_id"],
          target_account_id: row["target_account_id"],
          ownership: row["ownership"], distribution: row["distribution"],
          matching: row["matching"], distribution_params: row["distribution_params"]
        )
        allocation.account = Current.family.accounts.find_by(id: row["account_id"])
        allocation
      end
    end

    # the scenario's paycheck-config snapshot copy for one member (an
    # UNSAVED instance — the PaycheckDates math reads only frequency /
    # anchor_date / gross_per_paycheck_cents, so derived values compute
    # identically on the copy). nil when the member has no config row.
    def scenario_paycheck_config(member)
      row = (@scenario.snapshot["paycheck_configs"] || []).find { |c| c["user_id"] == member.id }
      return nil unless row

      # Snapshots are app-written iso8601, but a corrupted anchor_date must
      # not 500 the readout (no-crash on bad input): an unparseable row is
      # skipped as if the member had no config — the biweekly schedule math
      # needs a real anchor, so a nil-anchor copy is unusable.
      anchor_date = parse_snapshot_date(row["anchor_date"])
      return nil if anchor_date.nil?

      FamilyPaycheckConfig.new(
        family_id: Current.family.id,
        user_id: row["user_id"],
        recurring_transaction_id: row["recurring_transaction_id"],
        gross_per_paycheck_cents: row["gross_per_paycheck_cents"],
        frequency: row["frequency"],
        anchor_date: anchor_date
      )
    end

    # A snapshot anchor_date string, parsed; blank or unparseable -> nil.
    # (Same rescue/nil guard idiom as CashFlowsController#parse_date.)
    def parse_snapshot_date(value)
      return nil if value.blank?

      Date.parse(value)
    rescue Date::Error
      nil
    end

    # the allocation dialog's BANK SOURCE rows render
    # row into the active scenario's snapshot. The upsert key is the live
    # path's (account + name) for create, the explicit id for update. The
    # EFFECTIVE row is validated with the real PlanAllocation model, so the
    # 422 contract is identical to a live save; a new row gets a fresh uuid
    # the swapped-in rows carry the ****last4 spans too.
    # [ok, model, saved_row-or-nil]; [nil, nil, nil] when the update id is
    # not in the scenario.
    def scenario_save_plan_allocation(row:, id: nil)
      snapshot = @scenario.snapshot
      rows = snapshot["plan_allocations"] ||= []
      existing = id ? rows.find { |r| r["id"] == id } :
                    rows.find { |r| r["account_id"] == row[:account]&.id && r["name"] == row[:name] }
      return [ nil, nil, nil ] if id && existing.nil?

      allocation = PlanAllocation.new(
        id: existing ? existing["id"] : SecureRandom.uuid,
        family: Current.family,
        account: row[:account],
        name: row[:name], kind: row[:kind], mode: row[:mode],
        value_cents: row[:value_cents], value_percent: row[:value_percent],
        cadence: row[:cadence], recurring_transaction_id: row[:recurring_transaction_id],
        auto_transfer: row[:auto_transfer], category_id: row[:category_id],
        target_account_id: row[:target_account_id],
        ownership: row[:ownership], distribution: row[:distribution],
        matching: row[:matching], distribution_params: row[:distribution_params]
      )
      return [ false, allocation, nil ] unless allocation.valid?

      saved_row = PlanScenarioSnapshot.plan_allocation_row(allocation)
      if existing
        rows[rows.index(existing)] = saved_row
      else
        rows << saved_row
      end
      @scenario.update!(snapshot: snapshot, snapshotted_at: Time.current)
      [ true, allocation, saved_row ]
    end

    # ( twin for scenarios): pin the fun-money input
    # snapshot on a freshly-saved scenario row. The planner runs on the
    # scenario's draft (the just-updated snapshot), and the inputs land in
    # the SCENARIO row's distribution_params jsonb — no AR write.
    def persist_fun_money_input_snapshot_scenario(allocation, saved_row)
      return unless saved_row && allocation.kind == "fun_money"

      month = Date.current
      planner = PaycheckFlowPlanner.new(
        **PaycheckFlowPlanner.graph_inputs_for(family: Current.family, month: month),
        draft: PaycheckFlowPlanner.scenario_draft(
          family: Current.family, month: month, snapshot: @scenario.snapshot
        )
      )
      planner.plan_graph
      inputs = planner.fun_money_inputs
      return unless inputs

      snapshot = @scenario.snapshot
      rows = snapshot["plan_allocations"] || []
      row = rows.find { |r| r["id"] == allocation.id }
      params = (row["distribution_params"] || {}).to_h
      params["inputs_snapshot"] = inputs.transform_keys(&:to_s).transform_values do |entry|
        { "i" => entry["i"].to_i, "b" => entry["b"].to_i, "s" => entry["s"].to_i }
      end
      row["distribution_params"] = params
      @scenario.update!(snapshot: snapshot, snapshotted_at: Time.current)
    end

    # the sankey inPlanValue excludes dressed accounts
    # rows merge into the active scenario's snapshot edge set. Same value
    # shaping as the live path (draft_edges' major-unit conventions),
    # validated with the real IncomeAccountAllocation model (the 422
    # contract is identical); the leftover guardrail runs against the
    # SCENARIO's own edge set. No live table is touched.
    def save_scenario_bank_links(account)
      links = params[:links].to_unsafe_h
      snapshot = @scenario.snapshot
      rows = snapshot["allocations"] ||= []
      existing = rows.select { |row| row["account_id"] == account.id }
                     .index_by { |row| row["income_id"] }

      links.each do |income_id, link|
        link = link.respond_to?(:to_unsafe_h) ? link.to_unsafe_h : link
        series = income_series.find { |s| s.id == income_id }
        next unless series

        if link["enabled"].present?
          mode = link["mode"].to_s
          next unless IncomeAccountAllocation.modes.include?(mode)

          if mode == "leftover"
            conflict = rows.find do |row|
              row["income_id"] == series.id && row["mode"] == "leftover" &&
                row["account_id"] != account.id
            end
            if conflict
              record = IncomeAccountAllocation.new
              record.errors.add(:base, t("plan_flows.bank_config_dialog.leftover_conflict", name: series.name))
              @bank_link_errors = record.errors
              raise ActiveRecord::RecordInvalid.new(record)
            end
          end

          # Numeric (BigDecimal) in major units — the same convention the
          # live path hands to the IncomeAccountAllocation model, and what
          # PlanScenarioSnapshot.edge_row's `value * 100` arithmetic needs
          # (a String would repeat, not multiply). The required-mode
          # carrier is "" when the split is equal (the dialog's hidden
          # input is nameless/empty in required mode — view seed +
          # bank_config_dialog_controller#recalcPullFrom), so blank maps
          # to nil = equal split, mirroring the live path's
          # `presence` ("" -> nil is VALID; "" -> 0 would trip the
          # model's 0 < value <= 100 range check and 422 spuriously).
          value = case mode
          when "specific"
            link["value"].to_s.strip.to_d
          when "percent"
            percent = link["value"].to_s.strip.to_d / 100
            percent.positive? && percent <= 1 ? percent : 0
          when "required"
            link["value"].to_s.strip.presence&.to_d
          else
            nil
          end

          record = IncomeAccountAllocation.new(
            family: Current.family, income_series: series,
            account: account, mode: mode, value: value
          )
          unless record.valid?
            @bank_link_errors = record.errors
            raise ActiveRecord::RecordInvalid.new(record)
          end

          row = PlanScenarioSnapshot.edge_row(
            income_series_id: series.id, account_id: account.id, mode: mode, value: value
          )
          if (old = existing.delete(series.id)) # out of the destroy set
            rows[rows.index(old)] = row
          else
            rows << row
          end
        else
          if (old = existing.delete(series.id))
            rows.delete(old)
          end
        end
      end
      # Un-submitted pre-existing rows leave the account's edge set (the
      # live path's unchecked-destroy rule).
      existing.each_value { |row| rows.delete(row) }

      @scenario.update!(snapshot: snapshot, snapshotted_at: Time.current)
    end

    # the allocation write's unknown-id 404 contract (the live path's
    # RecordNotFound, mirrored for the snapshot rows).
    def not_found_allocation_redirect
      if json_request?
        render(json: { errors: { base: [ "not found" ] } }, status: :not_found)
      else
        redirect_to flow_plan_path(scenario: @scenario.id, view: flow_view)
      end
    end

    def flow_view
      %w[paycheck monthly].include?(params[:view].to_s) ? params[:view] : "paycheck"
    end

    # the Per-Paycheck unit choice (the kebab right of the
    # Manage/View control). "income" is the DEFAULT (per-income occurrence
    # count); "family" keeps the old family-composite divisor (the month's
    # total paycheck count). Persisted as ?paycheck_unit= like ?view=.
    def paycheck_unit
      %w[income family].include?(params[:paycheck_unit].to_s) ? params[:paycheck_unit] : "income"
    end

    # In-place diagram updates: the page's
    # mutation forms submit as Accept: application/json fetches (data-turbo
    # disabled) instead of full-reload submissions, so the Sankey can tween
    # to the new layout in place. These requests get a JSON response:
    # 200 + the fresh plan-graph JSON + the re-rendered stale chrome
    # fragments on success, 422 + the model's field errors on a validation
    # failure. Plain HTML requests keep the redirect + flash behavior.
    def json_request?
      request.format == Mime[:json]
    end

    def render_flow_json(ok: true, allocation_changed: false, accounts: [], income: nil, removed_account: nil, error_object: nil, paycheck_config_member: nil)
      return render(json: { errors: error_messages(error_object) }, status: :unprocessable_entity) unless ok

      # (Flow Scenarios): for an active scenario the plan re-derives from
      # the (just-updated) snapshot; the Default call is token-for-token
      # today's (the structural no-op invariant).
      graph = @scenario ?
        PaycheckFlowPlanner.plan_graph(family: Current.family, month: Date.current, draft: scenario_draft) :
        PaycheckFlowPlanner.plan_graph(family: Current.family, month: Date.current)
      @graph = graph
      # the family's scenarios for the
      # view input, so the in-place response renders the dialog readouts in
      # the SUBMITTING view (the display unit follows the active view).
      @view = flow_view
      set_chrome_instance_vars
      @known_allocations = known_allocations

      # (ghost banks): the bank config dialog for every affected bank,
      # so an in-place add/edit makes the (new) bank node operable without a
      # reload. A removed bank ships no dialog — the JS drops its element.
      bank_dialogs = removed_account ? nil : accounts.map do |account|
        {
          node_id: "bank:#{account.id}",
          html: render_to_string(partial: "plan_flows/bank_config_dialog", locals: {
            account: account,
            # (Flow Scenarios): the dialog's edge rows come from the
            # scenario's snapshot (wrapped with the model-like accessors the
            # partial reads — .mode / .value); Default is the live table.
            edges: @scenario ?
              scenario_edges_for_account(account.id) :
              Current.family.income_account_allocations.where(account_id: account.id).index_by(&:income_series_id),
            # the picker's searchable logo list (same-origin
            # assets; client-side filtering, no endpoint).
            available_bank_logos: @available_bank_logos,
            # fix: graph_required_monthly hands back CENTS; the view
            # locals as the page-load render — the re-rendered partial is
            # the only place the new context lands).
            view: @view,
            required_display_amount: (@bank_required_display || {})[account.id],
            income_amounts: @income_display_amounts,
            # the per-income required-split readouts (the
            # greyed 50/50 / Proportional readouts + the stored percents
            # behind the Percent behavior's inputs).
            required_splits: (@bank_required_splits || {})[account.id],
            # the active paycheck unit (the dialog's hidden
            # paycheck_unit input — in-place saves re-render the readouts
            # in the selected unit; the save form posts it back).
            paycheck_unit: paycheck_unit,
            # fix-round (BUG- -1, display-only): both paycheck-view
            # page-load render — recomputed in set_chrome_instance_vars so
            # it is current after the just-saved change).
            leftover_accounts: @leftover_accounts
          })
        }
      end
      # the old family composite — the monthly base prorated
      # READ-ONLY paycheck readout derived from the live plan graph, so it
      # must refresh after EVERY in-place save that changes the plan (a bank
      # link / allocation / income save) — not only after a paycheck-config
      # save (the old gate). render_flow_json runs after any in-place
      # mutation and re-renders the graph, so re-render the readout whenever
      # the bank dialogs are present (all saves except a removal); a fresh
      # dialog element gets a fresh controller that re-fetches the graph and
      # re-fills the per-member tables.
      if bank_dialogs
        bank_dialogs << {
          node_id: "paycheck-config",
          html: render_to_string(partial: "plan_flows/paycheck_config_dialog", locals: {
            tabs: paycheck_config_tabs,
            month: Date.current
          })
        }
      end

      render json: {
        graph: graph,
        chrome: {
          top: render_to_string(partial: "plan_flows/chrome_top"),
          overlays: render_to_string(partial: "plan_flows/chrome_overlays"),
          # legacy defensive value.
          # on every in-place write so it can appear or disappear without a
          # reload (#inPlaceSubmit swaps the holder's contents; empty
          # fragment = no red lines = icon gone). The partial reads the
          # same @over_plan_lines / @discrepancy_lines set above (unit-aware
          # amounts, the design decision 3).
          issues_icon: render_to_string(partial: "plan_flows/flow_issues_icon"),
          known: allocation_changed ? render_to_string(partial: "plan_flows/known_allocations", locals: { known_allocations: @known_allocations, known_hidden: @known_allocations_hidden }) : nil,
          # the allocation dialog's BANK SOURCE rows render
          # once at page load, so an in-place account change ships a fresh
          # fragment for #inPlaceSubmit to swap in place (the off-plan
          # row a dialog may append is out of scope here).
          # the swapped-in rows carry the ****last4 spans too.
          allocation_bank_rows: (accounts.any? || removed_account) ? render_to_string(partial: "plan_flows/allocation_bank_rows", locals: { bank_rows: @in_plan_accounts, account_last4s: @account_last4s }) : nil,
          bank_dialogs: bank_dialogs.presence,
          bank_removed: removed_account ? "bank:#{removed_account.id}" : nil,
          # the Sankey's in-plan / account-name values are
          # page-load state; refresh them after every in-place write or a
          # removed bank is re-synthesized as a phantom floor node until the
          # next reload.
          sankey: {
            accounts: @flow_accounts.map { |account| [ account.id, account.name ] }.to_h,
            # the sankey inPlanValue excludes dressed accounts
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
      # the usable bank-logo set (vendored file + label) the bank
      # config dialog's searchable picker filters over. The plan-graph
      # payload carries the same list at its root (available_bank_logos) so
      # the in-place JS path needs no extra source.
      @available_bank_logos = BankLogoSlugs.available
      @income_series = income_series
      @flow_accounts = flow_accounts
      @in_plan_account_ids = in_plan_account_ids
      @in_plan_accounts = @flow_accounts.select { |account| @in_plan_account_ids.include?(account.id) }
      # (Flow Scenarios): in a scenario the "already planned" set comes
      # full list minus the dressed allocation targets. Feeds ONLY the sankey
      # inPlanValue (show.html.erb data attr + the render_flow_json chrome
      # payload); a dressed account is drawn exactly once, as its own
      # allocation-pillar node, and must never re-enter the bank column.
      @sankey_in_plan_ids = sankey_in_plan_ids
      # the masked last-4 map the allocation dialog bank rows
      # render next to each name (****NNNN, the Add Account modal style);
      # the same helper the plan-graph payload and that modal already use —
      # plain 4 digits from plaid_accounts.mask, nil when absent.
      @account_last4s = PaycheckFlowPlanner.account_last4s_for(Current.family)
      @unplanned_count = @flow_accounts.count - @in_plan_accounts.count
      # (Flow Scenarios): the allocation dialog loop + empty-state CTA
      # render the scenario's snapshot rows (unsaved model instances with
      # the snapshot's values — the partial's accessors work on both);
      # Default is the live relation (token-for-token today).
      @plan_allocations = @scenario ? scenario_plan_allocations :
                              Current.family.plan_allocations.includes(:account).order(:name)
      # (Direct Deposit): the member's labeled income series —
      # header picker (chrome, not plan state — the live table in both
      # modes, order stable by creation).
      @scenarios = Current.family.plan_scenarios.order(:created_at, :id)
      # the member's existing paycheck config (one per member,
      # account id of its existing leftover edge (IncomeAccountAllocation
      # mode "leftover"). The bank dialog greys the "Leftover" option for a
      # member's other allocations when that paycheck already has a leftover
      # edge to a different account (one Leftover per member's paycheck).
      # Recomputed here (set_chrome_instance_vars runs in both show and the
      # in-place JSON responses) so the guardrail is current after every
      # save, not just at page load.
      @leftover_accounts = leftover_accounts
      @over_plan_lines = over_plan_lines
      # (Fun Money v2): the Un-Allocated discrepancy lines (the
      # second line group in _chrome_top.erb).
      @discrepancy_lines = discrepancy_lines
      set_bank_dialog_context
    end

    # member ( : no member creation here). Each tab carries the member,
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
      # fix: graph_required_monthly hands back CENTS; the view
      # layer formats + renders dollars (ERB L552 formats this directly,
      # and the dialog's $/thousands-separator labels are the JS's job).
      # The integer per-paycheck division keeps the - semantics
      # exactly — only the scale changes.
      # The fallback divisor when a bank has no stored
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
      # fix-round (BUG- -1, display-only): both paycheck-view
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
          if paycheck_unit == "family"
            # the old family composite — the monthly base prorated
            # over the month's TOTAL paycheck count (every income's
            # occurrences summed; primary 2 + secondary 2 = 4). The funding-sum
            # fallback (no paycheck dates — the impossible case) keeps the
            # legacy defensive value.
            family_total = @graph[:total_paychecks].to_i
            if family_total.positive?
              base / family_total / 100.0
            elsif funding.positive?
              base / funding / 100.0
            else
              nil
            end
          elsif counts.any?
            # default (the line, kept verbatim): the base over
            # the AVERAGE occurrences per linked income — the per-income
            # occurrence unit in the composite dialog readout.
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
      # the required-split readouts the dialog seeds — the greyed
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

        # the display absorb follows the dialog row order
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

    # (D-REOPEN, controller side): the percents the dialog seeds
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

    # "Known Allocations" list for the allocation dialog (
    # ; : only what is NOT already in the diagram): the bills /
    # auto-tracked subscriptions Sure already has, MINUS the ones a plan
    # allocation already links — those show in the diagram, so the dialog
    # offers only the rest. When every detected bill is planned,
    # @known_allocations_hidden is set so the empty list says
    # "already in the diagram" instead of implying nothing was detected.
    def known_allocations
      # (Flow Scenarios): in a scenario the "already planned" set comes
      # from the snapshot's plan-allocation rows (the known list must track
      # the scenario's plan, not the live one); Default is the live pluck.
      covered_ids = @scenario ?
        (@scenario.snapshot["plan_allocations"] || [])
                              .filter_map { |row| row["recurring_transaction_id"] }.to_set :
        Current.family.plan_allocations.where.not(recurring_transaction_id: nil)
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
          # the top-bar figure is UNIT-AWARE —
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
      # fix: a bank-links 422 fails on an
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

    # (Direct Deposit): the member's labeled income series —
    # bill_type income, active, manual, explicitly labeled to the member
    # (plan_owner_user_id == member.id). First by (name, id) so the overlay
    # target is deterministic when a member labels more than one series.
    # nil = the member has no labeled series (the dialog's empty state).
    def member_labeled_income_series(member)
      Current.family.recurring_transactions
                   .where(bill_type: :income, status: :active, manual: true,
                          plan_owner_user_id: member.id)
                   .order(:name, :id)
                   .first
    end

    # the member's existing paycheck config (one per member,
    # unique (family_id, user_id)) or a new one ready to assign.
    def paycheck_config_for(member)
      Current.family.family_paycheck_configs.find_or_initialize_by(user: member)
    end

    # the paycheck-config dialog tabs — one per EXISTING family
    # member ( : no member creation here). Each tab carries the member,
    # their labeled series (nil -> the panel's empty state), the saved
    # config (or nil), and the derived monthly cents + next-4 pay dates
    # (nil when there is no config to derive from).
    def paycheck_config_tabs
      family_users.map do |member|
        # (Flow Scenarios): the readout tabs carry the scenario's
        # paycheck-config snapshot copy (an UNSAVED instance — the
        # PaycheckDates math reads only its fields, so the derived values
        # compute identically); Default is the live saved config.
        config = @scenario ? scenario_paycheck_config(member) : paycheck_config_for(member)
        saved = @scenario ? !config.nil? : config.persisted?
        {
          member: member,
          series: member_labeled_income_series(member),
          config: saved ? config : nil,
          derived_monthly_cents: saved ? config.derived_monthly_cents(Date.current) : nil,
          upcoming: saved ? config.upcoming_dates : []
        }
      end
    end

    # + : a draft bucket row (savings /
    # id -> the account id of its existing leftover edge (IncomeAccountAllocation
    # mode "leftover"). A member's paycheck may fund at most ONE account as
    # its leftover (the per-paycheck remainder), so the bank dialog greys the
    # "Leftover" option for the member's other allocations. Nil-valued entries
    # never occur (mode "leftover" always carries an account_id).
    # (Flow Scenarios): in a scenario the map comes from the snapshot's
    # edge rows (the guardrail greys against the scenario's own leftover);
    # Default is the live pluck.
    def leftover_accounts
      if @scenario
        (@scenario.snapshot["allocations"] || [])
                 .select { |row| row["mode"] == "leftover" }
                 .to_h { |row| [ row["income_id"], row["account_id"] ] }
      else
        Current.family.income_account_allocations
                     .where(mode: "leftover")
                     .pluck(:income_series_id, :account_id)
                     .to_h
      end
    end

    # gross per paycheck in cents. The form submits a 2-dp
    # major-unit amount (step 0.01); 1250.50 -> 125050. Blank/invalid ->
    # nil (the model's presence + greater_than 0 validations reject it).
    def paycheck_gross_cents(params)
      gross = params.dig(:paycheck_config, :gross).presence
      return nil if gross.blank?

      (gross.to_d * 100).round
    end

    # the frequency, defaulting to semi_monthly when the
    # param is blank. An out-of-set value falls through to the model's
    # inclusion validation (a 422, not a silent default).
    def paycheck_frequency(params)
      frequency = params.dig(:paycheck_config, :frequency).presence
      frequency.presence || FamilyPaycheckConfig::FREQUENCY_SEMI_MONTHLY
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
    # Unassigned allocations ( : source bank removed) have a nil
    # account_id and must NOT pull a bank into the plan — a nil leaking into
    # this list becomes a phantom "Account" row in the diagram (:
    # the delete left a blank account row that survived reloads).
    def in_plan_account_ids
      (
        Current.family.accounts.where.not(plan_order: nil).pluck(:id) |
          Current.family.income_account_allocations.where.not(account_id: nil).pluck(:account_id) |
          Current.family.plan_allocations.where.not(account_id: nil).pluck(:account_id) |
          Current.family.accounts.where.not(plan_role: nil).pluck(:id) |
          Current.family.accounts.where.not(auto_transfer_to_account_id: nil).pluck(:id) |
          # the account the row dresses (the bank dialog's
          # the graph's bank rows (sub_account_links), so a sub-account keeps
          # its bank dialog even after its accidental second placement
          # (plan_order) is dropped — every drawn row stays fully interactive
          # (discover-A 5.5: without a dialog the sub row's clicks are no-ops).
          Current.family.accounts.where.not(parent_account_id: nil).pluck(:id)
      ).compact
    end

    # buckets keep the user-chosen mode + value — the generic
    # dressed accounts (plan_allocations.target_account_id). The sankey bank
    # column is graphBanks + (inPlan − graphBanks); already drops a
    # dressed account from graphBanks (the planner's bank_ids reject), so a
    # po-dressed account left in inPlan would synthesize a second, floor-valued
    # bank row next to its own allocation-pillar node — the the browser harness MOVE cycle's
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
        # A fan-out shortfall names the unsatisfied
        # BUCKET (a bank row, not an allocation) — nothing hidden about
        # which sub-account came up short.
        item = if over[:target] == "bucket" && over[:target_id]
          @graph[:banks].find { |row| row[:id] == over[:target_id] }&.dig(:name) || "a sub-account"
        elsif over[:target_id]
          @graph[:allocations].find { |row| row[:id] == over[:target_id] }&.dig(:name) || "fun money"
        else
          "the surplus line"
        end
        # pre-checks for a sub-account (parent) change, run BEFORE any
        # the per-paycheck amount in the Per Paycheck view, the monthly
        # amount in the Per Month view (one line per income; the
        # per-account amounts live on the chart labels).
        { income: income&.dig(:name) || "an income", item: item, amount: unit_aware_amount(over[:shortfall_month], income) }
      end
    end

    # (Fun Money v2): the fun_money config value shaping — only
    # per-paycheck figure (monthly / the income's occurrence count) in the
    # Per Paycheck view, the monthly figure otherwise. The per-paycheck
    # figure rounds through the same double the client renders (the
    # sankey's toFixed(2)), so the top bar and the chart labels agree to
    # the cent.
    def unit_aware_amount(monthly_amount, income)
      monthly = monthly_amount.to_d
      return monthly unless @view == "paycheck"

      occurrences = income&.dig(:occurrences)&.size
      return monthly if occurrences.nil? || occurrences.zero?

      # format("%.2f") rounds the exact binary double (C printf), which
      # matches the client's toFixed(2) on the SAME value — 2021.33/2
      # renders 1010.66 here and in the chart labels, where Ruby's
      # Float#round would print 1010.67 and desync the top bar by a cent.
      format("%.2f", (monthly / occurrences).to_f)
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

    # The plan-graph draft , same shape as the preview action's:
    # the selected income's saved edges replaced by the form's edge rows,
    # and the allocation rows merged per-id over the saved set. Only the
    # sets the form actually carries are present — the planner applies each
    # draft key wholesale over the saved inputs.
    def graph_draft
      draft = {}

      income = load_selected_income
      if income && params[:edges].present?
        # (Flow Scenarios): the form-preview edge base is the scenario's
        # snapshot edge rows when a scenario is active (the merge below
        # replaces only the selected income's edges); Default is the live
        # read.
        saved_edges = @scenario ? scenario_snapshot_allocations :
                                  PaycheckFlowPlanner.edge_rows(Current.family)
        rows = draft_edges(income).map do |account_id, attrs|
          {
            income_id: income.id,
            account_id: account_id,
            mode: attrs[:mode],
            value_cents: attrs[:mode] == "specific" ? (attrs[:value].to_d * 100).round : nil,
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
      # (Flow Scenarios): the per-id merge base is the scenario's
      # snapshot plan rows when a scenario is active; Default is the live
      # read. The merge itself is shape-agnostic (symbol-keyed base rows
      # either way).
      saved = @scenario ? scenario_snapshot_plan_allocations :
                          PaycheckFlowPlanner.plan_allocation_rows(Current.family)
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
            # the picker submits on every dialog save, so the
            # draft row carries the selection (blank = no category).
            category_id: attrs["category_id"].presence
          )
          # + : a draft bucket row (savings /
          # fun_money) keeps the user-chosen mode — the generic merge above
          # already shapes value_cents / value_percent to the mode, so the
          # in-place preview matches what a save persists, for every mode
          # (value validation stays model-owned). The bucket-specific drops
          # stay for the hidden controls: cadence ( owns bucket
          # cadence) and the detected-bill link (hidden for buckets) + the
          # gone auto-transfer flag.
          # (Plain if-guard: `expr if cond` returns nil when cond is false,
          # which would drop the row from the merge.)
          if %w[savings fun_money].include?(merged[:kind].to_s)
            merged = merged.merge(cadence: nil, recurring_transaction_id: nil,
              auto_transfer: false)
          end
          # (Fun Money v2): the fun_money row's config in the
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

    # The dialog row, shaped for persistence (issue 4;
    # U; ): kind "savings" / "fun_money" are buckets
    # funded from an associated account — and makes every mode
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
        # the Sure category whose color the diagram uses; blank
        # clears (nil). Survives the savings-bucket reshaping below — the
        # picker is visible for every kind.
        category_id: a[:category_id].presence,
        # the account the row dresses (the bank dialog's
        # "Make Allocated Sub-Account" popup sends the opened account's id;
        # the allocation dialog carries it in a hidden input so an edit
        # never silently unfreezes a dressed row). Blank = a plain row.
        # Existence + family membership are model-validated (422 contract).
        target_account_id: a[:target_account_id].presence
      }
      # buckets keep the user-chosen mode + value — the generic
      # shaping above already sets value_cents for required/specific and
      # value_percent for percent, exactly what the model wants for every
      # kind. Only the dialog's HIDDEN bucket controls are dropped here:
      # cadence ( owns bucket cadence), the detected-bill link
      # (hidden for buckets — a bucket is never a bill shape) and the gone
      # auto-transfer flag.
      if %w[savings fun_money].include?(row[:kind].to_s)
        row[:cadence] = nil
        row[:recurring_transaction_id] = nil
        row[:auto_transfer] = false
      end
      # (Fun Money v2): the fun_money row's configuration —
      # fun_money kind ONLY. For the other kinds the values are dropped
      # (nil) — a row edited from fun_money back to another kind clears its
      # config, and the non-fun_money dialog path is byte-identical to the
      # pre-fun-money one (the stop-rule property). The model's
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

      cents = (value.to_s.to_d * 100).round
      cents.zero? ? nil : cents
    end

    # (Fun Money v2): the fun_money config value shaping — only
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

    # (Fun Money v2): the per-member percents (distribution
    # "percent") the dialog submits as
    # plan_allocation[distribution_percents][<user_id>] — stored in
    # distribution_params["percents"] (jsonb, string values). Blank for
    # every other distribution (a change away from "percent" clears the
    # percents). The input snapshot
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

    # after a successful fun_money row save, persist the
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

    # (Fun Money v2): the RED Un-Allocated lines — one per
    # discrepancy strictly above the 100-cent tolerance, naming the income
    # ("an income" fallback) or the aggregate Household line.
    # Pre-resolved server-side from the graph (same pattern as
    # over_plan_lines); rendered as the second line group in
    # _chrome_top.erb (no new endpoint).
    def discrepancy_lines
      @discrepancy_lines ||= (@graph[:discrepancies] || []).map do |row|
        # unit-aware like the over-plan lines
        # (per-paycheck in the Per Paycheck view). The aggregate
        # Household line (income_id nil) has no single income to divide
        # by — it keeps its monthly figure in both views.
        income = row[:income_id] && @graph[:incomes].find { |i| i[:id] == row[:income_id] }
        { income: row[:income_name] || "an income", amount: unit_aware_amount(row[:un_allocated_month], income) }
      end
    end

    # Dialog percent (0-100, e.g. "10" = 10%) as a 0-1 fraction; blank or
    # zero -> nil.
    def parse_value_percent(value)
      return nil if value.blank?

      fraction = value.to_s.to_d / 100
      fraction.zero? ? nil : fraction
    end

    # Bank-config fields from the center card dialog: plan_role,
    # auto_transfer_to_account_id, the linked-income edges, and
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
      # the opened account becomes a
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
      # the logo picker (search + click-to-assign + clear). The
      # dialog's hidden input always submits the current value, so presence
      # = keep / assign, blank = clear. An unknown slug 422s through the
      # model validation (BankLogoSlugs.available — vendored files only).
      if account_params.key?("bank_logo_slug")
        account.update!(bank_logo_slug: account_params["bank_logo_slug"].presence)
      end
      # the checkbox submission order IS the band order —
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

    # pre-checks for a sub-account (parent) change, run BEFORE any
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
        reject_parent_change(account, "cannot become a sub-account while it has sub-accounts of its own")
      end
    end

    # keep the parent's fan-out in
    # sync with the opened account's sub-account (parent) change — the
    # SELECTED bank becomes the opened account's parent, so:
    # - link (new parent P present, P != OLD): P.auto_transfer_target_ids
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
            Array(old_parent.auto_transfer_target_ids) - [ account.id ]
          old_parent.save!
        end
      end

      # New parent: add this account to its fan-out (link / re-parent).
      if new_parent_id.present? && new_parent_id != old_parent_id
        parent = Current.family.accounts.find_by(id: new_parent_id)
        parent.auto_transfer_target_ids =
          (Array(parent.auto_transfer_target_ids) + [ account.id ]).uniq
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
        # the Leftover guardrail — one account per member's
        # paycheck may carry the leftover. If this save sets a leftover edge
        # for an income series that ALREADY has a leftover edge to a
        # DIFFERENT account, it would create a second leftover account for the
        # member -> 422. save_bank_links only touches the opened account's
        # edges, so a different-account leftover is never removed by this
        # save and the conflict is real. The UI greys the option (the disabled
        # per-row radio); this is the server backstop for a forced second
        # leftover (runs before any write — the transaction rolls back).
        links.each do |income_id, row|
          guard_row = row.respond_to?(:to_unsafe_h) ? row.to_unsafe_h : row
          next unless guard_row["enabled"].present?
          next unless guard_row["mode"].to_s == "leftover"
          series = income_series.find { |s| s.id == income_id }
          next unless series
          if Current.family.income_account_allocations
               .where(income_series_id: series.id, mode: "leftover")
               .where.not(account_id: account.id)
               .exists?
            record = IncomeAccountAllocation.new
            record.errors.add(:base,
              t("plan_flows.bank_config_dialog.leftover_conflict", name: series.name))
            raise ActiveRecord::RecordInvalid.new(record)
          end
        end

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
              # the stored percent of the bank's required
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
      # fix: the failing validation lives on the
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
