require "test_helper"

class PlanFlowsControllerTest < ActionDispatch::IntegrationTest
  # House pattern (bills_controller_test): session login + preview flag, and
  # the income/occurrence setup mirrors api/v1/paycheck_plans_controller_test
  # (dylan_family, family_admin/family_member, two November 2026 paychecks).
  teardown do
    travel_back
  end

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    @other = users(:family_member)
    @account = accounts(:depository)
    ensure_tailwind_build
  end

  def create_income_series(account:, name:, amount:)
    series = @family.recurring_transactions.create!(
      name: name,
      account: account,
      amount: amount,
      currency: "USD",
      expected_day_of_month: 6,
      last_occurrence_date: Date.new(2026, 9, 6),
      next_expected_date: Date.new(2026, 12, 20),
      status: "active",
      bill_type: "income",
      manual: true
    )
    series.recurring_occurrences.destroy_all
    [ Date.new(2026, 11, 6), Date.new(2026, 11, 20) ].each do |date|
      series.recurring_occurrences.create!(family: @family, due_on: date,
        original_due_on: date, currency: "USD", expected_amount: amount,
        status: "scheduled")
    end
    series
  end

  test "redirects users without preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get "/plan/flow"

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end

  # Clear every plan marker so the page is the empty state (rolled back with
  # the test transaction).
  def clear_plan_markers!
    @family.income_account_allocations.destroy_all
    @family.plan_allocations.destroy_all
    @family.accounts.update_all(plan_order: nil, plan_role: nil,
      auto_transfer_to_account_id: nil)
  end

  test "renders the planning diagram page with the sankey container and embedded names" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)

      get "/plan/flow"

      assert_response :success
      # The diagram container fetches the graph endpoint; the page embeds
      # only static names + in-plan membership.
      assert_select "div[data-controller=plan-flow-sankey]", 1 do
        assert_select "[data-plan-flow-sankey-graph-url-value='/plan/flow/graph']"
      end
      assert_includes response.body, "Bob Payroll"
      assert_includes response.body, @account.name
      # The old resolved panel and edge editor are gone.
      assert_select "turbo-frame#flow_resolved", count: 0
      assert_select "form[action='/plan/flow_save']", count: 0
      # The income node's config dialog is rendered for the declared series.
      assert_select "dialog[data-node-id='income:#{series.id}']", 1
      # Owner round 2 (F2): the column headers are buttons — Add Income goes
      # to the house incomes page, Add Account opens the existing-accounts
      # modal. No black column-header text on the page.
      assert_select "a[href='#{bills_path(view: 'paycheck')}']", text: /Add Income/
      assert_select "a[href='/plan/flow/add-accounts']", text: /Add Account/
    end
  end

  test "per-month view switches the diagram scale via a full reload" do
    travel_to Date.new(2026, 11, 15) do
      create_income_series(account: @account, name: "Bob Payroll", amount: 900)

      get "/plan/flow", params: { view: "monthly" }

      assert_response :success
      assert_select "div[data-controller=plan-flow-sankey][data-plan-flow-sankey-view-value=monthly]", 1
    end
  end

  test "an unknown income id renders without breaking the page" do
    travel_to Date.new(2026, 11, 15) do
      get "/plan/flow", params: { income: "not-a-uuid" }

      assert_response :success
      assert_select "div[data-controller=plan-flow-sankey]", 1
    end
  end

  test "the banks column empty state shows the unplanned count and the add-account link" do
    travel_to Date.new(2026, 11, 15) do
      clear_plan_markers!
      count = @family.accounts.count

      get "/plan/flow"

      assert_response :success
      assert_includes response.body, I18n.t("plan_flows.show.banks_not_planned", count: count)
      # The header button and the empty-state card both point at the modal
      # (round 2 F2).
      assert_select "a[href='/plan/flow/add-accounts']", min: 1
      # No bank dialogs: nothing is in the plan.
      assert_select "dialog[data-node-id^='bank:']", count: 0
    end
  end

  test "the allocations column empty state shows the add button without a recommended list" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")

      get "/plan/flow"

      assert_response :success
      assert_includes response.body, I18n.t("plan_flows.show.add_allocation")
      assert_select "button[data-action='plan-flow#openNewAllocation']", 1
      # Round 21 T2: the Recommended list was removed from the empty state
      # (owner decision); the header + Add Allocation button are the only
      # allocation access left in the empty column.
      assert_not_includes response.body, I18n.t("plan_flows.show.recommended")
      assert_select "button[data-action='plan-flow#openRecommended']", 0
      # The new-allocation dialog is rendered once.
      assert_select "dialog[data-node-id='allocation:new']", 1
    end
  end

  test "the over-plan overlay renders the red line server-side" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")
      PlanAllocation.create!(family: @family, account: @account, name: "Huge Bill",
        kind: "bill", mode: "required", value_cents: 250_000, cadence: "monthly")

      get "/plan/flow"

      assert_response :success
      # 1800 in, 2500 required -> 700 short on the income.
      assert_includes response.body, "Over-planned by $700.00 on Bob Payroll"
    end
  end

  test "the bank config dialog renders one row per income with all four modes" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "percent", value: 0.5)

      get "/plan/flow"

      assert_response :success
      assert_select "dialog[data-node-id='bank:#{@account.id}']", 1 do
        # The linked income is checked; the value input is enabled (percent).
        assert_select "input[name='links[#{series.id}][enabled]'][checked]"
        assert_select "select[name='links[#{series.id}][mode]'][disabled]", count: 0
        assert_select "select[name='links[#{series.id}][mode]'] option[value=required]"
        assert_select "select[name='links[#{series.id}][mode]'] option[value=specific]"
        assert_select "select[name='links[#{series.id}][mode]'] option[value=percent]"
        assert_select "select[name='links[#{series.id}][mode]'] option[value=leftover]"
        # Ownership / role / sub-account selects (round 11 issue 8: the
        # legacy single auto-transfer select is replaced by the
        # sub-account-of select + the multi-target fan-out checkboxes).
        assert_select "select[name='account[plan_ownership]']"
        assert_select "select[name='account[plan_role]'] option[value=savings_bucket]"
        assert_select "select[name='account[plan_role]'] option[value=credit_card_payoff]"
        assert_select "select[name='account[plan_role]'] option[value=loan_payoff]"
        # Round 20b: the sub-account select is unnamed (the kebab popup
        # syncs it into the form's hidden input, which is what submits).
        assert_select "input[type=hidden][name='account[parent_account_id]']"
        assert_select "select[name='account[parent_account_id]']"
        assert_select "input[type=hidden][name='account[auto_transfer_target_ids][]'][value='0']"
      end
    end
  end

  test "the income config dialog renders the owner select, the limit field, and the family-member link" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)

      get "/plan/flow"

      assert_response :success
      assert_select "dialog[data-node-id='income:#{series.id}']", 1 do
        assert_select "select[name='series[plan_owner_user_id]'] option[value='#{@other.id}']"
        assert_select "input[name='series[plan_max_account_links]']"
        assert_select "a[href='/settings/profile']"
      end
    end
  end

  test "the allocation dialogs render the bank source radios and the mode-dependent value input" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")
      row = PlanAllocation.create!(family: @family, account: @account, name: "Bills",
        kind: "bill", mode: "required", value_cents: 50_000, cadence: "monthly")

      get "/plan/flow"

      assert_response :success
      # New dialog (round 20 U): the Bank source stack is a radio list
      # (account name + plan-flow logo chip; a native select cannot show
      # the logo), and the value input is plan_allocation[value]
      # (required = monthly, deviation 1).
      assert_select "dialog[data-node-id='allocation:new']", 1 do
        assert_select "input[type=radio][name='plan_allocation[account_id]'][value='#{@account.id}']"
        assert_select "input[name='plan_allocation[value]']"
        assert_select "select[name='plan_allocation[mode]'] option[value=required][selected]"
      end
      # Owner round 2 (F3) + round 8: the new dialog opens on the Known
      # Allocations list — Sure's detected bills/subscriptions, MINUS the
      # ones already in the diagram (hidden, not flagged).
      netflix = recurring_transactions(:netflix_subscription)
      assert_select "dialog[data-node-id='allocation:new'] button[data-known-id='#{netflix.id}']", 1
      PlanAllocation.create!(family: @family, account: @account, name: "Netflix",
        kind: "bill", mode: "required", value_cents: 1_599, cadence: "monthly",
        recurring_transaction: netflix)
      get "/plan/flow"
      assert_response :success
      # Round 8: the planned bill no longer lists — and the empty list says
      # everything detected is already in the diagram (it was the only one).
      assert_select "dialog[data-node-id='allocation:new'] button[data-known-id='#{netflix.id}']", count: 0
      assert_select "dialog[data-node-id='allocation:new'] [data-plan-flow-target='knownSection']",
        text: /already in the diagram/
      # Edit dialog: prefill + the delete form.
      assert_select "dialog[data-node-id='allocation:#{row.id}']", 1 do
        assert_select "input[name='plan_allocation[name]'][value='Bills']"
        assert_select "input[name='plan_allocation[value]'][value='500.00']"
        assert_select "input[type=hidden][value='delete']"
      end
    end
  end

  test "the add-accounts modal lists unassigned accounts and links to the house manual page" do
    unassigned = @family.accounts.create!(name: "Unassigned Checking", owner: @user,
      currency: "USD", balance: 0, accountable: Depository.new)

    get "/plan/flow/add-accounts"

    assert_response :success
    assert_select "dialog"
    assert_select "form[action='/plan/flow_add_accounts'] input[type=checkbox][name='account_ids[]'][value='#{unassigned.id}']"
    # Owner round 2 (F2): the page keeps no manual-creation form of its own —
    # "Add Manual Account" links to the house add-account page.
    assert_select "form[action='/plan/flow_create_account']", count: 0
    assert_select "a[href='#{new_account_path}']", 1
  end

  test "add accounts assigns plan_order to the selected accounts" do
    a = @family.accounts.create!(name: "New A", owner: @user, currency: "USD",
      balance: 0, accountable: Depository.new)
    b = @family.accounts.create!(name: "New B", owner: @user, currency: "USD",
      balance: 0, accountable: Depository.new)
    base = @family.accounts.maximum(:plan_order).to_i

    post "/plan/flow_add_accounts", params: { account_ids: [ a.id, b.id ] }

    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal base + 1, a.reload.plan_order
    assert_equal base + 2, b.reload.plan_order
  end

  # Round 4 (ghost banks): the in-place (JSON) add ships the fresh graph —
  # which now renders the added plan-ordered banks — plus each new bank's
  # config dialog, so the node is operable without a reload.
  test "in-place add accounts responds with the graph and the new banks' dialogs" do
    a = @family.accounts.create!(name: "Ghost A", owner: @user, currency: "USD",
      balance: 0, accountable: Depository.new)
    b = @family.accounts.create!(name: "Ghost B", owner: @user, currency: "USD",
      balance: 0, accountable: Depository.new)
    base = @family.accounts.maximum(:plan_order).to_i

    # (xhr is unavailable in this app's test base; the Accept header is what
    # json_request? keys off.)
    post "/plan/flow_add_accounts", params: { account_ids: [ a.id, b.id ] },
         headers: { "Accept" => "application/json" }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal base + 1, a.reload.plan_order
    assert_equal base + 2, b.reload.plan_order
    bank_ids = body["graph"]["banks"].map { |bank| bank["id"] }
    assert_includes bank_ids, a.id
    assert_includes bank_ids, b.id
    ghost = body["graph"]["banks"].find { |bank| bank["id"] == a.id }
    assert_equal "0.00", ghost["inflow_month"]
    dialogs = body.dig("chrome", "bank_dialogs") || []
    dialog_a = dialogs.find { |entry| entry["node_id"] == "bank:#{a.id}" }
    assert dialog_a, "the added bank's config dialog ships with the in-place response"
    assert_includes dialog_a["html"], %(data-node-id="bank:#{a.id}")
  end

  # (create-account tests removed with the action — owner round 2, F2.)

  test "update account writes ownership from the combined dropdown" do
    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { plan_ownership: "user:#{@other.id}" }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal "user", @account.reload.plan_ownership
    assert_equal @other.id, @account.plan_owner_user_id

    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { plan_ownership: "shared" }
    }
    assert_equal "shared", @account.reload.plan_ownership
    assert_nil @account.plan_owner_user_id

    # A user outside the family falls back to shared/nil, not a 500.
    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { plan_ownership: "user:#{users(:empty).id}" }
    }
    assert_equal "shared", @account.reload.plan_ownership
    assert_nil @account.plan_owner_user_id
  end

  test "update income labels the series to a family member" do
    series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
    series.update!(plan_max_account_links: 5)

    patch "/plan/flow/incomes/#{series.id}", params: {
      series: { plan_owner_user_id: @other.id }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal @other.id, series.reload.plan_owner_user_id
    # Omitting the limit param keeps the existing value (no silent wipe).
    assert_equal 5, series.plan_max_account_links

    # Blank clears the label back to the account-owner fallback.
    patch "/plan/flow/incomes/#{series.id}", params: { series: { plan_owner_user_id: "" } }
    assert_nil series.reload.plan_owner_user_id
  end

  # --- planning diagram JSON + allocation CRUD + bank/income config ---

  test "graph returns the saved state as JSON" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")
      PlanAllocation.create!(family: @family, account: @account, name: "Bills",
        kind: "bill", mode: "required", value_cents: 50_000, cadence: "monthly")

      get "/plan/flow/graph", params: { income: series.id }

      assert_response :success
      json = JSON.parse(response.body)
      assert_equal 2, json["total_paychecks"]
      assert_equal %w[incomes banks allocations over_plans limit_warnings recommendations],
        %w[incomes banks allocations over_plans limit_warnings recommendations] & json.keys
      # Required value_cents is a MONTHLY figure prorated over the paychecks:
      # 500.00/month over 2 paychecks of 900.
      bills = json["allocations"].find { |a| a["name"] == "Bills" }
      assert_equal "500.00", bills["wanted_month"]
      assert_equal "500.00", bills["got_month"]
      assert_equal "250.00", bills["per_paycheck"].first["wanted"]
      assert_equal "ok", bills["status"]
      bank = json["banks"].find { |b| b["id"] == @account.id }
      assert_equal "1800.00", bank["inflow_month"]
      assert_equal "1300.00", bank["surplus_month"] # 1800 - 500
      assert_equal [], json["over_plans"]
      # netflix_subscription (15.99/mo) is not allocated yet -> recommended.
      assert json["recommendations"].any? { |r| r["type"] == "recurring_transaction" }
    end
  end

  # Owner round 2 (F4): the SAVED state must expose the exact per-allocation
  # shape the Sankey controller consumes — adding an allocation and reloading
  # (saved state, no draft params) used to crash the diagram. Every row
  # carries the full field set, per-paycheck included.
  test "graph saved state exposes the full allocation shape after a create" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")

      post "/plan/flow/allocations", params: {
        plan_allocation: { name: "Saved Bill", kind: "bill", mode: "required",
                           value: "100.00", cadence: "monthly",
                           account_id: @account.id }
      }

      get "/plan/flow/graph"

      assert_response :success
      json = JSON.parse(response.body)
      saved = json["allocations"].find { |a| a["name"] == "Saved Bill" }
      assert saved, "the created allocation must be in the saved-state graph"
      json["allocations"].each do |row|
        # The JS contract: every row has the full shape, no missing fields.
        %w[id name kind mode value_cents value_percent cadence recurring_transaction_id
           auto_transfer account_id per_paycheck wanted_month got_month shortfall_month
           status over_planned].each do |key|
          assert row.key?(key), "saved allocation row missing #{key}"
        end
        assert_kind_of Array, row["per_paycheck"]
        row["per_paycheck"].each do |step|
          assert row["per_paycheck"].all? { |s| s.key?("date") && s.key?("status") }
        end
      end
      assert_equal "100.00", saved["got_month"]
      assert_equal "0.00", saved["shortfall_month"]
      assert_equal "ok", saved["status"]
    end
  end

  test "graph merges draft edges and draft allocation rows over saved" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")
      savings = @family.accounts.create!(name: "Savings", owner: @user, currency: "USD",
        balance: 0, accountable: Depository.new)

      # Draft: the selected income's leftover edge is replaced by a 100/pk
      # specific edge to Savings; a new unsaved fun row joins the saved set.
      get "/plan/flow/graph", params: {
        income: series.id,
        edges: { savings.id.to_s => { "enabled" => "1", "mode" => "specific", "value" => "100" } },
        allocations: {
          "new-1" => { "name" => "Fun", "kind" => "fun_money", "mode" => "specific",
                       "value" => "300", "account_id" => @account.id }
        }
      }

      assert_response :success
      json = JSON.parse(response.body)
      # The draft edge replaced the saved leftover edge: only Savings
      # receives funds, @account starves, and the draft fun row is unfunded.
      savings_bank = json["banks"].find { |b| b["id"] == savings.id }
      assert_equal "200.00", savings_bank["inflow_month"] # 100 x 2 paychecks
      assert_equal "0.00", json["banks"].find { |b| b["id"] == @account.id }["inflow_month"]
      fun = json["allocations"].find { |a| a["id"] == "new-1" }
      assert_equal "Fun", fun["name"]
      assert_equal "600.00", fun["wanted_month"] # 300 x 2 paychecks
      assert_equal "0.00", fun["got_month"]
      assert_equal "over", fun["status"]
    end
  end

  test "create allocation upserts by bank and name" do
    post "/plan/flow/allocations", params: {
      plan_allocation: { account_id: @account.id, name: "Netflix", kind: "bill",
                         mode: "specific", value: "15.99", cadence: "monthly" }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal I18n.t("plan_flows.create_allocation.saved"), flash[:notice]
    row = @family.plan_allocations.find_by(name: "Netflix")
    assert row, "the allocation was not created"
    assert_equal 1599, row.value_cents.to_i

    # Re-saving the same bank + name edits the row instead of duplicating it.
    post "/plan/flow/allocations", params: {
      plan_allocation: { account_id: @account.id, name: "Netflix", kind: "bill",
                         mode: "specific", value: "20.00" }
    }
    assert_equal 1, @family.plan_allocations.count
    assert_equal 2000, row.reload.value_cents.to_i
  end

  test "create allocation flashes the house alert on invalid values" do
    post "/plan/flow/allocations", params: {
      plan_allocation: { account_id: @account.id, name: "Mystery", kind: "bill", mode: "specific" }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal I18n.t("plan_flows.create_allocation.save_failed"), flash[:alert]
    assert_nil @family.plan_allocations.find_by(name: "Mystery")
  end

  test "update and destroy allocation rows" do
    row = PlanAllocation.create!(family: @family, account: @account, name: "Bills",
      kind: "bill", mode: "required", value_cents: 50_000)

    patch "/plan/flow/allocations/#{row.id}", params: {
      plan_allocation: { account_id: @account.id, name: "Bills", kind: "bill",
                         mode: "specific", value: "40.00" }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal I18n.t("plan_flows.update_allocation.saved"), flash[:notice]
    assert_equal "specific", row.reload.mode
    assert_equal 4000, row.value_cents.to_i

    # Invalid edit flashes and keeps the previous state.
    patch "/plan/flow/allocations/#{row.id}", params: {
      plan_allocation: { account_id: @account.id, name: "Bills", kind: "bill", mode: "percent" }
    }
    assert_equal I18n.t("plan_flows.update_allocation.save_failed"), flash[:alert]
    assert_equal "specific", row.reload.mode

    delete "/plan/flow/allocations/#{row.id}"
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal I18n.t("plan_flows.destroy_allocation.saved"), flash[:notice]
    assert_nil @family.plan_allocations.find_by(id: row.id)
  end

  # --- Round 10 issue 4 + round 20 U: the savings bucket (kind "savings") ---
  # The dialog shows the bucket's associated-account hint (the existing
  # account_id field, now the Bank source radio list) and "How much to save
  # Per Month" (the existing value field, mode forced "required" = monthly);
  # the bill-only fields (mode / cadence / detected-bill link) are hidden
  # (auto-transfer is gone, round 20 U) — and hidden fields still submit,
  # so the controller sanitizes a stale submit into the clean monthly shape.
  # --- Round 10 issue 4: the savings bucket (kind "savings") ----------------
  # The dialog shows "Which Account is this Savings Bucket Associated to"
  # (the existing account_id select) and "How much to save Per Month" (the
  # existing value field, mode forced "required" = monthly); the bill-only
  # fields (mode / cadence / detected-bill link / auto transfer) are hidden —
  # and hidden fields still submit, so the controller sanitizes a stale
  # submit into the clean monthly shape.

  test "the savings bucket dialog hides the bill fields and shows the bucket labels" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")
      bucket = PlanAllocation.create!(family: @family, account: @account,
        name: "Pet Safety Fund", kind: "savings", mode: "required", value_cents: 25_000)

      get "/plan/flow"

      assert_response :success
      # Edit dialog: the three bill-only blocks (mode / cadence / detected
      # bill link) render hidden for the bucket kind, and the amount input
      # + the bank-source hint wear the bucket labels.
      assert_select "dialog[data-node-id='allocation:#{bucket.id}']", 1 do
        assert_select "input[name='plan_allocation[name]'][value='Pet Safety Fund']"
        assert_select "div[data-allocation-kinds].hidden", count: 3
        assert_select "div[data-allocation-kinds].hidden select[name='plan_allocation[mode]']"
        assert_select "div[data-allocation-kinds].hidden select[name='plan_allocation[cadence]']"
        assert_select "div[data-allocation-kinds].hidden select[name='plan_allocation[recurring_transaction_id]']"
        assert_select "input[name='plan_allocation[auto_transfer]']", count: 0
        assert_select "label[for$='allocation_value']", text: I18n.t("plan_flows.allocation_dialog.savings_value_label")
        assert_select "p[data-allocation-kind-hint='account']", text: I18n.t("plan_flows.allocation_dialog.savings_account_hint")
      # Edit dialog: the four bill-only blocks (mode / cadence / detected
      # bill link / auto transfer) render hidden, and the account select +
      # amount input wear the bucket labels.
        assert_select "div[data-allocation-bill-only].hidden", count: 4
        assert_select "div[data-allocation-bill-only].hidden select[name='plan_allocation[mode]']"
        assert_select "div[data-allocation-bill-only].hidden select[name='plan_allocation[cadence]']"
        assert_select "div[data-allocation-bill-only].hidden select[name='plan_allocation[recurring_transaction_id]']"
        assert_select "div[data-allocation-bill-only].hidden input[name='plan_allocation[auto_transfer]']"
        assert_select "label[for$='allocation_value']", text: I18n.t("plan_flows.allocation_dialog.savings_value_label")
        assert_select "p[data-allocation-kind-hint='account']", text: I18n.t("plan_flows.allocation_dialog.savings_account_hint")
        assert_select "input[name='plan_allocation[value]'][value='250.00']"
      end
      # New dialog (kind defaults to bill): the bill fields stay visible and
      # the bill labels show — the bucket view is kind-specific.
      assert_select "dialog[data-node-id='allocation:new']", 1 do
        assert_select "div[data-allocation-kinds].hidden", count: 0
        assert_select "label[for$='allocation_value']", text: I18n.t("plan_flows.allocation_dialog.value_label")
        assert_select "p[data-allocation-kind-hint='account']", text: I18n.t("plan_flows.allocation_dialog.source_bank_hint")
        assert_select "div[data-allocation-bill-only].hidden", count: 0
        assert_select "label", text: I18n.t("plan_flows.allocation_dialog.value_label")
        assert_select "label", text: I18n.t("plan_flows.allocation_dialog.source_bank_label")
      end
    end
  end

  test "create a savings bucket sanitizes the stale hidden fields" do
    netflix = recurring_transactions(:netflix_subscription)
    post "/plan/flow/allocations", params: {
      plan_allocation: { account_id: @account.id, name: "Pet Safety Fund",
                         kind: "savings", mode: "percent", value_percent: "5",
                         value: "250.00", cadence: "monthly",
                         recurring_transaction_id: netflix.id,
                         auto_transfer: "1" }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal I18n.t("plan_flows.create_allocation.saved"), flash[:notice]
    row = @family.plan_allocations.find_by(name: "Pet Safety Fund")
    assert row, "the bucket was not created"
    assert_equal "savings", row.kind
    assert_equal "required", row.mode
    assert_equal 25_000, row.value_cents.to_i
    assert_nil row.value_percent
    assert_nil row.cadence
    assert_nil row.recurring_transaction_id
    assert_equal false, row.auto_transfer
    assert_equal @account.id, row.account_id
  end

  test "update a savings bucket re-sanitizes the stale hidden fields" do
    row = PlanAllocation.create!(family: @family, account: @account, name: "Pet Safety Fund",
      kind: "savings", mode: "required", value_cents: 25_000)

    patch "/plan/flow/allocations/#{row.id}", params: {
      plan_allocation: { account_id: @account.id, name: "Pet Safety Fund",
                         kind: "savings", mode: "percent", value_percent: "5",
                         value: "300.00", cadence: "monthly", auto_transfer: "1" }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal I18n.t("plan_flows.update_allocation.saved"), flash[:notice]
    assert_equal "savings", row.reload.kind
    assert_equal "required", row.mode
    assert_equal 30_000, row.value_cents.to_i
    assert_nil row.value_percent
    assert_nil row.cadence
    assert_equal false, row.auto_transfer
  end

  test "graph resolves the savings bucket from its associated bank" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")
      bucket_bank = @family.accounts.create!(name: "Pet Safety Bank", owner: @user,
        currency: "USD", balance: 0, accountable: Depository.new)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: bucket_bank, mode: "specific", value: 250)
      PlanAllocation.create!(family: @family, account: bucket_bank,
        name: "Pet Safety Fund", kind: "savings", mode: "required", value_cents: 25_000)

      get "/plan/flow/graph", params: { income: series.id }

      assert_response :success
      json = JSON.parse(response.body)
      saved = json["allocations"].find { |a| a["name"] == "Pet Safety Fund" }
      assert saved, "the bucket must be in the saved-state graph"
      assert_equal "savings", saved["kind"]
      assert_equal "required", saved["mode"]
      assert_equal bucket_bank.id, saved["account_id"]
      # Monthly figure fully funded by the 250/month bank: 250.00 in, 250.00
      # wanted, no shortfall — resolved exactly like a required bill.
      assert_equal "250.00", saved["wanted_month"]
      assert_equal "250.00", saved["got_month"]
      assert_equal "0.00", saved["shortfall_month"]
      assert_equal "ok", saved["status"]
    end
  end

  test "graph draft previews a savings row as the sanitized monthly shape" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")
      bucket_bank = @family.accounts.create!(name: "Pet Safety Bank", owner: @user,
        currency: "USD", balance: 0, accountable: Depository.new)

      # A stale draft submit (percent mode, no funding): the preview normalizes
      # it to the monthly required shape; the unfunded bucket shows shortfall.
      get "/plan/flow/graph", params: {
        income: series.id,
        allocations: {
          "new-bucket" => { "name" => "Pet Safety Fund", "kind" => "savings",
                            "mode" => "percent", "value_percent" => "5",
                            "value" => "250", "account_id" => bucket_bank.id }
        }
      }

      assert_response :success
      json = JSON.parse(response.body)
      saved = json["allocations"].find { |a| a["id"] == "new-bucket" }
      assert saved, "the draft bucket must be in the preview graph"
      assert_equal "savings", saved["kind"]
      assert_equal "required", saved["mode"]
      assert_equal "250.00", saved["wanted_month"]
      assert_equal "0.00", saved["got_month"] # no funding edge -> unfunded
      assert_equal "over", saved["status"]
    end
  end

  test "update account writes plan_role and the auto-transfer link" do
    savings = @family.accounts.create!(name: "Savings", owner: @user, currency: "USD",
      balance: 0, accountable: Depository.new)

    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { plan_ownership: "shared", plan_role: "savings_bucket",
                 auto_transfer_to_account_id: savings.id }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal "savings_bucket", @account.reload.plan_role
    assert_equal savings.id, @account.auto_transfer_to_account_id

    # Blank values clear both fields.
    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { plan_ownership: "shared", plan_role: "", auto_transfer_to_account_id: "" }
    }
    assert_nil @account.reload.plan_role
    assert_nil @account.auto_transfer_to_account_id
  end

  test "update account upserts the linked-income edges from the links param" do
    series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
    savings = @family.accounts.create!(name: "Savings", owner: @user, currency: "USD",
      balance: 0, accountable: Depository.new)
    IncomeAccountAllocation.create!(family: @family, income_series: series,
      account: @account, mode: "percent", value: 0.5)
    IncomeAccountAllocation.create!(family: @family, income_series: series,
      account: savings, mode: "specific", value: 100)

    # Both incomes checked on @account: the percent edge is replaced by leftover.
    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { plan_ownership: "shared" },
      links: { series.id.to_s => { "enabled" => "1", "mode" => "leftover" } }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    edge = IncomeAccountAllocation.where(income_series: series, account: @account).first
    assert_equal "leftover", edge.mode
    assert_nil edge.value
    # The other account's edge is untouched.
    assert IncomeAccountAllocation.exists?(income_series: series, account: savings)

    # Unchecked: the edge is removed.
    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { plan_ownership: "shared" },
      links: { series.id.to_s => { "enabled" => "", "mode" => "leftover" } }
    }
    assert_not IncomeAccountAllocation.exists?(income_series: series, account: @account)
    assert IncomeAccountAllocation.exists?(income_series: series, account: savings)
  end

  test "update income writes the bank-link limit and flashes on an invalid one" do
    series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)

    patch "/plan/flow/incomes/#{series.id}", params: {
      series: { plan_owner_user_id: "", plan_max_account_links: "3" }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal 3, series.reload.plan_max_account_links

    # 0 violates the >= 1 check: alert flash, value unchanged.
    patch "/plan/flow/incomes/#{series.id}", params: {
      series: { plan_owner_user_id: "", plan_max_account_links: "0" }
    }
    assert_equal I18n.t("plan_flows.update_income.save_failed"), flash[:alert]
    assert_equal 3, series.reload.plan_max_account_links

    # Blank clears the limit.
    patch "/plan/flow/incomes/#{series.id}", params: {
      series: { plan_owner_user_id: "", plan_max_account_links: "" }
    }
    assert_nil series.reload.plan_max_account_links
  end

  # --- Owner review round 3: R1 (in-place JSON responses) + R3 (bank removal) ---

  # R1: the delete path is what broke the diagram (add worked since round 2).
  # The in-place fetch expects the fresh saved-state graph back as JSON — the
  # diagram re-renders from it with NO navigation, so the response must be a
  # well-formed saved-state graph with every remaining row in the full shape.
  test "destroy allocation responds with the fresh saved-state graph JSON in place" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")
      PlanAllocation.create!(family: @family, account: @account, name: "Keep Bill",
        kind: "bill", mode: "required", value_cents: 30_000, cadence: "monthly")
      gone = PlanAllocation.create!(family: @family, account: @account, name: "Gone Bill",
        kind: "bill", mode: "required", value_cents: 20_000, cadence: "monthly")

      delete "/plan/flow/allocations/#{gone.id}", headers: { "Accept" => "application/json" }

      assert_response :success
      assert_equal "application/json", response.media_type
      json = JSON.parse(response.body)
      assert json.key?("graph"), "the in-place response must carry the fresh graph"
      names = json["graph"]["allocations"].map { |a| a["name"] }
      assert_includes names, "Keep Bill"
      refute_includes names, "Gone Bill"
      # Every surviving row keeps the 14-key shape the Sankey consumes.
      json["graph"]["allocations"].each do |row|
        %w[id name kind mode value_cents value_percent cadence recurring_transaction_id
           auto_transfer account_id per_paycheck wanted_month got_month shortfall_month
           status over_planned].each do |key|
          assert row.key?(key), "post-destroy allocation row missing #{key}"
        end
        assert_kind_of Array, row["per_paycheck"]
      end
      assert_nil @family.plan_allocations.find_by(id: gone.id)
    end
  end

  # R1: create + update share the same in-place contract.
  test "create and update allocation respond with graph JSON in place" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")

      post "/plan/flow/allocations", headers: { "Accept" => "application/json" }, params: {
        plan_allocation: { account_id: @account.id, name: "In Place", kind: "bill",
                           mode: "required", value: "100.00", cadence: "monthly" }
      }
      assert_response :success
      created = JSON.parse(response.body)
      assert created["graph"]["allocations"].any? { |a| a["name"] == "In Place" }

      row = @family.plan_allocations.find_by(name: "In Place")
      patch "/plan/flow/allocations/#{row.id}", headers: { "Accept" => "application/json" }, params: {
        plan_allocation: { account_id: @account.id, name: "In Place", kind: "bill",
                           mode: "required", value: "120.00", cadence: "monthly" }
      }
      assert_response :success
      updated = JSON.parse(response.body)
      assert_equal "120.00",
        updated["graph"]["allocations"].find { |a| a["name"] == "In Place" }["wanted_month"]

      # A 422 carries the field errors the dialog renders inline.
      patch "/plan/flow/allocations/#{row.id}", headers: { "Accept" => "application/json" }, params: {
        plan_allocation: { account_id: @account.id, name: "", kind: "bill", mode: "required" }
      }
      assert_response :unprocessable_entity
      errors = JSON.parse(response.body)["errors"]
      assert errors.is_a?(Hash), "422 must be the model's field errors, not a string"
    end
  end

  # Round 8: creating an allocation that links a detected bill drops that
  # bill from the in-place Known Allocations chrome — the dialog offers only
  # what isn't already in the diagram, without a reload.
  test "create allocation linked to a known bill drops it from the in-place known list" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")
      netflix = recurring_transactions(:netflix_subscription)

      # Before: the bill lists in the dialog's Known Allocations.
      get "/plan/flow"
      assert_select "dialog[data-node-id='allocation:new'] button[data-known-id='#{netflix.id}']", 1

      post "/plan/flow/allocations", headers: { "Accept" => "application/json" }, params: {
        plan_allocation: { account_id: @account.id, name: "Netflix", kind: "bill",
                           mode: "required", value: "15.99", cadence: "monthly",
                           recurring_transaction_id: netflix.id }
      }
      assert_response :success
      json = JSON.parse(response.body)
      assert json.key?("graph"), "the in-place response must carry the fresh graph"
      known_html = json["chrome"]["known"]
      assert known_html, "an allocation change must ship the refreshed known list"
      refute known_html.include?("data-known-id=\"#{netflix.id}\""),
        "the planned bill must drop out of the known list"
      assert known_html.include?("already in the diagram"),
        "the emptied list must say everything detected is in the diagram"
    end
  end

  # R3: removing a bank keeps its allocations alive — they persist without a
  # source bank (status "unassigned"), the edges and plan markers are dropped,
  # and the re-assignment path (the allocation dialog) works again.
  test "remove bank from the plan unassigns allocations and drops edges" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "percent", value: 0.5)
      row = PlanAllocation.create!(family: @family, account: @account, name: "Bills",
        kind: "bill", mode: "required", value_cents: 50_000, cadence: "monthly")
      @account.update!(plan_order: 1, plan_role: "savings_bucket")

      # The in-place fetch: 200 + the fresh graph.
      delete "/plan/flow/accounts/#{@account.id}", headers: { "Accept" => "application/json" }
      assert_response :success
      json = JSON.parse(response.body)
      assert json.key?("graph")

      account = @account.reload
      assert_nil account.plan_order
      assert_nil account.plan_role
      assert_not IncomeAccountAllocation.exists?(income_series: series, account: @account)
      # The allocation survived, now unassigned.
      assert_nil row.reload.account_id

      unassigned = json["graph"]["allocations"].find { |a| a["name"] == "Bills" }
      assert unassigned, "the unassigned allocation must still be in the graph"
      assert_equal "unassigned", unassigned["status"]
      assert_nil unassigned["account_id"]
      assert_equal [], unassigned["per_paycheck"]
      assert_equal "0.00", unassigned["wanted_month"]
      assert_equal "0.00", unassigned["got_month"]
      # Unassigned rows name no bank.
      refute_includes json["graph"]["banks"].map { |b| b["id"] }, @account.id

      # Re-assignment via the allocation dialog works again.
      patch "/plan/flow/allocations/#{row.id}", params: {
        plan_allocation: { account_id: @account.id, name: "Bills", kind: "bill",
                           mode: "required", value: "500.00", cadence: "monthly" }
      }
      assert_redirected_to "/plan/flow?view=paycheck"
      assert_equal @account.id, row.reload.account_id
    end
  end

  # R3: removing a bank without allocations is the plain edge/marker drop.
  test "remove bank without allocations redirects with the removed notice" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")
      @account.update!(plan_order: 2, plan_role: "loan_payoff")

      delete "/plan/flow/accounts/#{@account.id}"

      assert_redirected_to "/plan/flow?view=paycheck"
      assert_equal I18n.t("plan_flows.remove_account.removed"), flash[:notice]
      assert_not IncomeAccountAllocation.exists?(account: @account)
      account = @account.reload
      assert_nil account.plan_order
      assert_nil account.plan_role
    end
  end

  # Round 7 (owner: deleting a bank left a blank "Account" row that survived
  # reloads): an unassigned allocation's nil account_id used to leak into the
  # in-plan list, and the Sankey synthesizes a floor node for every in-plan
  # id it does not see in the graph. Both sides must stay nil-free / fresh.
  test "remove bank leaves no phantom row in the in-plan list" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")
      row = PlanAllocation.create!(family: @family, account: @account, name: "Bills",
        kind: "bill", mode: "required", value_cents: 50_000, cadence: "monthly")
      @account.update!(plan_order: 1)

      # (a) In-place JSON: the removed bank leaves the graph AND the response
      # refreshes the Sankey's in-plan value nil-free, so the client never
      # re-synthesizes the removed bank as a phantom floor node.
      delete "/plan/flow/accounts/#{@account.id}", headers: { "Accept" => "application/json" }
      assert_response :success
      json = JSON.parse(response.body)
      assert_equal "bank:#{@account.id}", json["chrome"]["bank_removed"]
      refute_includes json["graph"]["banks"].map { |b| b["id"] }, @account.id

      sankey = json["chrome"]["sankey"]
      assert sankey, "the response must refresh the sankey's in-plan state"
      assert_not_includes sankey["in_plan"], @account.id
      assert_not_includes sankey["in_plan"], nil
      assert sankey["accounts"].is_a?(Hash)

      # (b) A full page render afterwards: the embedded in-plan value is
      # nil-free — the unassigned allocation must not leak a null id into
      # the list the Sankey synthesizes floor nodes from.
      get "/plan/flow?view=paycheck"
      assert_response :success
      attr = response.body[/data-plan-flow-sankey-in-plan-value="([^"]*)"/, 1]
      assert attr, "the sankey in-plan value must be embedded in the page"
      in_plan = JSON.parse(URI.decode_www_form_component(attr))
      assert_not_includes in_plan, nil
      assert_not_includes in_plan, @account.id
    end
  end

  # Round 11 issue 8 (sub-accounts + fan-out, backend): the bank config
  # dialog persists the sub-account link and the ordered fan-out targets,
  # rejects invalid links with the 422 inline-error contract, clears both
  # when the bank leaves the plan, and the graph payload bank rows carry
  # the new keys. (Planner fan-out math is covered in
  # paycheck_flow_planner_graph_test.)
  def create_vault(name)
    @family.accounts.create!(name: name, balance: 0, currency: "USD",
                             accountable: Depository.new)
  end

  test "update account persists the sub-account link and fan-out targets in checkbox order" do
    child = create_vault("Baby Vault")
    other_child = create_vault("Pet Vault")

    # Both children link to the bank (the strict rule: targets must be
    # sub-accounts of the source).
    patch "/plan/flow/accounts/#{child.id}", params: {
      account: { parent_account_id: @account.id }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal @account.id, child.reload.parent_account_id

    patch "/plan/flow/accounts/#{other_child.id}", params: {
      account: { parent_account_id: @account.id }
    }
    assert_equal @account.id, other_child.reload.parent_account_id

    # The checkbox submission order IS the band order: the array is stored
    # as submitted, never re-sorted.
    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { auto_transfer_target_ids: [ other_child.id.to_s, child.id.to_s ] }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal [ other_child.id.to_s, child.id.to_s ], @account.reload.auto_transfer_target_ids

    # An all-unchecked checkbox set posts the hidden "0" sentinel plus the
    # checked ids: the sentinel is dropped, the order survives.
    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { auto_transfer_target_ids: [ "0", child.id.to_s ] }
    }
    assert_equal [ child.id.to_s ], @account.reload.auto_transfer_target_ids
  end

  test "update account rejects a non-sub-account fan-out target and a depth-2 parent with 422 inline errors" do
    stranger = create_vault("Stranger Vault")

    # Q1 strict rule: the source only fans out to its own sub-accounts.
    patch "/plan/flow/accounts/#{@account.id}", headers: { "Accept" => "application/json" }, params: {
      account: { auto_transfer_target_ids: [ stranger.id.to_s ] }
    }
    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes (json["errors"]["auto_transfer_target_ids"] || []),
      "must be sub-accounts of this account"
    assert_nil @account.reload.auto_transfer_target_ids.presence

    # Depth 2: the candidate parent is already a sub-account.
    inner = create_vault("Inner Vault")
    outer = create_vault("Outer Vault")
    inner.update!(parent_account_id: outer.id)

    patch "/plan/flow/accounts/#{@account.id}", headers: { "Accept" => "application/json" }, params: {
      account: { parent_account_id: inner.id.to_s }
    }
    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert json["errors"]["parent_account"].any? { |m| m.include?("depth-1 only") }
    assert_nil @account.reload.parent_account_id
  end

  test "remove account clears the sub-account link and the fan-out targets" do
    child = create_vault("Baby Vault")
    child.update!(parent_account_id: @account.id)
    @account.update!(auto_transfer_target_ids: [ child.id.to_s ], plan_order: 1)

    delete "/plan/flow/accounts/#{@account.id}", headers: { "Accept" => "application/json" }
    assert_response :success

    account = @account.reload
    assert_nil account.parent_account_id
    assert_equal [], account.auto_transfer_target_ids
  end

  test "graph payload bank rows carry the sub-account and fan-out keys and the fan-out resolves" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "required")
      PlanAllocation.create!(family: @family, account: @account, name: "Bills",
        kind: "bill", mode: "required", value_cents: 40_000, cadence: "monthly")
      @account.update!(plan_order: 1)

      child = create_vault("Baby Vault")
      child.update!(parent_account_id: @account.id)
      @account.update!(auto_transfer_target_ids: [ child.id.to_s ])
      PlanAllocation.create!(family: @family, account: child, name: "Baby Savings",
        kind: "savings", mode: "required", value_cents: 10_000, cadence: "monthly")

      get "/plan/flow/graph", params: { income: series.id }
      assert_response :success
      # The endpoint renders the graph payload directly (no wrapper).
      graph = JSON.parse(response.body)

      bank = graph["banks"].find { |b| b["id"] == @account.id }
      child_bank = graph["banks"].find { |b| b["id"] == child.id }
      %w[parent_account_id sub_account auto_transfer_target_ids
         auto_transfer_to_account_id].each do |key|
        assert bank.key?(key), "bank row missing the #{key} key"
        assert child_bank.key?(key), "child bank row missing the #{key} key"
      end
      assert_equal false, bank["sub_account"]
      assert_nil bank["parent_account_id"]
      assert_equal [ child.id ], bank["auto_transfer_target_ids"]
      assert_equal true, child_bank["sub_account"]
      assert_equal @account.id, child_bank["parent_account_id"]

      # The fan-out end to end: the bank's per-paycheck reservation counts
      # the child's base once ((400 + 100) / 2 = 250) and the child's
      # bucket is fully funded from its share of the pool.
      assert_equal "500.00", bank["inflow_month"]
      bucket = graph["allocations"].find { |a| a["name"] == "Baby Savings" }
      assert_equal "100.00", bucket["got_month"]
      assert_equal "0.00", bucket["shortfall_month"]
      assert_equal "ok", bucket["status"]
    end
  end

  # Round 16 (owner note 3b): the logo picker's hidden input saves through the
  # existing PATCH flow_account action (account[bank_logo_slug]). Presence
  # assigns, blank clears, an unknown slug 422s inline.
  test "update account sets the bank logo slug and clears it with a blank value" do
    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { bank_logo_slug: "sofi" }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal "sofi", @account.reload.bank_logo_slug

    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { bank_logo_slug: "" }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_nil @account.reload.bank_logo_slug
  end

  test "update account rejects an unknown bank logo slug with 422 inline errors" do
    patch "/plan/flow/accounts/#{@account.id}", headers: { "Accept" => "application/json" }, params: {
      account: { bank_logo_slug: "not-a-real-bank" }
    }
    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes (json["errors"]["bank_logo_slug"] || []), "is not a known bank logo"
    assert_nil @account.reload.bank_logo_slug
  end

  # Round 16 (owner note 2): the allocation dialog saves a category through
  # the existing allocation actions (plan_allocation[category_id]); the graph
  # payload's allocation rows carry the category name + color (nil when none).
  test "allocation save persists the category and the graph rows carry the category color" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      category = @family.categories.create!(name: "Groceries", color: "#11AA22")

      post "/plan/flow/allocations", params: {
        plan_allocation: { name: "Groceries Bill", kind: "bill", mode: "specific",
                           value: "100.00", account_id: @account.id,
                           category_id: category.id }
      }
      assert_redirected_to "/plan/flow?view=paycheck"
      allocation = @family.plan_allocations.find_by!(name: "Groceries Bill")
      assert_equal category.id, allocation.category_id

      # A second allocation with no category.
      post "/plan/flow/allocations", params: {
        plan_allocation: { name: "No Category", kind: "bill", mode: "specific",
                           value: "50.00", account_id: @account.id }
      }
      no_cat = @family.plan_allocations.find_by!(name: "No Category")
      assert_nil no_cat.category_id

      get "/plan/flow/graph", params: { income: series.id }
      assert_response :success
      graph = JSON.parse(response.body)

      grocery = graph["allocations"].find { |a| a["name"] == "Groceries Bill" }
      assert_equal "Groceries", grocery["category_name"]
      assert_equal "#11AA22", grocery["category_color"]

      none = graph["allocations"].find { |a| a["name"] == "No Category" }
      assert_nil none["category_name"]
      assert_nil none["category_color"]
    end
  end

  # Round 16 (owner note 2 + 3b): the dialogs render the new fields — the
  # allocation dialog's category picker (round 20 U: a radio list with the
  # same color + icon chip the house category lists use, because a native
  # select cannot render the icon + color) and the bank dialog's logo
  # picker (hidden slug input + the vendored logo list), J's existing
  # fields intact.
  test "dialogs render the category picker and the logo picker" do
  # allocation dialog's category select and the bank dialog's logo picker
  # (hidden slug input + the vendored logo list), J's existing fields intact.
  test "dialogs render the category select and the logo picker" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "required")
      allocation = PlanAllocation.create!(family: @family, account: @account, name: "Bills",
        kind: "bill", mode: "required", value_cents: 40_000, cadence: "monthly")
      @account.update!(plan_order: 1)
      category = @family.categories.create!(name: "Groceries", color: "#11AA22")

      get "/plan/flow"
      assert_response :success

      # Bank config dialog (round 20d): the top-left avatar + logo popup
      # replaced the old search/list section; the hidden slug input and the
      # fan-out fields stay intact.
      assert_select "dialog[data-node-id='bank:#{@account.id}']", 1 do
        assert_select "[data-bank-config-dialog-target=avatar]", 1
        assert_select "[data-bank-config-dialog-target=avatarImg]", 1
        assert_select "[data-bank-config-dialog-target=avatarPencil]", 1
        assert_select "[data-bank-config-dialog-target=logoPopup] [data-bank-config-dialog-target=fileInput][accept='image/*']", 1
        assert_select "[data-bank-config-dialog-target=logoPopup] button[data-slug=sofi]", 1
        assert_select "input[name='account[bank_logo_slug]'][type=hidden]", 1
        assert_select "input[type=hidden][name='account[parent_account_id]']", 1
        assert_select "input[type=hidden][name='account[auto_transfer_target_ids][]'][value='0']", 1
      end

      # Allocation dialog (edit mode, round 20 U): the category picker is a
      # radio list carrying the family's categories, each with the same
      # color-mix icon chip the house category lists use.
      assert_select "dialog[data-node-id='allocation:#{allocation.id}']", 1 do
        assert_select "input[type=radio][name='plan_allocation[category_id]'][value='']", 1
        assert_select "input[type=radio][name='plan_allocation[category_id]'][value='#{category.id}']", 1
        assert_select "span[style*='#{category.color}']", 1
      end
    end
  end

  # ---------------------------------------------------------------------
  # Round 20 (T): the save bug + the progressive-disclosure rework.
  # Controller round-trips for uncheck / sub-account / fan-out pre-date this
  # round (edge-editor era, above); these pin the NEW dialog markup, the
  # five-value role enum, and the custom-logo upload/remove endpoints.
  # ---------------------------------------------------------------------

  test "bank dialog renders the uncheck sentinel, kebab popups, and the five roles" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "required")

      get "/plan/flow"
      assert_response :success

      assert_select "dialog[data-node-id='bank:#{@account.id}']", 1 do
        # Round 20 save-bug fix: an unchecked browser checkbox sends NO
        # param, so the hidden empty sentinel (before the checkbox) is what
        # makes the controller see the row and destroy the edge.
        assert_select "input[type=hidden][name='links[#{series.id}][enabled]'][value='']", 1
        # Progressive disclosure: the rule select sits inside the row's
        # details wrapper (visible because this row is checked).
        assert_select "[data-bank-row-details] select[name='links[#{series.id}][mode]']", 1
        # Round 20b: the kebab + the sub-account popup (the select is
        # unnamed; it syncs into the form's hidden input).
        assert_select "[data-bank-config-dialog-target=kebabMenu]", 1
        assert_select "[data-bank-config-dialog-target=subAccountPopup] [data-bank-config-dialog-target=subAccountSelect]", 1
        assert_select "[data-bank-config-dialog-target=subAccountSelect] option[value='']", 1
        # Round 20e: the auto-transfer popup with the checkbox box.
        assert_select "[data-bank-config-dialog-target=autoTransferPopup] [data-bank-config-dialog-target=autoTransferBox]", 1
        # Round 20c: exactly the five roles (plus the disabled Plain
        # placeholder while the role is nil).
        assert_select "select[name='account[plan_role]'] option[value=savings_bucket]", 1
        assert_select "select[name='account[plan_role]'] option[value=checking]", 1
        assert_select "select[name='account[plan_role]'] option[value=credit_card_payoff]", 1
        assert_select "select[name='account[plan_role]'] option[value=loan_payoff]", 1
        assert_select "select[name='account[plan_role]'] option[value=investment]", 1
        assert_select "select[name='account[plan_role]'] option[disabled][value='']", 1
        # Round 20a heading + 20d avatar.
        assert_select "[data-bank-config-dialog-target=pullFrom]", 1
        assert_select "[data-bank-config-dialog-target=avatarImg]", 1
        assert_includes response.body, I18n.t("plan_flows.bank_config_dialog.pull_from_incomes")
      end
    end
  end

  test "unchecking a linked income and saving removes the link (round 20 save bug)" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "required")
      # plan_order keeps the dialog rendered even after the edge is gone
      # (the depository fixture carries no other plan marker).
      @account.update!(plan_order: 1)

      # Exactly what the dialog posts when the checkbox is unchecked: only
      # the hidden sentinel (the disabled rule controls send no values).
      patch "/plan/flow/accounts/#{@account.id}", headers: { "Accept" => "application/json" }, params: {
        account: { plan_ownership: "shared", plan_role: "", bank_logo_slug: "",
                   parent_account_id: "", auto_transfer_target_ids: [ "0" ] },
        links: { series.id.to_s => { "enabled" => "" } }
      }
      assert_response :success
      json = JSON.parse(response.body)
      assert_equal "bank:#{@account.id}", json["chrome"]["bank_dialogs"][0]["node_id"]
      assert_not IncomeAccountAllocation.exists?(income_series_id: series.id, account_id: @account.id)

      # Re-checking persists a new edge (round trip in the other direction).
      patch "/plan/flow/accounts/#{@account.id}", headers: { "Accept" => "application/json" }, params: {
        account: { plan_ownership: "shared", plan_role: "", bank_logo_slug: "",
                   parent_account_id: "", auto_transfer_target_ids: [ "0" ] },
        links: { series.id.to_s => { "enabled" => "1", "mode" => "leftover" } }
      }
      assert_response :success
      edge = IncomeAccountAllocation.find_by(income_series_id: series.id, account_id: @account.id)
      assert_equal "leftover", edge.mode
    end
  end

  test "kebab make-sub-account round trip: set and clear the parent link" do
    child = create_vault("Baby Vault")
    # Both accounts carry a plan marker: the child to render its dialog,
    # the parent to be listed as a sub-account candidate.
    @account.update!(plan_order: 1)
    child.update!(plan_order: 2)

    # The dialog markup: the popup lists the in-plan parent candidates +
    # the "Not a sub-account" clear entry (empty value).
    travel_to Date.new(2026, 11, 15) do
      get "/plan/flow"
      assert_response :success
      assert_select "dialog[data-node-id='bank:#{child.id}'] [data-bank-config-dialog-target=subAccountPopup] [data-bank-config-dialog-target=subAccountSelect]", 1 do
        assert_select "option[value='']", 1
        assert_select "option[value='#{@account.id}']", 1
      end
    end

    # Set via the same param the popup's Save submits.
    patch "/plan/flow/accounts/#{child.id}", headers: { "Accept" => "application/json" }, params: {
      account: { plan_ownership: "shared", plan_role: "", bank_logo_slug: "",
                 parent_account_id: @account.id }
    }
    assert_response :success
    assert_equal @account.id, child.reload.parent_account_id

    # "Not a sub-account" posts an empty value -> clears the link.
    patch "/plan/flow/accounts/#{child.id}", headers: { "Accept" => "application/json" }, params: {
      account: { plan_ownership: "shared", plan_role: "", bank_logo_slug: "",
                 parent_account_id: "" }
    }
    assert_response :success
    assert_nil child.reload.parent_account_id
  end

  test "role change persists the new five-value roles" do
    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { plan_ownership: "shared", plan_role: "investment" }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal "investment", @account.reload.plan_role
    assert_not Account.plan_role_debt?(@account.plan_role)

    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { plan_ownership: "shared", plan_role: "checking" }
    }
    assert_equal "checking", @account.reload.plan_role

    # Debt roles still classify as debt (the planner's "Pay off X" kinds).
    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { plan_ownership: "shared", plan_role: "credit_card_payoff" }
    }
    account = @account.reload
    assert_equal "credit_card_payoff", account.plan_role
    assert Account.plan_role_debt?(account.plan_role)
  end

  test "auto-transfer via the kebab: the sentinel-only post clears the targets" do
    child = create_vault("Baby Vault")
    @account.update!(plan_order: 1) # render the dialog
    patch "/plan/flow/accounts/#{child.id}", params: {
      account: { parent_account_id: @account.id }
    }

    # The popup's checkbox list marks the sub-account row enabled.
    travel_to Date.new(2026, 11, 15) do
      get "/plan/flow"
      assert_response :success
      assert_select "dialog[data-node-id='bank:#{@account.id}'] [data-bank-config-dialog-target=autoTransferBox] input[type=checkbox][data-other-id='#{child.id}']", 1
    end

    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { auto_transfer_target_ids: [ "0", child.id.to_s ] }
    }
    assert_equal [ child.id.to_s ], @account.reload.auto_transfer_target_ids

    # All unchecked posts only the "0" sentinel -> dropped, and the jsonb
    # column holds an empty array (the ERB's Array() render sees no rows).
    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { auto_transfer_target_ids: [ "0" ] }
    }
    assert_equal [], @account.reload.auto_transfer_target_ids
  end

  # 1x1 transparent PNG (67 bytes) for the upload tests.
  ROUND20_TEST_PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
  ).freeze

  def round20_upload(bytes, content_type, name)
    Rack::Test::UploadedFile.new(StringIO.new(bytes), content_type, original_filename: name)
  end

  test "bank logo custom upload validates, persists, and removes" do
    travel_to Date.new(2026, 11, 15) do
      # Wrong content type (SVG deliberately excluded - XSS vector).
      post "/plan/flow/accounts/#{@account.id}/bank-logo",
        headers: { "Accept" => "application/json" },
        params: { image: round20_upload("<svg/>".b, "image/svg+xml", "logo.svg") }
      assert_response :unprocessable_entity
      assert_includes JSON.parse(response.body)["errors"],
        I18n.t("plan_flows.upload_bank_logo.bank_logo_not_an_image")

      # Oversized (1 MB + 1).
      post "/plan/flow/accounts/#{@account.id}/bank-logo",
        headers: { "Accept" => "application/json" },
        params: { image: round20_upload("x".b * (1_048_577), "image/png", "big.png") }
      assert_response :unprocessable_entity
      assert_includes JSON.parse(response.body)["errors"],
        I18n.t("plan_flows.upload_bank_logo.bank_logo_too_large")

      # Missing file.
      post "/plan/flow/accounts/#{@account.id}/bank-logo",
        headers: { "Accept" => "application/json" },
        params: {}
      assert_response :unprocessable_entity
      assert_includes JSON.parse(response.body)["errors"],
        I18n.t("plan_flows.upload_bank_logo.bank_logo_missing_file")

      # Valid upload -> 200 + the avatar URL (the model's own helper).
      post "/plan/flow/accounts/#{@account.id}/bank-logo",
        headers: { "Accept" => "application/json" },
        params: { image: round20_upload(ROUND20_TEST_PNG, "image/png", "custom.png") }
      assert_response :success
      account = @account.reload
      assert account.logo.attached?
      assert_equal JSON.parse(response.body)["logo_url"],
        Rails.application.routes.url_helpers.rails_blob_path(account.logo, only_path: true)
      assert_equal account.plan_flow_avatar_url,
        Rails.application.routes.url_helpers.rails_blob_path(account.logo, only_path: true)

      # The dialog avatar renders the custom URL.
      get "/plan/flow"
      assert_response :success
      assert_includes response.body, %(src="#{account.plan_flow_avatar_url}")

      # Re-upload replaces (still exactly one attachment).
      post "/plan/flow/accounts/#{@account.id}/bank-logo",
        headers: { "Accept" => "application/json" },
        params: { image: round20_upload(ROUND20_TEST_PNG, "image/png", "other.png") }
      assert_response :success
      assert_equal 1, ActiveStorage::Attachment
        .where(record_type: "Account", record_id: @account.id, name: "logo").count

      # Remove -> 200 + nil url; the purge is enqueued (async, house
      # pattern). Block form: the re-upload's purge counts separately.
      assert_enqueued_jobs(1, only: ActiveStorage::PurgeJob) do
        delete "/plan/flow/accounts/#{@account.id}/bank-logo",
          headers: { "Accept" => "application/json" }
      end
      assert_response :success
      assert_nil JSON.parse(response.body)["logo_url"]
    end
  end
      # Bank config dialog: the logo picker (search + hidden slug input +
      # the vendored list) and J's fan-out fields intact.
        assert_select "section[data-controller=bank-logo-picker]", 1 do
          assert_select "input[name='account[bank_logo_slug]'][type=hidden]", 1
          assert_select "[data-bank-logo-picker-target=search]", 1
          assert_select "[data-bank-logo-picker-target=choice][data-slug=sofi]", 1
        end
        assert_select "select[name='account[parent_account_id]']", 1
      # Allocation dialog (edit mode): the category select carries the
      # family's categories.
        assert_select "select[name='plan_allocation[category_id]']", 1 do
          assert_select "option[value='#{category.id}']", 1
        end
        assert_select "input[type=hidden][name='account[auto_transfer_target_ids][]'][value='0']", 1
      end

      assert_select "dialog[data-node-id='allocation:#{allocation.id}']", 1 do
      end
    end
  end

  # ---------------------------------------------------------------------
  # Round 20 (T): the save bug + the progressive-disclosure rework.
  # Controller round-trips for uncheck / sub-account / fan-out pre-date this
  # round (edge-editor era, above); these pin the NEW dialog markup, the
  # five-value role enum, and the custom-logo upload/remove endpoints.
  # ---------------------------------------------------------------------

  test "bank dialog renders the uncheck sentinel, kebab popups, and the five roles" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "required")

      get "/plan/flow"
      assert_response :success

      assert_select "dialog[data-node-id='bank:#{@account.id}']", 1 do
        # Round 20 save-bug fix: an unchecked browser checkbox sends NO
        # param, so the hidden empty sentinel (before the checkbox) is what
        # makes the controller see the row and destroy the edge.
        assert_select "input[type=hidden][name='links[#{series.id}][enabled]'][value='']", 1
        # Progressive disclosure: the rule select sits inside the row's
        # details wrapper (visible because this row is checked).
        assert_select "[data-bank-row-details] select[name='links[#{series.id}][mode]']", 1
        # Round 20b: the kebab + the sub-account popup (the select is
        # unnamed; it syncs into the form's hidden input).
        assert_select "[data-bank-config-dialog-target=kebabMenu]", 1
        assert_select "[data-bank-config-dialog-target=subAccountPopup] [data-bank-config-dialog-target=subAccountSelect]", 1
        assert_select "[data-bank-config-dialog-target=subAccountSelect] option[value='']", 1
        # Round 20e: the auto-transfer popup with the checkbox box.
        assert_select "[data-bank-config-dialog-target=autoTransferPopup] [data-bank-config-dialog-target=autoTransferBox]", 1
        # Round 20c: exactly the five roles (plus the disabled Plain
        # placeholder while the role is nil).
        assert_select "select[name='account[plan_role]'] option[value=savings_bucket]", 1
        assert_select "select[name='account[plan_role]'] option[value=checking]", 1
        assert_select "select[name='account[plan_role]'] option[value=credit_card_payoff]", 1
        assert_select "select[name='account[plan_role]'] option[value=loan_payoff]", 1
        assert_select "select[name='account[plan_role]'] option[value=investment]", 1
        assert_select "select[name='account[plan_role]'] option[disabled][value='']", 1
        # Round 20a heading + 20d avatar.
        assert_select "[data-bank-config-dialog-target=pullFrom]", 1
        assert_select "[data-bank-config-dialog-target=avatarImg]", 1
        assert_includes response.body, I18n.t("plan_flows.bank_config_dialog.pull_from_incomes")
      end
    end
  end

  test "unchecking a linked income and saving removes the link (round 20 save bug)" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "required")
      # plan_order keeps the dialog rendered even after the edge is gone
      # (the depository fixture carries no other plan marker).
      @account.update!(plan_order: 1)

      # Exactly what the dialog posts when the checkbox is unchecked: only
      # the hidden sentinel (the disabled rule controls send no values).
      patch "/plan/flow/accounts/#{@account.id}", headers: { "Accept" => "application/json" }, params: {
        account: { plan_ownership: "shared", plan_role: "", bank_logo_slug: "",
                   parent_account_id: "", auto_transfer_target_ids: ["0"] },
        links: { series.id.to_s => { "enabled" => "" } }
      }
      assert_response :success
      json = JSON.parse(response.body)
      assert_equal "bank:#{@account.id}", json["chrome"]["bank_dialogs"][0]["node_id"]
      assert_not IncomeAccountAllocation.exists?(income_series_id: series.id, account_id: @account.id)

      # Re-checking persists a new edge (round trip in the other direction).
      patch "/plan/flow/accounts/#{@account.id}", headers: { "Accept" => "application/json" }, params: {
        account: { plan_ownership: "shared", plan_role: "", bank_logo_slug: "",
                   parent_account_id: "", auto_transfer_target_ids: ["0"] },
        links: { series.id.to_s => { "enabled" => "1", "mode" => "leftover" } }
      }
      assert_response :success
      edge = IncomeAccountAllocation.find_by(income_series_id: series.id, account_id: @account.id)
      assert_equal "leftover", edge.mode
    end
  end

  test "kebab make-sub-account round trip: set and clear the parent link" do
    child = create_vault("Baby Vault")
    # Both accounts carry a plan marker: the child to render its dialog,
    # the parent to be listed as a sub-account candidate.
    @account.update!(plan_order: 1)
    child.update!(plan_order: 2)

    # The dialog markup: the popup lists the in-plan parent candidates +
    # the "Not a sub-account" clear entry (empty value).
    travel_to Date.new(2026, 11, 15) do
      get "/plan/flow"
      assert_response :success
      assert_select "dialog[data-node-id='bank:#{child.id}'] [data-bank-config-dialog-target=subAccountPopup] [data-bank-config-dialog-target=subAccountSelect]", 1 do
        assert_select "option[value='']", 1
        assert_select "option[value='#{@account.id}']", 1
      end
    end

    # Set via the same param the popup's Save submits.
    patch "/plan/flow/accounts/#{child.id}", headers: { "Accept" => "application/json" }, params: {
      account: { plan_ownership: "shared", plan_role: "", bank_logo_slug: "",
                 parent_account_id: @account.id }
    }
    assert_response :success
    assert_equal @account.id, child.reload.parent_account_id

    # "Not a sub-account" posts an empty value -> clears the link.
    patch "/plan/flow/accounts/#{child.id}", headers: { "Accept" => "application/json" }, params: {
      account: { plan_ownership: "shared", plan_role: "", bank_logo_slug: "",
                 parent_account_id: "" }
    }
    assert_response :success
    assert_nil child.reload.parent_account_id
  end

  test "role change persists the new five-value roles" do
    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { plan_ownership: "shared", plan_role: "investment" }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal "investment", @account.reload.plan_role
    assert_not Account.plan_role_debt?(@account.plan_role)

    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { plan_ownership: "shared", plan_role: "checking" }
    }
    assert_equal "checking", @account.reload.plan_role

    # Debt roles still classify as debt (the planner's "Pay off X" kinds).
    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { plan_ownership: "shared", plan_role: "credit_card_payoff" }
    }
    account = @account.reload
    assert_equal "credit_card_payoff", account.plan_role
    assert Account.plan_role_debt?(account.plan_role)
  end

  test "auto-transfer via the kebab: the sentinel-only post clears the targets" do
    child = create_vault("Baby Vault")
    @account.update!(plan_order: 1) # render the dialog
    patch "/plan/flow/accounts/#{child.id}", params: {
      account: { parent_account_id: @account.id }
    }

    # The popup's checkbox list marks the sub-account row enabled.
    travel_to Date.new(2026, 11, 15) do
      get "/plan/flow"
      assert_response :success
      assert_select "dialog[data-node-id='bank:#{@account.id}'] [data-bank-config-dialog-target=autoTransferBox] input[type=checkbox][data-other-id='#{child.id}']", 1
    end

    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { auto_transfer_target_ids: [ "0", child.id.to_s ] }
    }
    assert_equal [ child.id.to_s ], @account.reload.auto_transfer_target_ids

    # All unchecked posts only the "0" sentinel -> dropped, and the jsonb
    # column holds an empty array (the ERB's Array() render sees no rows).
    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { auto_transfer_target_ids: [ "0" ] }
    }
    assert_equal [], @account.reload.auto_transfer_target_ids
  end

  # 1x1 transparent PNG (67 bytes) for the upload tests.
  ROUND20_TEST_PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
  ).freeze

  def round20_upload(bytes, content_type, name)
    Rack::Test::UploadedFile.new(StringIO.new(bytes), content_type, original_filename: name)
  end

  test "bank logo custom upload validates, persists, and removes" do
    travel_to Date.new(2026, 11, 15) do
      # Wrong content type (SVG deliberately excluded - XSS vector).
      post "/plan/flow/accounts/#{@account.id}/bank-logo",
        headers: { "Accept" => "application/json" },
        params: { image: round20_upload("<svg/>".b, "image/svg+xml", "logo.svg") }
      assert_response :unprocessable_entity
      assert_includes JSON.parse(response.body)["errors"],
        I18n.t("plan_flows.upload_bank_logo.bank_logo_not_an_image")

      # Oversized (1 MB + 1).
      post "/plan/flow/accounts/#{@account.id}/bank-logo",
        headers: { "Accept" => "application/json" },
        params: { image: round20_upload("x".b * (1_048_577), "image/png", "big.png") }
      assert_response :unprocessable_entity
      assert_includes JSON.parse(response.body)["errors"],
        I18n.t("plan_flows.upload_bank_logo.bank_logo_too_large")

      # Missing file.
      post "/plan/flow/accounts/#{@account.id}/bank-logo",
        headers: { "Accept" => "application/json" },
        params: {}
      assert_response :unprocessable_entity
      assert_includes JSON.parse(response.body)["errors"],
        I18n.t("plan_flows.upload_bank_logo.bank_logo_missing_file")

      # Valid upload -> 200 + the avatar URL (the model's own helper).
      post "/plan/flow/accounts/#{@account.id}/bank-logo",
        headers: { "Accept" => "application/json" },
        params: { image: round20_upload(ROUND20_TEST_PNG, "image/png", "custom.png") }
      assert_response :success
      account = @account.reload
      assert account.logo.attached?
      assert_equal JSON.parse(response.body)["logo_url"],
        Rails.application.routes.url_helpers.rails_blob_path(account.logo, only_path: true)
      assert_equal account.plan_flow_avatar_url,
        Rails.application.routes.url_helpers.rails_blob_path(account.logo, only_path: true)

      # The dialog avatar renders the custom URL.
      get "/plan/flow"
      assert_response :success
      assert_includes response.body, %(src="#{account.plan_flow_avatar_url}")

      # Re-upload replaces (still exactly one attachment).
      post "/plan/flow/accounts/#{@account.id}/bank-logo",
        headers: { "Accept" => "application/json" },
        params: { image: round20_upload(ROUND20_TEST_PNG, "image/png", "other.png") }
      assert_response :success
      assert_equal 1, ActiveStorage::Attachment
        .where(record_type: "Account", record_id: @account.id, name: "logo").count

      # Remove -> 200 + nil url; the purge is enqueued (async, house
      # pattern). Block form: the re-upload's purge counts separately.
      assert_enqueued_jobs(1, only: ActiveStorage::PurgeJob) do
        delete "/plan/flow/accounts/#{@account.id}/bank-logo",
          headers: { "Accept" => "application/json" }
      end
      assert_response :success
      assert_nil JSON.parse(response.body)["logo_url"]
    end
  end
end
