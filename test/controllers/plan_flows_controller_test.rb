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

  # The exact in-place save the bank dialog's Save button posts (the
  # account hidden inputs + the COMPLETE links map — one row per family
  # income; the dialog submits the hidden mode/value inputs,
  # which this shape mirrors).
  def patch_bank_links(links:, account: @account)
    patch "/plan/flow/accounts/#{account.id}", headers: { "Accept" => "application/json" }, params: {
      account: { plan_ownership: "shared", plan_role: "", bank_logo_slug: "",
                 parent_account_id: "", auto_transfer_target_ids: [ "0" ] },
      links: links
    }
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
      # the column headers are buttons — Add Income goes
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
      # .
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
      # the empty-state CTA is the 4-kind picker (a DS::Menu
      # flat action menu — Bill / Debt / Savings / Fun Money). The trigger
      # carries no plan-flow data-action of its own (the DS--menu
      # controller's own click listener toggles the menu); the items are
      # <button>s wired to plan-flow#openAllocationKind, which opens the
      # allocation:new dialog pre-set to the picked kind.
      assert_select "div[data-flow-chrome='overlays'] div[data-controller='DS--menu']", 1
      %w[bill debt savings fun_money].each do |kind|
        assert_select "div[data-flow-chrome='overlays'] button[data-allocation-kind='#{kind}']", 1
      end
      # The dialog header CTA renders its own picker instance.
      assert_select "dialog[data-node-id='allocation:new'] button[data-allocation-kind='bill']", 1
      # the Recommended list was removed from the empty state
      # ; the header + Add Allocation button are the only
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
      # 1800/mo in (2 x 900.00), 2500/mo required -> 700.00/mo short.
      # the top-bar figure is unit-aware —
      # the default Per Paycheck view shows the per-paycheck share
      # (700.00 / 2 occurrences = 350.00).
      assert_includes response.body, "Over-planned by $350.00 on Bob Payroll"

      # The Per Month view renders the same line with the monthly figure.
      get "/plan/flow", params: { view: "monthly" }
      assert_response :success
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
        # the mode select is an -style trigger
        # button — the hidden mode input (the submit carrier) holds the
        # stored mode and the four modes are the floating panel's radios.
        assert_select "input[type=hidden][name='links[#{series.id}][mode]'][value=percent]", 1
        assert_select "[data-bank-pull-panel-group='row-#{series.id}'] input[type=radio][value=required]", 1
        assert_select "[data-bank-pull-panel-group='row-#{series.id}'] input[type=radio][value=specific]", 1
        assert_select "[data-bank-pull-panel-group='row-#{series.id}'] input[type=radio][value=percent]", 1
        assert_select "[data-bank-pull-panel-group='row-#{series.id}'] input[type=radio][value=leftover]", 1
        # Ownership / role / sub-account selects ( issue 8: the
        # legacy single auto-transfer select is replaced by the
        # sub-account-of select + the multi-target fan-out checkboxes).
        assert_select "select[name='account[plan_ownership]']"
        assert_select "select[name='account[plan_role]'] option[value=savings_bucket]"
        assert_select "select[name='account[plan_role]'] option[value=credit_card_payoff]"
        assert_select "select[name='account[plan_role]'] option[value=loan_payoff]"
        # the sub-account select is unnamed (the kebab popup
        # syncs it into the form's hidden input, which is what submits).
        assert_select "input[type=hidden][name='account[parent_account_id]']"
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
      # New dialog: the Bank source is a labeled row + a
      # floating dropdown panel holding the radio list (the radios live
      # OUTSIDE the form — the form's hidden plan_allocation[account_id]
      # input is the submit carrier; a native select cannot show the logo
      # either way), and the value input is plan_allocation[value]
      # (required = monthly, deviation 1).
      assert_select "dialog[data-node-id='allocation:new']", 1 do
        assert_select "input[type=radio][name='plan_allocation[account_id]'][value='#{@account.id}']"
        assert_select "input[type=hidden][name='plan_allocation[account_id]']", 1
        assert_select "div[data-allocation-bank-panel]", 1
        assert_select "[data-allocation-bank-trigger]", 1
        assert_select "input[name='plan_allocation[value]']"
        assert_select "select[name='plan_allocation[mode]'] option[value=required][selected]"
        # the kind is a HIDDEN input — no visible
        # kind select anywhere in the dialog.
        assert_select "input[type=hidden][name='plan_allocation[kind]'][value=bill]", 1
        assert_select "select[name='plan_allocation[kind]']", count: 0
      end
      # + : the new dialog opens on the Known
      # Allocations list — Sure's detected bills/subscriptions, MINUS the
      # ones already in the diagram (hidden, not flagged).
      netflix = recurring_transactions(:netflix_subscription)
      assert_select "dialog[data-node-id='allocation:new'] button[data-known-id='#{netflix.id}']", 1
      # the known_allocations payload carries the
      # bill's category (data-known-category) so the dialog's prefill
      # paths can preselect it.
      known_category = @family.categories.create!(name: "Groceries", color: "#11AA22")
      netflix.update!(category_id: known_category.id)
      get "/plan/flow"
      assert_response :success
      assert_select "dialog[data-node-id='allocation:new'] button[data-known-id='#{netflix.id}'][data-known-category='#{known_category.id}']", 1
      PlanAllocation.create!(family: @family, account: @account, name: "Netflix",
        kind: "bill", mode: "required", value_cents: 1_599, cadence: "monthly",
        recurring_transaction: netflix)
      get "/plan/flow"
      assert_response :success
      # the planned bill no longer lists — and the empty list says
      # everything detected is already in the diagram (it was the only one).
      assert_select "dialog[data-node-id='allocation:new'] button[data-known-id='#{netflix.id}']", count: 0
      assert_select "dialog[data-node-id='allocation:new'] [data-plan-flow-target='knownSection']",
        text: /already in the diagram/
      # Edit dialog: prefill + the delete form.
      assert_select "dialog[data-node-id='allocation:#{row.id}']", 1 do
        assert_select "input[name='plan_allocation[name]'][value='Bills']"
        assert_select "input[name='plan_allocation[value]'][value='500.00']"
        assert_select "input[type=hidden][value='delete']"
        # the Bank source row is pre-populated with the
        # allocation's CURRENT source bank — the trigger shows the bank
        # name (the none-icon stays hidden), the form's hidden carrier
        # holds the bank id, and the panel's radio for that bank is the
        # checked row (the unassigned radio is not) — so re-opening an
        # already-assigned allocation renders its bank, not "None
        # Selected".
        assert_select "[data-allocation-bank-trigger] [data-allocation-bank-name]", text: @account.name
        assert_select "[data-allocation-bank-trigger] span[data-allocation-bank-none-icon].hidden", 1
        assert_select "input[type=hidden][name='plan_allocation[account_id]'][value='#{@account.id}']", 1
        assert_select "input[type=radio][name='plan_allocation[account_id]'][value='#{@account.id}'][checked]", 1
        assert_select "input[type=radio][name='plan_allocation[account_id]'][value=''][checked]", count: 0
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
    # the page keeps no manual-creation form of its own —
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

  # (ghost banks): the in-place (JSON) add ships the fresh graph —
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

  # the Add-Account guardrail — an account already placed
  # in ANOTHER area (a sub-row via the parent link, the dressed allocation
  # pillar via a target allocation) is not offered by the modal: adding it
  # would place it in a second area (the invisible duplicate row).
  test "the add-accounts modal does not offer parent-linked or target-dressed accounts" do
    unassigned = create_vault("Unassigned Checking")
    sub = @family.accounts.create!(name: "Sub Savings", owner: @user,
      currency: "USD", balance: 0, accountable: Depository.new,
      parent_account_id: @account.id)
    dressed = create_vault("Dressed Savings")
    PlanAllocation.create!(family: @family, account: @account, name: "Dressed",
      kind: "savings", mode: "required", value_cents: 100_000,
      target_account_id: dressed.id)

    get "/plan/flow/add-accounts"

    assert_response :success
    assert_select "form[action='/plan/flow_add_accounts'] input[type=checkbox][name='account_ids[]'][value='#{unassigned.id}']", 1
    assert_select "form[action='/plan/flow_add_accounts'] input[type=checkbox][name='account_ids[]'][value='#{sub.id}']", count: 0
    assert_select "form[action='/plan/flow_add_accounts'] input[type=checkbox][name='account_ids[]'][value='#{dressed.id}']", count: 0
  end

  # defense in depth — the server rejects a submission
  # that names an account already placed by ANY placement (plan_order,
  # parent link, or target allocation) with the render_flow_json 422
  # contract instead of silently placing it a second time. A mixed batch
  # 422s as a whole and nothing is half-placed.
  test "add accounts rejects an already-placed account with 422 and places nothing" do
    a = create_vault("Fresh A")
    placed = create_vault("Placed B")
    placed.update!(plan_order: 1)
    sub = @family.accounts.create!(name: "Sub C", owner: @user, currency: "USD",
      balance: 0, accountable: Depository.new,
      parent_account_id: placed.id)
    dressed = create_vault("Dressed D")
    PlanAllocation.create!(family: @family, account: @account, name: "Dressed",
      kind: "savings", mode: "required", value_cents: 100_000,
      target_account_id: dressed.id)

    # plan_order-placed: the fresh sibling stays unplaced (no half batch).
    post "/plan/flow_add_accounts", params: { account_ids: [ a.id, placed.id ] },
         headers: { "Accept" => "application/json" }
    assert_response :unprocessable_entity
    assert_nil a.reload.plan_order

    # parent-link-placed: the same 422, nothing placed.
    post "/plan/flow_add_accounts", params: { account_ids: [ a.id, sub.id ] },
         headers: { "Accept" => "application/json" }
    assert_response :unprocessable_entity
    assert_nil a.reload.plan_order

    # target-dressed: the same 422, nothing placed.
    post "/plan/flow_add_accounts", params: { account_ids: [ a.id, dressed.id ] },
         headers: { "Accept" => "application/json" }
    assert_response :unprocessable_entity
    assert_nil a.reload.plan_order
  end

  # (create-account tests removed with the action — , .)

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

    # Blank clears the label back to the account-holder fallback.
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
      # the ADDITIVE mode field on every inflow row — the
      # leftover edge's inflow carries mode "leftover" (the sankey icon + the
      # DD leftover row derive from it). Additive-only: existing keys keep
      # their order, mode is appended last.
      assert bank["inflow"].all? { |row| row.key?("mode") },
        "every inflow row must carry the additive mode field"
      assert_equal "leftover", bank["inflow"].first["mode"]
      assert_equal [], json["over_plans"]
      # netflix_subscription (15.99/mo) is not allocated yet -> recommended.
      assert json["recommendations"].any? { |r| r["type"] == "recurring_transaction" }
    end
  end

  # the SAVED state must expose the exact per-allocation
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

  # --- issue 4 + U + : the savings bucket ---
  # The dialog shows the bucket's associated-account hint (the existing
  # account_id field, now the Bank source radio list) and the mode-shaped
  # value field.: the Mode selector is visible + functional for
  # buckets (all four kinds support all four modes; the mode group is
  # hidden only for linked rows), so a user-chosen mode + its value
  # persist — only the truly hidden controls (cadence / detected-bill
  # link; auto-transfer is gone, U) are sanitized away
  # server-side.

  test "the savings bucket dialog shows the mode selector and bucket labels, hiding only cadence + RT link" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")
      bucket = PlanAllocation.create!(family: @family, account: @account,
        name: "Pet Safety Fund", kind: "savings", mode: "required", value_cents: 25_000)

      get "/plan/flow"

      assert_response :success
      # Edit dialog: the two bill-only blocks that STAY hidden
      # for the bucket kind (cadence / detected bill link) render hidden,
      # while the Mode selector is VISIBLE with all four options (the mode
      # group is hidden only for linked rows — this bucket is unlinked),
      # and the amount input + the bank-source hint wear the bucket labels.
      # the RT box is bill-only now (gate "bill"), hidden for
      # EVERY non-bill kind including debt; cadence + the category picker
      # (and the kind select) live inside the collapsed "More options"
      # disclosure instead of at the top of the form.
      assert_select "dialog[data-node-id='allocation:#{bucket.id}']", 1 do
        assert_select "input[name='plan_allocation[name]'][value='Pet Safety Fund']"
        assert_select "div[data-allocation-kinds].hidden", count: 2
        assert_select "div[data-allocation-kinds].hidden select[name='plan_allocation[cadence]']"
        assert_select "div[data-allocation-kinds].hidden select[name='plan_allocation[recurring_transaction_id]']"
        assert_select "div[data-allocation-mode-group].hidden", count: 0
        assert_select "div[data-allocation-mode-group] select[name='plan_allocation[mode]'] option[value=required][selected]"
        assert_select "div[data-allocation-mode-group] select[name='plan_allocation[mode]'] option[value=specific]"
        assert_select "div[data-allocation-mode-group] select[name='plan_allocation[mode]'] option[value=percent]"
        assert_select "div[data-allocation-mode-group] select[name='plan_allocation[mode]'] option[value=leftover]"
        assert_select "input[name='plan_allocation[auto_transfer]']", count: 0
        assert_select "label[for$='allocation_value']", text: I18n.t("plan_flows.allocation_dialog.savings_value_label")
        assert_select "p[data-allocation-kind-hint='account']", text: I18n.t("plan_flows.allocation_dialog.savings_account_hint")
        assert_select "input[name='plan_allocation[value]'][value='250.00']"
        # (items 7c/7d): no collapsibles — the kind select is
        # a hidden input on the current kind, and the second-tier fields
        # (cadence / category trigger + icon chip) sit flat in the form.
        assert_select "select[name='plan_allocation[kind]']", count: 0
        assert_select "input[type=hidden][name='plan_allocation[kind]'][value=savings]", 1
        assert_select "select[name='plan_allocation[cadence]']"
        assert_select "[data-allocation-category-selection]"
        assert_select "[data-allocation-category-icon-chip]"
      end
      # New dialog (kind defaults to bill): the bill fields stay visible and
      # the bill labels show — the bucket view is kind-specific. The RT box
      # is bill-gated, so it is visible here too (client-side the
      # #applyAllocationVisibility loop keeps both bill-gated blocks shown).
      assert_select "dialog[data-node-id='allocation:new']", 1 do
        assert_select "div[data-allocation-kinds].hidden", count: 0
        assert_select "label[for$='allocation_value']", text: I18n.t("plan_flows.allocation_dialog.value_label")
        assert_select "p[data-allocation-kind-hint='account']", text: I18n.t("plan_flows.allocation_dialog.source_bank_hint")
        # (items 7c/7d): flat layout — the kind is a hidden
        # input on the form default (bill); no visible kind select.
        assert_select "input[type=hidden][name='plan_allocation[kind]'][value=bill]", 1
        assert_select "select[name='plan_allocation[kind]']", count: 0
      end
    end
  end

  # the detected-bill link is now BILL-ONLY (the custom box's
  # data-allocation-kinds gate is "bill", was "bill,debt"). The
  # #applyAllocationVisibility kind loop hides every [data-allocation-kinds]
  # box whose list lacks the current kind, so for a DEBT allocation the RT
  # box is hidden client-side while the cadence (gate "bill,debt") stays
  # visible. A controller test sees the server-rendered HTML, so it
  # asserts the gate attribute that drives the hiding (debt gets no
  # server-side hidden class: bucket_kind is savings/fun_money only).
  test "the debt dialog gates the detected-bill link to bill only, keeping cadence" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")
      debt = PlanAllocation.create!(family: @family, account: @account,
        name: "Card Minimum", kind: "debt", mode: "required", value_cents: 120_000,
        cadence: "monthly")

      get "/plan/flow"

      assert_response :success
      assert_select "dialog[data-node-id='allocation:#{debt.id}']", 1 do
        # The RT box gate is "bill" only — the kind loop hides it for debt.
        assert_select "div[data-allocation-kinds='bill'] select[name='plan_allocation[recurring_transaction_id]']"
        assert_select "div[data-allocation-kinds='bill']", count: 1
        # The cadence gate still includes debt — it stays visible.
        assert_select "div[data-allocation-kinds='bill,debt'] select[name='plan_allocation[cadence]']"
        assert_select "div[data-allocation-kinds='bill,debt']", count: 1
        # The mode selector stays visible (hidden only for linked rows).
        assert_select "div[data-allocation-mode-group].hidden", count: 0
        # (items 7c/7d): flat layout — the kind is a hidden
        # input on the current kind; the cadence select + category trigger
        # sit in the form directly.
        assert_select "select[name='plan_allocation[kind]']", count: 0
        assert_select "input[type=hidden][name='plan_allocation[kind]'][value=debt]", 1
        assert_select "select[name='plan_allocation[cadence]'] option[value=monthly][selected]"
        assert_select "[data-allocation-category-selection]"
      end
    end
  end

  test "create a savings bucket keeps the user-chosen mode and sanitizes the stale hidden fields" do
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
    # the user-chosen mode survives for buckets (all four
    # modes are valid for every kind) — percent keeps its percent value and
    # the stale major-unit value must NOT persist (value_cents is forbidden
    # in percent mode, model-owned). The hidden controls (cadence / RT
    # link / auto-transfer) are still sanitized away.
    assert_equal "percent", row.mode
    assert_equal 0.05, row.value_percent.to_f
    assert_nil row.value_cents
    assert_nil row.cadence
    assert_nil row.recurring_transaction_id
    assert_equal false, row.auto_transfer
    assert_equal @account.id, row.account_id
  end

  test "update a savings bucket keeps the user-chosen mode and re-sanitizes the stale hidden fields" do
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
    # the update's user-chosen mode (percent) survives — the
    # percent value replaces the old monthly figure (value_cents must be
    # nil in percent mode, model-owned); the hidden fields (cadence /
    # auto-transfer) are still sanitized away.
    assert_equal "percent", row.mode
    assert_equal 0.05, row.value_percent.to_f
    assert_nil row.value_cents
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

  test "graph draft previews a savings row in the user-chosen mode" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")
      bucket_bank = @family.accounts.create!(name: "Pet Safety Bank", owner: @user,
        currency: "USD", balance: 0, accountable: Depository.new)

      # the draft merge no longer normalizes a bucket to the
      # monthly required shape — the user-chosen mode (percent) survives, so
      # the preview carries value_percent and the stale major-unit value is
      # not persisted. Unfunded bank: a percent of a zero pool demands
      # nothing (wanted 0 -> status ok, no over-plan flag).
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
      assert_equal "percent", saved["mode"]
      assert_equal "0.0500", saved["value_percent"]
      assert_nil saved["value_cents"]
      assert_equal "0.00", saved["wanted_month"] # 5% of a zero leftover pool
      assert_equal "0.00", saved["got_month"] # no funding edge -> unfunded
      assert_equal "ok", saved["status"]
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

  # --- : (in-place JSON responses) + (bank removal) ---

  # the delete path is what broke the diagram (add worked since ).
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

  # create + update share the same in-place contract.
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

  # "Make Allocated Sub-Account" — the bank dialog kebab
  # creates a TARGET allocation (the row dresses the target account in the
  # allocation pillar; account_id stays the SOURCE bank, frozen semantics).
  # The create response carries the target fields in the graph row and
  # re-renders the target account's bank dialog (the kebab flips to the
  # REVERSE); a dangling target id is a 422 with the field error; the
  # reverse (destroy) unfreezes the bank row; the bank-as-allocation
  # recommendation skips a dressed account; an allocation-dialog save of a
  # dressed row keeps the target (the hidden input contract).
  test "create allocation with a target account dresses the row and re-renders the target dialog" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")
      target = create_vault("Frosty Tools")
      @account.update!(plan_order: 1)

      post "/plan/flow/allocations", headers: { "Accept" => "application/json" }, params: {
        plan_allocation: { account_id: @account.id, name: "Frosty Tools", kind: "savings",
                           mode: "required", value: "100.00",
                           target_account_id: target.id }
      }
      assert_response :success
      json = JSON.parse(response.body)
      row = json["graph"]["allocations"].find { |a| a["name"] == "Frosty Tools" }
      assert_equal target.id, row["target_account_id"], "the graph row must carry the target id"
      assert_equal "Frosty Tools", row["target_account_name"]
      assert row.key?("target_account_logo"), "the additive target logo key must be present"
      assert_equal @account.id, row["account_id"], "account_id stays the SOURCE bank (frozen)"

      # The response ships the dressed account's bank dialog: the REVERSE
      # (the sibling destroy form id) is rendered, the forward popup is
      # not (a dressed account cannot offer itself again).
      dialog = (json["chrome"]["bank_dialogs"] || []).find { |d| d["node_id"] == "bank:#{target.id}" }
      assert dialog, "the target account's bank dialog must be in the response"
      assert dialog["html"].include?("allocated_reverse_#{target.id}"),
        "the dressed account's dialog must render the REVERSE form"
      assert_not dialog["html"].include?("allocated_sub_form_#{target.id}"),
        "the dressed account's dialog must not offer the forward popup again"

      # Persistence: the row is a target row; the source bank field is
      # untouched.
      stored = @family.plan_allocations.find_by(name: "Frosty Tools")
      assert_equal target.id, stored.target_account_id
      assert_equal @account.id, stored.account_id
    end
  end

  test "create allocation with a dangling target account id is a 422 field error" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")

      post "/plan/flow/allocations", headers: { "Accept" => "application/json" }, params: {
        plan_allocation: { account_id: @account.id, name: "Ghost", kind: "savings",
                           mode: "required", value: "100.00",
                           target_account_id: "00000000-0000-0000-0000-000000000000" }
      }
      assert_response :unprocessable_entity
      errors = JSON.parse(response.body)["errors"]
      assert errors.key?("target_account"), "the 422 must carry the target_account field error"
      assert_nil @family.plan_allocations.find_by(name: "Ghost")
    end
  end

  test "a cross-family target account id is rejected" do
    other_account = families(:empty).accounts.create!(
      name: "Other Family Vault", balance: 0, currency: "USD",
      accountable: Depository.new
    )
    target = PlanAllocation.new(
      family: @family, account: @account, name: "Ghost", kind: "savings",
      mode: "required", value_cents: 100_000,
      target_account_id: other_account.id
    )
    refute target.valid?, "a target account outside the family must be invalid"
    assert target.errors[:target_account].any?
  end

  test "destroy of a target allocation unfreezes the dressed bank row" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")
      target = create_vault("Frosty Tools")
      row = PlanAllocation.create!(family: @family, account: @account, name: "Frosty Tools",
        kind: "savings", mode: "required", value_cents: 100_000, target_account: target)

      delete "/plan/flow/allocations/#{row.id}", headers: { "Accept" => "application/json" }
      assert_response :success
      json = JSON.parse(response.body)
      refute json["graph"]["allocations"].any? { |a| a["id"] == row.id },
        "the destroyed row must be gone from the graph"
      # The reverse ships the fresh bank dialog for the unfrozen account:
      # the forward action is back (forward popup form id rendered, the
      # reverse form gone).
      dialog = (json["chrome"]["bank_dialogs"] || []).find { |d| d["node_id"] == "bank:#{target.id}" }
      assert dialog, "the unfrozen account's bank dialog must be in the response"
      assert dialog["html"].include?("allocated_sub_form_#{target.id}")
      assert_not dialog["html"].include?("allocated_reverse_#{target.id}")
      assert_nil @family.plan_allocations.find_by(id: row.id)
    end
  end

  test "the bank-as-allocation recommendation skips a dressed account" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")
      bucket = create_vault("Snowbird Nest")
      bucket.update!(plan_role: "savings_bucket")

      get "/plan/flow/graph", headers: { "Accept" => "application/json" }
      assert_response :success
      recs_before = JSON.parse(response.body)["recommendations"]
      assert recs_before.any? { |r| r["type"] == "account" && r["account_id"] == bucket.id },
        "a role-labeled account with no allocation must be recommended"

      PlanAllocation.create!(family: @family, account: @account, name: "Snowbird Nest",
        kind: "savings", mode: "required", value_cents: 100_000, target_account: bucket)

      get "/plan/flow/graph", headers: { "Accept" => "application/json" }
      recs_after = JSON.parse(response.body)["recommendations"]
      refute recs_after.any? { |r| r["type"] == "account" && r["account_id"] == bucket.id },
        "a dressed account must not be recommended a second row"
    end
  end

  test "saving a target row from the allocation dialog keeps the dressed account" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")
      target = create_vault("Frosty Tools")
      row = PlanAllocation.create!(family: @family, account: @account, name: "Frosty Tools",
        kind: "savings", mode: "required", value_cents: 100_000, target_account: target)

      # The allocation dialog's hidden input carries the target id on
      # every save — an amount edit must not unfreeze the dressed row.
      patch "/plan/flow/allocations/#{row.id}", headers: { "Accept" => "application/json" }, params: {
        plan_allocation: { account_id: @account.id, name: "Frosty Tools", kind: "savings",
                           mode: "specific", value: "150.00",
                           target_account_id: target.id }
      }
      assert_response :success
      row.reload
      assert_equal target.id, row.target_account_id, "the dressed account must survive the edit"
      assert_equal 15_000, row.value_cents
    end
  end

  # creating an allocation that links a detected bill drops that
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

  # removing a bank keeps its allocations alive — they persist without a
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

  # removing a bank without allocations is the plain edge/marker drop.
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

  # (reported defect: deleting a bank left a blank "Account" row that survived
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

  # (sub-accounts + fan-out, backend): the bank config
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

    # The strict rule: the source only fans out to its own sub-accounts.
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

  # + : removing an account clears its OWN
  # sub-account link and its OWN fan-out targets (the semantics).
  # Setup note: the removed account must have no children of
  # its own — a fan-out target that is not its sub-account is only valid
  # when it funds that target as a dressed allocation (the model's
  # auto_transfer_targets_consistent rule).
  test "remove account clears the sub-account link and the fan-out targets" do
    parent = create_vault("Grand Vault")
    dressed = create_vault("Dressed Vault")
    PlanAllocation.create!(family: @family, account: @account, name: "Dressed",
      kind: "savings", mode: "required", value_cents: 100_000,
      target_account_id: dressed.id)
    @account.update!(parent_account_id: parent.id,
                     auto_transfer_target_ids: [ dressed.id.to_s ], plan_order: 1)

    delete "/plan/flow/accounts/#{@account.id}", headers: { "Accept" => "application/json" }
    assert_response :success

    account = @account.reload
    assert_nil account.parent_account_id
    assert_equal [], account.auto_transfer_target_ids
    # The dressed allocation persists without a source bank ( semantics).
    assert_nil PlanAllocation.find_by(target_account_id: dressed.id)&.account_id
  end

  # the removed account is the
  # SUB-ACCOUNT. Its parent link, its income edges, AND its entry in the
  # parent's auto_transfer_target_ids must all leave the plan in one
  # transaction — a lingering fan-out entry kept it drawn as a $0.00 bank
  # row while in_plan_account_ids dropped it (the invisible ghost row).
  test "removing a sub-account clears the parent link, the parent fan-out entry, and its income edges" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      child = create_vault("Baby Vault")
      sibling = create_vault("Pet Vault")
      child.update!(parent_account_id: @account.id)
      sibling.update!(parent_account_id: @account.id)
      @account.update!(auto_transfer_target_ids: [ sibling.id.to_s, child.id.to_s ], plan_order: 1)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: child, mode: "percent", value: 0.25)

      delete "/plan/flow/accounts/#{child.id}", headers: { "Accept" => "application/json" }
      assert_response :success
      json = JSON.parse(response.body)

      child = child.reload
      assert_nil child.parent_account_id
      assert_nil child.plan_order
      assert_not IncomeAccountAllocation.exists?(family: @family, account: child)
      # The parent's fan-out loses exactly the removed entry, order intact.
      assert_equal [ sibling.id.to_s ], @account.reload.auto_transfer_target_ids
      # The removed account leaves the graph banks entirely (no ghost row).
      assert_equal "bank:#{child.id}", json["chrome"]["bank_removed"]
      refute_includes json["graph"]["banks"].map { |b| b["id"] }, child.id
    end
  end

  # regression pin: the plain plan-ordered bank removal path is
  # unchanged — po/role/edges drop, its allocations persist unassigned, and
  # UNRELATED accounts' fan-out arrays are untouched (the new fan-out sync
  # is a no-op for them).
  test "removing a plain plan-ordered bank keeps the po-only semantics and other fan-outs intact" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")
      row = PlanAllocation.create!(family: @family, account: @account, name: "Bills",
        kind: "bill", mode: "required", value_cents: 50_000, cadence: "monthly")
      @account.update!(plan_order: 1, plan_role: "savings_bucket")

      other = create_vault("Other Bank")
      other_child = create_vault("Other Child")
      other_child.update!(parent_account_id: other.id)
      other.update!(auto_transfer_target_ids: [ other_child.id.to_s ], plan_order: 2)

      delete "/plan/flow/accounts/#{@account.id}", headers: { "Accept" => "application/json" }
      assert_response :success
      json = JSON.parse(response.body)

      account = @account.reload
      assert_nil account.plan_order
      assert_nil account.plan_role
      assert_not IncomeAccountAllocation.exists?(family: @family, account: @account)
      assert_nil row.reload.account_id
      assert_equal [ other_child.id.to_s ], other.reload.auto_transfer_target_ids
      refute_includes json["graph"]["banks"].map { |b| b["id"] }, @account.id
      assert_includes json["graph"]["banks"].map { |b| b["id"] }, other.id
    end
  end

  # guardrail: an account named by a target allocation is drawn
  # as its dressed allocation pillar; removing it would orphan that row.
  # 422 with the inline error; nothing is touched.
  test "removing an account named by a target allocation 422s and changes nothing" do
    dressed = create_vault("Dressed Savings")
    PlanAllocation.create!(family: @family, account: @account, name: "Dressed",
      kind: "savings", mode: "required", value_cents: 100_000,
      target_account_id: dressed.id)
    @account.update!(plan_order: 1)

    delete "/plan/flow/accounts/#{dressed.id}", headers: { "Accept" => "application/json" }
    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert json["errors"]["base"].any? { |m| m.include?(I18n.t("plan_flows.remove_account.has_target_allocation")) }, json

    # Nothing moved: the row still names the target, still sourced by the bank.
    row = PlanAllocation.find_by(target_account_id: dressed.id)
    assert_equal @account.id, row.account_id
    assert_equal 1, @account.reload.plan_order
    assert_nil dressed.reload.parent_account_id
  end

  # guardrail: an account with child sub-accounts would leave
  # those children pointing at a bank that left the plan. 422; nothing
  # touched (the parent keeps its order and its fan-out).
  test "removing an account with child sub-accounts 422s and changes nothing" do
    child = create_vault("Baby Vault")
    child.update!(parent_account_id: @account.id)
    @account.update!(auto_transfer_target_ids: [ child.id.to_s ], plan_order: 1)

    delete "/plan/flow/accounts/#{@account.id}", headers: { "Accept" => "application/json" }
    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert json["errors"]["base"].any? { |m| m.include?(I18n.t("plan_flows.remove_account.has_sub_accounts")) }, json

    account = @account.reload
    assert_equal 1, account.plan_order
    assert_equal [ child.id.to_s ], account.auto_transfer_target_ids
    assert_equal @account.id, child.reload.parent_account_id
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

  # the logo picker's hidden input saves through the
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

  # the allocation dialog saves a category through
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

  # the dialogs render the new fields — the
  # allocation dialog's category picker ( U: a radio list with the
  # same color + icon chip the house category lists use, because a native
  # select cannot render the icon + color) and the bank dialog's logo
  # picker (hidden slug input + the vendored logo list), J's existing
  # fields intact.
  test "dialogs render the category picker and the logo picker" do
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

      # Bank config dialog: the top-left avatar + logo popup
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

      # Allocation dialog (edit mode, U + 7b): the
      # category picker is a radio list carrying the family's categories,
      # each with the same color-mix icon chip the house category lists
      # use; the trigger IS the labeled row and carries its own icon chip
      # (neutral ? when the allocation is untagged — no color style).
      assert_select "dialog[data-node-id='allocation:#{allocation.id}']", 1 do
        assert_select "input[type=radio][name='plan_allocation[category_id]'][value='']", 1
        assert_select "input[type=radio][name='plan_allocation[category_id]'][value='#{category.id}']", 1
        assert_select "span[style*='#{category.color}']", 1
        assert_select "span[data-allocation-category-icon-chip]", 1
        assert_select "span[data-allocation-category-icon-chip][style]", count: 0
      end

      # category auto-fill — a linked bill's own
      # category is preselected when the allocation carries none (the
      # dialog reads allocation.category_id || recurring_transaction
      # .category_id): the trigger shows the category name + colored chip,
      # and the matching radio is checked server-side.
      water = RecurringTransaction.create!(
        family: @family, account: @account, name: "Water Utility", amount: 300,
        currency: "USD", expected_day_of_month: 9, status: "active",
        manual: true, bill_type: "bill",
        last_occurrence_date: Date.current, next_expected_date: Date.current,
        category_id: category.id)
      linked_row = PlanAllocation.create!(family: @family, account: @account, name: "Water Utility",
        kind: "bill", mode: "required", value_cents: 3_000, cadence: "monthly",
        recurring_transaction: water)
      get "/plan/flow"
      assert_response :success
      assert_select "dialog[data-node-id='allocation:#{linked_row.id}']", 1 do
        assert_select "input[type=radio][name='plan_allocation[category_id]'][value='#{category.id}'][checked]", 1
        assert_select "span[data-allocation-category-icon-chip][style*='#{category.color}']", 1
        assert_select "[data-allocation-category-selection]", text: category.display_name
      end
    end
  end

  # ---------------------------------------------------------------------
  # (T): the save bug + the progressive-disclosure rework.
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
        # save-bug fix: an unchecked browser checkbox sends NO
        # param, so the hidden empty sentinel (before the checkbox) is what
        # makes the controller see the row and destroy the edge.
        assert_select "input[type=hidden][name='links[#{series.id}][enabled]'][value='']", 1
        # Progressive disclosure: the hidden mode input (the trigger
        # button's submit carrier) sits inside the row's details wrapper
        # (visible because this row is checked).
        assert_select "[data-bank-row-details] input[type=hidden][name='links[#{series.id}][mode]']", 1
        # the kebab + the sub-account popup (the select is
        # unnamed; it syncs into the form's hidden input).
        assert_select "[data-bank-config-dialog-target=kebabMenu]", 1
        assert_select "[data-bank-config-dialog-target=subAccountPopup] [data-bank-config-dialog-target=subAccountSelect]", 1
        assert_select "[data-bank-config-dialog-target=subAccountSelect] option[value='']", 1
        # the auto-transfer popup with the checkbox box.
        assert_select "[data-bank-config-dialog-target=autoTransferPopup] [data-bank-config-dialog-target=autoTransferBox]", 1
        # exactly the five roles (plus the disabled Plain
        # placeholder while the role is nil).
        assert_select "select[name='account[plan_role]'] option[value=savings_bucket]", 1
        assert_select "select[name='account[plan_role]'] option[value=checking]", 1
        assert_select "select[name='account[plan_role]'] option[value=credit_card_payoff]", 1
        assert_select "select[name='account[plan_role]'] option[value=loan_payoff]", 1
        assert_select "select[name='account[plan_role]'] option[value=investment]", 1
        assert_select "select[name='account[plan_role]'] option[disabled][value='']", 1
        # heading + 20d avatar.
        assert_select "[data-bank-config-dialog-target=pullFrom]", 1
        assert_select "[data-bank-config-dialog-target=avatarImg]", 1
        assert_includes response.body, I18n.t("plan_flows.bank_config_dialog.pull_from_incomes")
        # ( -4): the "Details" disclosure is gone — ownership +
        # role stay always exposed, so no <details> element exists inside
        # the dialog at all and the ownership select is directly present.
        assert_select "details", 0
        assert_select "select[name='account[plan_ownership]']", 1
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

  # ---------------------------------------------------------------------
  # the restyled Pull-From-Incomes. The
  # per-income IAA rows stay the only store (persistence decision (a));
  # the client-side Ratio never reaches the server, so
  # save_bank_links is byte-identical — these pin the saved per-income
  # shapes the shared control set derives (Fixed/Equal, Percent/Rational,
  # Required/Leftover NULL, the single<->two transition, and the re-open
  # re-derivation of the ratio from the stored values).
  # ---------------------------------------------------------------------

  test "two-income Fixed/Equal save stores two specific rows summing to the total" do
    travel_to Date.new(2026, 11, 15) do
      primary = create_income_series(account: @account, name: "Primary Payroll", amount: 2700)
      secondary = create_income_series(account: @account, name: "Secondary Payroll", amount: 1400)

      # What the shared control set submits (mode Fixed Amount, Ratio
      # Equal, total 100.00): two per-paycheck specific rows of 50.00.
      patch_bank_links(links: {
        primary.id.to_s => { "enabled" => "1", "mode" => "specific", "value" => "50.00" },
        secondary.id.to_s => { "enabled" => "1", "mode" => "specific", "value" => "50.00" }
      })
      assert_response :success
      primary_edge = IncomeAccountAllocation.find_by(income_series_id: primary.id, account_id: @account.id)
      secondary_edge = IncomeAccountAllocation.find_by(income_series_id: secondary.id, account_id: @account.id)
      assert_in_delta 50.00, primary_edge.value.to_d, 0.0001
      assert_in_delta 50.00, secondary_edge.value.to_d, 0.0001

      # Re-open: the re-rendered dialog re-derives the shared state —
      # both rows checked, the shared block present, Ratio = Equal (equal
      # dollars within 1c).
      json = JSON.parse(response.body)
      html = json["chrome"]["bank_dialogs"].find { |d| d["node_id"] == "bank:#{@account.id}" }["html"]
      assert_includes html, "data-bank-pull-from-shared"
      assert_includes html, 'data-bank-pull-from-ratio="equal"'
      assert_includes html, "checked"

      # ( -1): the shared block renders BELOW both income rows
      # (after row 2) — the placement change from -3's
      # between-the-rows — with the grey Mode / Split Behavior labels and
      # the option labels (50/50 / Proportional Split / Fixed
      # Amounts; the radio values stay equal/rational/fixed_amounts).
      shared_at = html.index("data-bank-pull-from-shared")
      primary_row_at = html.index("data-bank-series-id=\"#{primary.id}\"")
      secondary_row_at = html.index("data-bank-series-id=\"#{secondary.id}\"")
      assert shared_at, "shared block missing from re-rendered dialog"
      assert primary_row_at < secondary_row_at, "income row 1 must come before income row 2"
      assert secondary_row_at < shared_at, "shared block must come below both income rows (R29-1)"
      assert_includes html, "Split Behavior"
      assert_includes html, ">Mode<"
      # The 50/50 re-derivation lands in the behavior trigger label, and
      # all three labels are present (trigger + the two panel radio
      # labels).
      assert_includes html, ">50/50<"
      assert_includes html, "Proportional Split"
      # The behavior trigger is server-visible in the Fixed/Equal state
      # (the shared_ratio_shown), with the split icon.
      assert_not html.match?(/flex-wrap hidden" data-bank-pull-ratio-wrap/),
        "ratio wrap must not be hidden in the Fixed/Equal state"
      # The per-row split inputs live inline in the income rows (the old
      # bottom-center split wrap is gone).
      assert_includes html, "data-bank-split-input=\"#{primary.id}\""
      assert_includes html, "data-bank-split-input=\"#{secondary.id}\""
      assert_not_includes html, "data-bank-pull-split-wrap"
      # -4: the always-exposed details panel.
      assert_includes html, 'class="bg-surface-inset rounded-xl p-3"'
    end
  end

  test "two-income Percent/Rational save stores two percent rows" do
    travel_to Date.new(2026, 11, 15) do
      primary = create_income_series(account: @account, name: "Primary Payroll", amount: 2700)
      secondary = create_income_series(account: @account, name: "Secondary Payroll", amount: 1400)

      # Ratio Rational (the default): each income stores the SAME 10.00
      # percent (each pays 10% of its own paycheck) — the 0.10 fraction.
      patch_bank_links(links: {
        primary.id.to_s => { "enabled" => "1", "mode" => "percent", "value" => "10.00" },
        secondary.id.to_s => { "enabled" => "1", "mode" => "percent", "value" => "10.00" }
      })
      assert_response :success
      primary_edge = IncomeAccountAllocation.find_by(income_series_id: primary.id, account_id: @account.id)
      secondary_edge = IncomeAccountAllocation.find_by(income_series_id: secondary.id, account_id: @account.id)
      assert_in_delta 0.10, primary_edge.value.to_d, 0.0001
      assert_in_delta 0.10, secondary_edge.value.to_d, 0.0001

      # Re-open re-derives Ratio = Rational (equal fractions).
      json = JSON.parse(response.body)
      html = json["chrome"]["bank_dialogs"].find { |d| d["node_id"] == "bank:#{@account.id}" }["html"]
      assert_includes html, 'data-bank-pull-from-ratio="rational"'
    end
  end

  test "Required and Leftover store value NULL (mixed stored modes lock the ratio)" do
    travel_to Date.new(2026, 11, 15) do
      primary = create_income_series(account: @account, name: "Primary Payroll", amount: 2700)
      secondary = create_income_series(account: @account, name: "Secondary Payroll", amount: 1400)

      # Required + leftover carry no value (the planner derives them);
      # the stored values must be NULL (the DB check enforces it too).
      patch_bank_links(links: {
        primary.id.to_s => { "enabled" => "1", "mode" => "required", "value" => "" },
        secondary.id.to_s => { "enabled" => "1", "mode" => "leftover", "value" => "" }
      })
      assert_response :success
      primary_edge = IncomeAccountAllocation.find_by(income_series_id: primary.id, account_id: @account.id)
      secondary_edge = IncomeAccountAllocation.find_by(income_series_id: secondary.id, account_id: @account.id)
      assert_nil primary_edge.value
      assert_nil secondary_edge.value

      # Mixed stored modes (required + leftover): the re-rendered shared
      # block is locked to the Fixed Amounts ratio.
      json = JSON.parse(response.body)
      html = json["chrome"]["bank_dialogs"].find { |d| d["node_id"] == "bank:#{@account.id}" }["html"]
      assert_includes html, 'data-bank-pull-from-ratio="fixed_amounts"'
    end
  end

  test "two-income Fixed Amounts save stores unequal dollars and re-derives the behavior" do
    travel_to Date.new(2026, 11, 15) do
      primary = create_income_series(account: @account, name: "Primary Payroll", amount: 2700)
      secondary = create_income_series(account: @account, name: "Secondary Payroll", amount: 1400)

      # ( -3): Fixed Amount + Fixed Amounts — the two inline
      # per-row inputs (80.00 / 20.00, unequal and not income-proportional)
      # submit as the per-paycheck specific rows; the re-derivation on
      # re-open must land on fixed_amounts.
      patch_bank_links(links: {
        primary.id.to_s => { "enabled" => "1", "mode" => "specific", "value" => "80.00" },
        secondary.id.to_s => { "enabled" => "1", "mode" => "specific", "value" => "20.00" }
      })
      assert_response :success
      primary_edge = IncomeAccountAllocation.find_by(income_series_id: primary.id, account_id: @account.id)
      secondary_edge = IncomeAccountAllocation.find_by(income_series_id: secondary.id, account_id: @account.id)
      assert_in_delta 80.00, primary_edge.value.to_d, 0.0001
      assert_in_delta 20.00, secondary_edge.value.to_d, 0.0001

      json = JSON.parse(response.body)
      html = json["chrome"]["bank_dialogs"].find { |d| d["node_id"] == "bank:#{@account.id}" }["html"]
      assert_includes html, 'data-bank-pull-from-ratio="fixed_amounts"'
      assert_includes html, ">Fixed Amounts<"
      # The inline per-row inputs pre-fill from the stored values.
      assert html.match?(/value="80\.00"[^>]*data-bank-split-input="#{primary.id}"/),
        "Primary inline split input must pre-fill 80.00"
      assert html.match?(/value="20\.00"[^>]*data-bank-split-input="#{secondary.id}"/),
        "Secondary inline split input must pre-fill 20.00"
    end
  end

  test "two-income Required/Required renders the shared block with hidden ratio (round 28)" do
    travel_to Date.new(2026, 11, 15) do
      primary = create_income_series(account: @account, name: "Primary Payroll", amount: 2700)
      secondary = create_income_series(account: @account, name: "Secondary Payroll", amount: 1400)

      # Both incomes required, nil stored percents: re-derives the
      # equal split (the dataset carries "equal"; the ratio is still never
      # submitted).
      patch_bank_links(links: {
        primary.id.to_s => { "enabled" => "1", "mode" => "required", "value" => "" },
        secondary.id.to_s => { "enabled" => "1", "mode" => "required", "value" => "" }
      })
      assert_response :success
      primary_edge = IncomeAccountAllocation.find_by(income_series_id: primary.id, account_id: @account.id)
      secondary_edge = IncomeAccountAllocation.find_by(income_series_id: secondary.id, account_id: @account.id)
      assert_nil primary_edge.value
      assert_nil secondary_edge.value

      json = JSON.parse(response.body)
      html = json["chrome"]["bank_dialogs"].find { |d| d["node_id"] == "bank:#{@account.id}" }["html"]
      assert_includes html, "data-bank-pull-from-shared"
      assert_includes html, 'data-bank-pull-from-ratio="equal"'
    end
  end

  test "single<->two income transition round-trips (edges are the only store)" do
    travel_to Date.new(2026, 11, 15) do
      primary = create_income_series(account: @account, name: "Primary Payroll", amount: 2700)
      secondary = create_income_series(account: @account, name: "Secondary Payroll", amount: 1400)

      # Start: one income (required), the other unchecked (the sentinel
      # submits enabled="" and destroys/creates nothing).
      patch_bank_links(links: {
        primary.id.to_s => { "enabled" => "1", "mode" => "required" },
        secondary.id.to_s => { "enabled" => "" }
      })
      assert_response :success
      assert IncomeAccountAllocation.exists?(income_series_id: primary.id, account_id: @account.id, mode: "required")
      assert_not IncomeAccountAllocation.exists?(income_series_id: secondary.id, account_id: @account.id)

      # One -> two: both checked, Fixed/Equal 50.00 each — the Primary edge
      # upserts required -> specific, the Secondary edge is created.
      patch_bank_links(links: {
        primary.id.to_s => { "enabled" => "1", "mode" => "specific", "value" => "50.00" },
        secondary.id.to_s => { "enabled" => "1", "mode" => "specific", "value" => "50.00" }
      })
      assert_response :success
      assert IncomeAccountAllocation.exists?(income_series_id: primary.id, account_id: @account.id, mode: "specific")
      assert IncomeAccountAllocation.exists?(income_series_id: secondary.id, account_id: @account.id, mode: "specific")
      # The re-rendered dialog shows the fresh shared state (both checked,
      # Equal re-derived from the stored values).
      json = JSON.parse(response.body)
      html = json["chrome"]["bank_dialogs"].find { |d| d["node_id"] == "bank:#{@account.id}" }["html"]
      assert_includes html, 'data-bank-pull-from-ratio="equal"'

      # Two -> one: uncheck Primary (the sentinel submits enabled=""), keep
      # Secondary at its stored value — the Primary edge is destroyed.
      patch_bank_links(links: {
        primary.id.to_s => { "enabled" => "" },
        secondary.id.to_s => { "enabled" => "1", "mode" => "specific", "value" => "50.00" }
      })
      assert_response :success
      assert_not IncomeAccountAllocation.exists?(income_series_id: primary.id, account_id: @account.id)
      assert IncomeAccountAllocation.exists?(income_series_id: secondary.id, account_id: @account.id, mode: "specific")
    end
  end

  # ---------------------------------------------------------------------
  # fixes (controller-render + save-path coverage).
  # ---------------------------------------------------------------------

  test "the bank dialog required display renders dollars, not cents (R5 BUG-1)" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "required")
      # $5,000.00/month required over the two November paychecks:
      # per-paycheck 2,500.00 in the paycheck view, 5,000.00 monthly.
      # Pre-fix the attribute carried the raw cents ("250000.00").
      PlanAllocation.create!(family: @family, account: @account, name: "Huge Bill",
        kind: "bill", mode: "required", value_cents: 500_000, cadence: "monthly")

      get "/plan/flow"

      assert_response :success
      assert_select "dialog[data-node-id='bank:#{@account.id}'] [data-bank-config-dialog-target=pullFrom][data-bank-required-display='2500.00']", 1

      get "/plan/flow", params: { view: "monthly" }
      assert_response :success
      assert_select "dialog[data-node-id='bank:#{@account.id}'] [data-bank-config-dialog-target=pullFrom][data-bank-required-display='5000.00']", 1
    end
  end

  # ---------------------------------------------------------------------
  # fixes (controller context + dialog JS).
  # ---------------------------------------------------------------------

  test "the bank dialog required display falls back to the linked-income proration with no required edge (R28B BUG-B)" do
    travel_to Date.new(2026, 11, 15) do
      primary = create_income_series(account: @account, name: "Primary Payroll", amount: 2700)
      secondary = create_income_series(account: @account, name: "Secondary Payroll", amount: 1400)
      # Third Secondary paycheck this month (the fallback divisor is the
      # AVERAGE paychecks per month of the linked incomes: (2 + 3) / 2 = 2.5).
      secondary.recurring_occurrences.create!(family: @family, due_on: Date.new(2026, 11, 27),
        original_due_on: Date.new(2026, 11, 27), currency: "USD", expected_amount: 1400,
        status: "scheduled")
      # The bank's required base (its allocation required amount) with NO
      # required income edge: the pre-fix context nilled the display
      # (required_edge_funding_counts == 0), so the live Required
      # transition showed "—" in the inputs and $0.00 in the readouts.
      PlanAllocation.create!(family: @family, account: @account, name: "Loan Payment",
        kind: "bill", mode: "required", value_cents: 25_000, cadence: "monthly")
      # Both incomes linked as specific (the saved non-required state).
      IncomeAccountAllocation.create!(family: @family, income_series: primary,
        account: @account, mode: "specific", value: 62.50)
      IncomeAccountAllocation.create!(family: @family, income_series: secondary,
        account: @account, mode: "specific", value: 62.50)

      # Fallback: 25,000 cents / 2.5 paychecks = 10,000 cents = 100.00
      # per paycheck (250.00 in the monthly view — no funding gate there).
      get "/plan/flow"
      assert_response :success
      assert_select "dialog[data-node-id='bank:#{@account.id}'] [data-bank-config-dialog-target=pullFrom][data-bank-required-display='100.00']", 1

      get "/plan/flow", params: { view: "monthly" }
      assert_response :success
      assert_select "dialog[data-node-id='bank:#{@account.id}'] [data-bank-config-dialog-target=pullFrom][data-bank-required-display='250.00']", 1

      # fix-round (BUG- -1): the stored-required-edge path now
      # uses the SAME average divisor as the fallback (the composite
      # paycheck): (Primary 2 + Secondary 3) / 2 = 2.5 -> 25,000/2.5 = 100.00,
      # not the pre-fix required-edge sum (Primary 2 -> 125.00). Display-only:
      # the planner still settles over the edge sum (D-RECON).
      IncomeAccountAllocation.find_by!(income_series_id: primary.id, account_id: @account.id)
                            .update!(mode: "required", value: nil)
      get "/plan/flow"
      assert_response :success
      assert_select "dialog[data-node-id='bank:#{@account.id}'] [data-bank-config-dialog-target=pullFrom][data-bank-required-display='100.00']", 1
    end
  end

  test "the shared-mode panel renders with four mode radios (R5 BUG-2)" do
    travel_to Date.new(2026, 11, 15) do
      primary = create_income_series(account: @account, name: "Primary Payroll", amount: 2700)
      secondary = create_income_series(account: @account, name: "Secondary Payroll", amount: 1400)
      IncomeAccountAllocation.create!(family: @family, income_series: primary,
        account: @account, mode: "required")
      IncomeAccountAllocation.create!(family: @family, income_series: secondary,
        account: @account, mode: "required")

      get "/plan/flow"

      assert_response :success
      dialog = "dialog[data-node-id='bank:#{@account.id}']"
      # before this fix the trigger had no panel at all (openPullPanel
      # found nothing and returned) — all four mode radios must exist.
      %w[required specific percent leftover].each do |mode|
        assert_select "#{dialog} [data-bank-pull-panel][data-bank-pull-panel-group='shared-mode'] input[type=radio][value=#{mode}]", 1
      end
    end
  end

  test "the shared-mode label renders real text, never a missing key (R5 BUG-3)" do
    travel_to Date.new(2026, 11, 15) do
      primary = create_income_series(account: @account, name: "Primary Payroll", amount: 2700)
      secondary = create_income_series(account: @account, name: "Secondary Payroll", amount: 1400)
      dialog = "dialog[data-node-id='bank:#{@account.id}']"

      # Nil case: one checked income (the shared block is hidden) used to
      # render t(".mode_") -> "translation missing: ... mode_".
      IncomeAccountAllocation.create!(family: @family, income_series: primary,
        account: @account, mode: "required")
      get "/plan/flow"
      assert_response :success
      assert_select "#{dialog} [data-bank-pull-shared-mode-label]", text: "Required"

      # Stored-mode case: two required edges -> shared_mode "required".
      IncomeAccountAllocation.create!(family: @family, income_series: secondary,
        account: @account, mode: "required")
      get "/plan/flow"
      assert_response :success
      assert_select "#{dialog} [data-bank-pull-shared-mode-label]", text: "Required"
      assert_no_match(/translation missing/, response.body[/<span[^>]*data-bank-pull-shared-mode-label[^>]*>.*?<\/span>/m] || "")
    end
  end

  test "a 422 rejected bank-links save returns real error messages (R5 BUG-7)" do
    travel_to Date.new(2026, 11, 15) do
      primary = create_income_series(account: @account, name: "Primary Payroll", amount: 2700)

      # specific with a blank value fails the allocation's numericity
      # validation; pre-fix the 422 body was {"errors":{}} (zero client
      # feedback).
      patch_bank_links(links: {
        primary.id.to_s => { "enabled" => "1", "mode" => "specific", "value" => "   " }
      })
      assert_response :unprocessable_entity
      json = JSON.parse(response.body)
      errors = json["errors"]
      assert errors.is_a?(Hash) && !errors.empty?, "expected non-empty errors, got #{json.inspect}"
      assert_includes errors.fetch("value", []).join(" "), "must be greater than 0"
      # Nothing persisted: the rejected save left no edge behind.
      assert_not IncomeAccountAllocation.exists?(income_series_id: primary.id, account_id: @account.id)
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

  # ---------------------------------------------------------------------
  # the context-aware kebab matrix
  # ("Make Parent Account" context labels, Auto-Transfer LAST), the
  # main-section "Parent Account" labeled row + picker, the MOVE semantics
  # (make-allocated keeps the parent link), and the in-place staleness
  # ship-sets (source / old / new parents ship fresh dialogs).
  # ---------------------------------------------------------------------

  # The kebab menu items of one bank dialog, in DOM order, as
  # [ text, type, form ] tuples. The matrix labels ALSO appear in the
  # header popups (the popup titles reuse them), so a whole-page text
  # search is unreliable — parse the dialog's own kebabMenu element.
  def kebab_menu_items(doc, account_id)
    dialog = doc.at_css("dialog[data-node-id='bank:#{account_id}']")
    assert dialog, "the bank dialog must render for #{account_id.to_s[0, 8]}"
    dialog.at_css("[data-bank-config-dialog-target=kebabMenu]")
         .css("button")
         .map { |b| [ b.text.strip, b["type"].to_s, b["form"].to_s ] }
  end

  test "kebab matrix: the item set and order per context state (round 26 R2)" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      child = create_vault("Baby Vault")     # the SUB state (parent, no target)
      dressed = create_vault("Pet Vault")    # the DRESSED state (target, no parent)
      both = create_vault("Both Vault")      # the DRESSED+PARENT state
      @account.update!(plan_order: 1)
      child.update!(plan_order: 2)
      dressed.update!(plan_order: 3)
      both.update!(plan_order: 4)
      child.update!(parent_account_id: @account.id)
      both.update!(parent_account_id: @account.id)
      PlanAllocation.create!(family: @family, account: @account, name: "Pet Bucket",
        kind: "savings", mode: "required", value_cents: 100_000, target_account: dressed)
      PlanAllocation.create!(family: @family, account: @account, name: "Both Bucket",
        kind: "savings", mode: "required", value_cents: 100_000, target_account: both)

      get "/plan/flow"
      assert_response :success
      doc = Nokogiri::HTML.parse(response.body)
      make_sub = I18n.t("plan_flows.bank_config_dialog.menu_make_sub_account")
      make_parent = I18n.t("plan_flows.bank_config_dialog.make_parent_account")
      make_allocated = I18n.t("plan_flows.bank_config_dialog.menu_make_allocated_sub_account")
      auto_transfer = I18n.t("plan_flows.bank_config_dialog.menu_configure_auto_transfer")

      # Normal bank (no parent, no target): the three items,
      # Auto-Transfer LAST (item 5: not in the middle).
      assert_equal [
        [ make_sub, "button", "" ],
        [ make_allocated, "button", "" ],
        [ auto_transfer, "button", "" ]
      ], kebab_menu_items(doc, @account.id)

      # Sub (parent present, no target): slot 1 flips to "Make Parent
      # Account" (it opens the EXISTING sub-account popup, whose
      # "Not a sub-account" entry clears the link).
      assert_equal [
        [ make_parent, "button", "" ],
        [ make_allocated, "button", "" ],
        [ auto_transfer, "button", "" ]
      ], kebab_menu_items(doc, child.id)

      # Dressed (target present, no parent): TWO items — the REVERSE
      # (a submit of the existing destroy form, no popup) + auto-transfer;
      # no forward "Make Allocated" offer.
      assert_equal [
        [ make_parent, "submit", "allocated_reverse_#{dressed.id}" ],
        [ auto_transfer, "button", "" ]
      ], kebab_menu_items(doc, dressed.id)

      # Dressed+parent: BOTH "Make Parent Account" items (slot 1 clears
      # the link through the popup, slot 2 destroys the target) +
      # auto-transfer — two adjacent items sharing a label is the
      # the accepted reading.
      assert_equal [
        [ make_parent, "button", "" ],
        [ make_parent, "submit", "allocated_reverse_#{both.id}" ],
        [ auto_transfer, "button", "" ]
      ], kebab_menu_items(doc, both.id)
    end
  end

  test "Make Parent Account on a sub: the popup's clear path drops the link (round 26 R2)" do
    child = create_vault("Baby Vault")
    @account.update!(plan_order: 1)
    child.update!(plan_order: 2)

    travel_to Date.new(2026, 11, 15) do
      # Link the sub-account (the popup's Save posts this exact hash).
      patch "/plan/flow/accounts/#{child.id}", headers: { "Accept" => "application/json" }, params: {
        account: { plan_ownership: "shared", plan_role: "", bank_logo_slug: "",
                   parent_account_id: @account.id }
      }
      assert_response :success
      assert_equal [ child.id.to_s ], @account.reload.auto_transfer_target_ids,
        "the fan-out sync must add the child to the new parent"

      # The sub-state dialog: slot 1 is "Make Parent Account", and the
      # main-section Parent Account row renders (label + the picker with
      # the current parent selected).
      get "/plan/flow"
      doc = Nokogiri::HTML.parse(response.body)
      assert_equal I18n.t("plan_flows.bank_config_dialog.make_parent_account"),
                   kebab_menu_items(doc, child.id)[0][0]
      assert_select "dialog[data-node-id='bank:#{child.id}'] [data-bank-config-dialog-target=parentRow]", 1

      # The popup's "Not a sub-account" posts an empty value -> the link
      # clears and the old parent's fan-out row drops (the existing
      # validate_parent_change path, now reached via the matrix label).
      patch "/plan/flow/accounts/#{child.id}", headers: { "Accept" => "application/json" }, params: {
        account: { plan_ownership: "shared", plan_role: "", bank_logo_slug: "",
                   parent_account_id: "" }
      }
      assert_response :success
      assert_nil child.reload.parent_account_id
      assert_equal [], @account.reload.auto_transfer_target_ids

      # Slot 1 flips back to "Make a Sub-Account".
      get "/plan/flow"
      assert_equal I18n.t("plan_flows.bank_config_dialog.menu_make_sub_account"),
                   kebab_menu_items(Nokogiri::HTML.parse(response.body), child.id)[0][0]
    end
  end

  test "Make Parent Account on a dressed account: the reverse destroys the target, parent intact (round 26 R2)" do
    child = create_vault("Baby Vault")
    @account.update!(plan_order: 1)
    child.update!(plan_order: 2, parent_account_id: @account.id)
    row = PlanAllocation.create!(family: @family, account: @account, name: "Baby Bucket",
      kind: "savings", mode: "required", value_cents: 100_000, target_account: child)

    delete "/plan/flow/allocations/#{row.id}", headers: { "Accept" => "application/json" }
    assert_response :success
    json = JSON.parse(response.body)
    refute json["graph"]["allocations"].any? { |a| a["id"] == row.id },
      "the target allocation must be gone from the graph"
    assert_equal @account.id, child.reload.parent_account_id,
      "the reverse touches only the allocation — the parent link survives"

    # The account's row returns: the response ships the account's fresh
    # dialog with the FORWARD item back and the reverse form gone.
    dialogs = json["chrome"]["bank_dialogs"] || []
    target_dialog = dialogs.find { |d| d["node_id"] == "bank:#{child.id}" }
    assert target_dialog, "the unfrozen account's dialog must ship"
    assert target_dialog["html"].include?("allocated_sub_form_#{child.id}")
    assert_not target_dialog["html"].include?("allocated_reverse_#{child.id}")
    # staleness: the SOURCE bank's holder ships too (its
    # Remove allocated_count changed).
    assert dialogs.any? { |d| d["node_id"] == "bank:#{@account.id}" },
      "the source bank's dialog must ship on a target destroy"
  end

  test "Parent Account row + picker: render, re-parent 200, and the 422 contract (round 26 R2)" do
    child = create_vault("Baby Vault")
    other = create_vault("Savings B")
    @account.update!(plan_order: 1)
    child.update!(plan_order: 2, parent_account_id: @account.id)

    travel_to Date.new(2026, 11, 15) do
      get "/plan/flow"
      assert_response :success
      assert_select "dialog[data-node-id='bank:#{child.id}'] [data-bank-config-dialog-target=parentRow]", 1 do
        # The label shows the parent's name.
        assert_select "span", text: @account.name
        # The picker: top-level family accounts only, excluding self —
        # the current parent selected.
        assert_select "[data-bank-config-dialog-target=mainParentSelect] option[value='#{@account.id}'][selected]", 1
        assert_select "[data-bank-config-dialog-target=mainParentSelect] option[value='#{other.id}']", 1
        assert_select "[data-bank-config-dialog-target=mainParentSelect] option[value='#{child.id}']", 0
      end
      # No row for a parentless account.
      assert_select "dialog[data-node-id='bank:#{@account.id}'] [data-bank-config-dialog-target=parentRow]", 0
    end

    # Re-parent through the picker's hidden-input contract (the form's
    # Save posts parent_account_id = the new top-level account).
    patch "/plan/flow/accounts/#{child.id}", headers: { "Accept" => "application/json" }, params: {
      account: { plan_ownership: "shared", plan_role: "", bank_logo_slug: "",
                 parent_account_id: other.id }
    }
    assert_response :success
    assert_equal other.id, child.reload.parent_account_id
    assert_includes other.reload.auto_transfer_target_ids, child.id.to_s,
      "the fan-out sync must add the child to the NEW parent"
    assert_not_includes @account.reload.auto_transfer_target_ids, child.id.to_s,
      "the fan-out sync must drop the child from the OLD parent"
    # staleness: the child + the OLD and NEW parents all ship
    # fresh dialogs (the cosmetic note — the new parent's dialog used
    # to lag one reload).
    json = JSON.parse(response.body)
    node_ids = (json["chrome"]["bank_dialogs"] || []).map { |d| d["node_id"] }
    assert_includes node_ids, "bank:#{child.id}"
    assert_includes node_ids, "bank:#{@account.id}"
    assert_includes node_ids, "bank:#{other.id}"

    # 422 contract (the picker offers only top-level candidates, but the
    # server enforces): self.
    patch "/plan/flow/accounts/#{child.id}", headers: { "Accept" => "application/json" }, params: {
      account: { parent_account_id: child.id }
    }
    assert_response :unprocessable_entity
    assert JSON.parse(response.body)["errors"]["parent_account"].any? { |m| m.include?("itself") }
    assert_equal other.id, child.reload.parent_account_id, "a 422 must not move the link"

    # 422 contract: the account has its own sub-accounts. (A SEPARATE
    # account: while `child` is linked below it cannot gain children of
    # its own — the model's depth-1 rule blocks that save.)
    child2 = create_vault("Kid Vault")
    child2.update!(plan_order: 5)
    grandchild = create_vault("Grand Vault")
    grandchild.update!(parent_account_id: child2.id)
    patch "/plan/flow/accounts/#{child2.id}", headers: { "Accept" => "application/json" }, params: {
      account: { parent_account_id: @account.id }
    }
    assert_response :unprocessable_entity
    assert JSON.parse(response.body)["errors"]["parent_account"].any? { |m| m.include?("sub-accounts of its own") }
    assert_nil child2.reload.parent_account_id, "a 422 must not move the link"
  end

  test "MOVE: make-allocated on a sub-account creates the target and keeps the parent (round 26 R2)" do
    child = create_vault("Baby Vault")
    @account.update!(plan_order: 1)
    child.update!(plan_order: 2, parent_account_id: @account.id)

    travel_to Date.new(2026, 11, 15) do
      # Exactly what the allocated-sub popup posts (source = the parent,
      # pre-checked by the dialog's default).
      post "/plan/flow/allocations", headers: { "Accept" => "application/json" }, params: {
        plan_allocation: { account_id: @account.id, name: "Baby Bucket", kind: "savings",
                           mode: "required", value: "100.00",
                           target_account_id: child.id }
      }
      assert_response :success
      stored = @family.plan_allocations.find_by(name: "Baby Bucket")
      assert_equal child.id, stored.target_account_id
      assert_equal @account.id, child.reload.parent_account_id,
        "the MOVE: the target allocation is created and the parent link STAYS"

      # The response ships the target's fresh dialog (the kebab flips to
      # the REVERSE) AND the source bank's dialog (its Remove count
      # changed) — and the dressed+parent dialog renders both "Make Parent
      # Account" items.
      json = JSON.parse(response.body)
      dialogs = json["chrome"]["bank_dialogs"] || []
      assert dialogs.any? { |d| d["node_id"] == "bank:#{@account.id}" },
        "the source bank's dialog must ship on a target create"
      target_dialog = dialogs.find { |d| d["node_id"] == "bank:#{child.id}" }
      assert target_dialog, "the target account's dialog must ship"
      assert target_dialog["html"].include?("allocated_reverse_#{child.id}")
      labels = kebab_menu_items(Nokogiri::HTML.parse(target_dialog["html"]), child.id).map { |i| i[0] }
      assert_equal [
        I18n.t("plan_flows.bank_config_dialog.make_parent_account"),
        I18n.t("plan_flows.bank_config_dialog.make_parent_account"),
        I18n.t("plan_flows.bank_config_dialog.menu_configure_auto_transfer")
      ], labels
    end
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
    # column holds an empty array (the ERB's Array render sees no rows).
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

  # ---------------------------------------------------------------------
  # the required split. The REQUIRED-mode split is PERSISTED as
  # percents of the bank's required amount (2 dp major units) on the
  # income_account_allocations value; nil = the equal split = today.
  # - pin the dialog readouts/seeding and the save contract.
  # ---------------------------------------------------------------------

  def r30_required_base(cents)
    @family.plan_allocations.create!(
      family: @family, account: @account, name: "Required", kind: "bill",
      mode: "required", value_cents: cents, cadence: "monthly"
    )
  end

  # stored percents 75/25 with a $100.00 displayed required seed the
  # greyed readouts that sum exactly to the displayed required, re-open as
  # the Percent behavior, and seed the visible % inputs.
  test "required split: stored percents seed the readouts summing to the required (C1)" do
    travel_to Date.new(2026, 11, 15) do
      primary = create_income_series(account: @account, name: "Primary Payroll", amount: 2700)
      secondary = create_income_series(account: @account, name: "Secondary Payroll", amount: 1400)
      IncomeAccountAllocation.create!(family: @family, income_series: primary,
        account: @account, mode: "required", value: 75.00)
      IncomeAccountAllocation.create!(family: @family, income_series: secondary,
        account: @account, mode: "required", value: 25.00)
      # $200/mo over the AVERAGE 2 paychecks per linked income (2 linked
      # incomes x 2 occurrences; BUG- -1: the divisor is the average, not
      # the 4-edge sum) -> $100.00/paycheck.
      r30_required_base(20_000)

      get "/plan/flow"

      assert_response :success
      assert_includes response.body, %(data-bank-required-display="100.00")
      # 75% / 25% of the displayed $100.00 — the readouts sum exactly to it.
      assert_includes response.body, "Primary Payroll: $75.00"
      assert_includes response.body, "Secondary Payroll: $25.00"
      # D-REOPEN: 75/25 is neither equal (50/50 +/- 1c) nor strict
      # proportional (65.85/34.15 +/- 1c) -> the Percent behavior re-opens,
      # with the 4th option checked + enabled and the % inputs seeded.
      assert_includes response.body, %(data-bank-pull-from-ratio="percent")
      assert_select "dialog[data-node-id='bank:#{@account.id}'] [data-bank-pull-panel-group='shared-ratio'] input[type=radio][value=percent][checked]"
      assert_select "input[data-bank-split-input='#{primary.id}'][value='75.00']"
      assert_select "input[data-bank-split-input='#{secondary.id}'][value='25.00']"
      # The percents ride the existing [value] carrier.
      assert_select "input[type=hidden][name='links[#{primary.id}][value]'][value='75.00']"
      assert_select "input[type=hidden][name='links[#{secondary.id}][value]'][value='25.00']"
    end
  end

  # all-nil stored percents re-open as the equal split — the greyed
  # readouts are 50% of the displayed required each.
  test "required split: nil percents re-open as the equal split readouts (C2)" do
    travel_to Date.new(2026, 11, 15) do
      primary = create_income_series(account: @account, name: "Primary Payroll", amount: 2700)
      secondary = create_income_series(account: @account, name: "Secondary Payroll", amount: 1400)
      IncomeAccountAllocation.create!(family: @family, income_series: primary,
        account: @account, mode: "required")
      IncomeAccountAllocation.create!(family: @family, income_series: secondary,
        account: @account, mode: "required")
      r30_required_base(20_000) # $200/mo over the average 2 paychecks -> $100.00 display (BUG-R30-1 divisor)

      get "/plan/flow"

      assert_response :success
      assert_includes response.body, %(data-bank-required-display="100.00")
      assert_includes response.body, "Primary Payroll: $50.00"
      assert_includes response.body, "Secondary Payroll: $50.00"
      assert_includes response.body, %(data-bank-pull-from-ratio="equal")
      # Nil stored percents: the carriers stay blank server-side (nil = the
      # equal split); the JS recalc seeds the 50.00/50.00 split client-side
      # on connect.
      assert_select "input[type=hidden][name='links[#{primary.id}][value]'][value='']"
      assert_select "input[type=hidden][name='links[#{secondary.id}][value]'][value='']"
    end
  end

  # the behavior dataset re-derivation (D-REOPEN) for required —
  # strict-proportional stored percents -> rational; custom -> percent;
  # nil -> equal.
  test "required split: the dataset seed re-derives the behavior (C3)" do
    travel_to Date.new(2026, 11, 15) do
      primary = create_income_series(account: @account, name: "Primary Payroll", amount: 2700)
      secondary = create_income_series(account: @account, name: "Secondary Payroll", amount: 1400)
      primary_edge = IncomeAccountAllocation.create!(family: @family, income_series: primary,
        account: @account, mode: "required")
      secondary_edge = IncomeAccountAllocation.create!(family: @family, income_series: secondary,
        account: @account, mode: "required")
      r30_required_base(20_000) # $200/mo over the average 2 paychecks -> $100.00 display (BUG-R30-1 divisor)

      # (a) 65.85 / 34.15 at 2700/1400 is the strict proportional split
      # (100 * 2700/4100 = 65.8536...) within 1c of both -> rational.
      primary_edge.update!(value: 65.85)
      secondary_edge.update!(value: 34.15)
      get "/plan/flow"
      assert_response :success
      assert_includes response.body, %(data-bank-pull-from-ratio="rational")

      # (b) 75 / 25 is custom -> percent.
      primary_edge.update!(value: 75.00)
      secondary_edge.update!(value: 25.00)
      get "/plan/flow"
      assert_response :success
      assert_includes response.body, %(data-bank-pull-from-ratio="percent")

      # (c) nil / nil -> equal.
      primary_edge.update!(value: nil)
      secondary_edge.update!(value: nil)
      get "/plan/flow"
      assert_response :success
      assert_includes response.body, %(data-bank-pull-from-ratio="equal")
    end
  end

  # the save contract — the required [value] carrier stores the
  # PERCENT (not dollars); blank stores nil (the equal split); an
  # out-of-range percent is a 422 with field-keyed errors and the stored
  # state is preserved.
  test "required split: save persists percents, blank is nil, 150 is a 422 (C4)" do
    travel_to Date.new(2026, 11, 15) do
      primary = create_income_series(account: @account, name: "Primary Payroll", amount: 2700)
      secondary = create_income_series(account: @account, name: "Secondary Payroll", amount: 1400)
      primary_edge = IncomeAccountAllocation.create!(family: @family, income_series: primary,
        account: @account, mode: "required")
      secondary_edge = IncomeAccountAllocation.create!(family: @family, income_series: secondary,
        account: @account, mode: "required")
      r30_required_base(20_000) # $200/mo over the average 2 paychecks -> $100.00 display (BUG-R30-1 divisor)

      # The displayed required is 100.00, so 75.00 / 25.00 are PERCENTS of
      # it (75.00 dollars would be the original specific shape).
      patch_bank_links(links: {
        primary.id.to_s => { "enabled" => "1", "mode" => "required", "value" => "75.00" },
        secondary.id.to_s => { "enabled" => "1", "mode" => "required", "value" => "25.00" }
      })
      assert_response :success
      assert_in_delta 75.00, primary_edge.reload.value.to_d, 0.0001
      assert_in_delta 25.00, secondary_edge.reload.value.to_d, 0.0001

      # Blank = nil = the equal split.
      patch_bank_links(links: {
        primary.id.to_s => { "enabled" => "1", "mode" => "required", "value" => "" },
        secondary.id.to_s => { "enabled" => "1", "mode" => "required", "value" => "25.00" }
      })
      assert_response :success
      assert_nil primary_edge.reload.value
      assert_in_delta 25.00, secondary_edge.reload.value.to_d, 0.0001

      # 150.00 fails the model's <= 100 check: 422 with field-keyed errors,
      # the stored state preserved (no partial write).
      patch_bank_links(links: {
        primary.id.to_s => { "enabled" => "1", "mode" => "required", "value" => "150.00" },
        secondary.id.to_s => { "enabled" => "1", "mode" => "required", "value" => "25.00" }
      })
      assert_response :unprocessable_entity
      errors = JSON.parse(response.body)["errors"]
      assert errors["value"].any? { |message| message.include?("less than or equal to 100") }
      assert_nil primary_edge.reload.value
      assert_in_delta 25.00, secondary_edge.reload.value.to_d, 0.0001
    end
  end

  # --- The Leftover guardrail — one account per
  # member's paycheck may carry the leftover. The UI greys the "Leftover"
  # option for the member's other allocations; the server backstops a forced
  # second leftover with a 422 (the unit test the spec calls out). ---

  # A member's paycheck already has a leftover edge to @account (Checking);
  # opening a DIFFERENT account (Savings) and forcing that paycheck's mode to
  # leftover there would create a second leftover account -> 422, nothing
  # written, the original leftover preserved.
  test "leftover guardrail: a second leftover account for the same paycheck 422s (spec 3)" do
    travel_to Date.new(2026, 11, 15) do
      secondary = create_income_series(account: @account, name: "Secondary Payroll", amount: 1400)
      secondary.update!(plan_owner_user_id: @user.id)
      savings = @family.accounts.create!(name: "Savings Bucket", owner: @user,
        currency: "USD", balance: 0, accountable: Depository.new)
      # Secondary's paycheck's leftover already lands in @account (Checking).
      IncomeAccountAllocation.create!(family: @family, income_series: secondary,
        account: @account, mode: "leftover")

      # Force a second leftover (Savings) for the same paycheck -> 422.
      patch_bank_links(links: { secondary.id.to_s => { "enabled" => "1", "mode" => "leftover" } },
        account: savings)
      assert_response :unprocessable_entity
      errors = JSON.parse(response.body)["errors"]
      assert errors["base"].any? { |m| m.include?("One Leftover per member") },
        "the 422 must carry the clear one-Leftover-per-member message"

      # Nothing written: still exactly ONE leftover edge, and it is the
      # original (@account), never Savings.
      leftovers = @family.income_account_allocations.where(mode: "leftover",
        income_series_id: secondary.id)
      assert_equal 1, leftovers.count
      assert_equal @account.id, leftovers.first.account_id
      assert_equal 0, @family.income_account_allocations
        .where(mode: "leftover", account_id: savings.id).count
    end
  end

  # The allowed cases: the FIRST leftover (no existing one), re-saving the
  # SAME account as leftover (idempotent), and a DIFFERENT member's paycheck
  # taking its own leftover (one per member, not one per family).
  test "leftover guardrail: first leftover, same-account re-save, and a different member are allowed (spec 3)" do
    travel_to Date.new(2026, 11, 15) do
      secondary = create_income_series(account: @account, name: "Secondary Payroll", amount: 1400)
      secondary.update!(plan_owner_user_id: @user.id)

      # No existing leftover: setting @account as Secondary's leftover is allowed.
      patch_bank_links(links: { secondary.id.to_s => { "enabled" => "1", "mode" => "leftover" } })
      assert_response :success
      assert_equal 1, @family.income_account_allocations
        .where(mode: "leftover", income_series_id: secondary.id).count

      # Re-saving the SAME account as leftover is allowed (idempotent).
      patch_bank_links(links: { secondary.id.to_s => { "enabled" => "1", "mode" => "leftover" } })
      assert_response :success
      assert_equal 1, @family.income_account_allocations
        .where(mode: "leftover", income_series_id: secondary.id).count

      # A different member's paycheck can take its own leftover (one per
      # member) on a different account.
      primary = create_income_series(account: @account, name: "Primary Payroll", amount: 2700)
      primary.update!(plan_owner_user_id: @other.id)
      savings = @family.accounts.create!(name: "Savings Bucket", owner: @user,
        currency: "USD", balance: 0, accountable: Depository.new)
      patch_bank_links(links: { primary.id.to_s => { "enabled" => "1", "mode" => "leftover" } },
        account: savings)
      assert_response :success
      assert_equal 1, @family.income_account_allocations
        .where(mode: "leftover", income_series_id: primary.id, account_id: savings.id).count
    end
  end

  # UI half: when Secondary's paycheck already has a leftover edge to
  # @account (Checking), the bank dialog opened on a DIFFERENT account greys
  # the "Leftover" radio for that paycheck (disabled + tooltip), while the
  # other three modes stay selectable. The same-account dialog keeps it
  # enabled (it is the current leftover).
  test "leftover guardrail: the bank dialog greys the Leftover option for the member's other accounts (spec 3)" do
    travel_to Date.new(2026, 11, 15) do
      secondary = create_income_series(account: @account, name: "Secondary Payroll", amount: 1400)
      secondary.update!(plan_owner_user_id: @user.id)
      # plan_order puts Savings ON the plan so its bank dialog renders (the
      # bank dialogs only render for in-plan accounts).
      savings = @family.accounts.create!(name: "Savings Bucket", owner: @user,
        currency: "USD", balance: 0, accountable: Depository.new)
      savings.update!(plan_order: 99)
      IncomeAccountAllocation.create!(family: @family, income_series: secondary,
        account: @account, mode: "leftover")

      get "/plan/flow"
      assert_response :success

      # Opened on Savings (NOT Secondary's leftover account): the Leftover radio
      # is greyed out; the other three modes are still selectable.
      assert_select "dialog[data-node-id='bank:#{savings.id}']" do
        assert_select "[data-bank-pull-panel-group='row-#{secondary.id}'] input[type=radio][value=leftover][disabled]", 1
        assert_select "[data-bank-pull-panel-group='row-#{secondary.id}'] input[type=radio][value=required][disabled]", 0
        assert_select "[data-bank-pull-panel-group='row-#{secondary.id}'] input[type=radio][value=specific][disabled]", 0
        assert_select "[data-bank-pull-panel-group='row-#{secondary.id}'] input[type=radio][value=percent][disabled]", 0
      end

      # Opened on @account (Secondary's leftover account): the Leftover radio
      # stays enabled (it is the current leftover).
      assert_select "dialog[data-node-id='bank:#{@account.id}']" do
        assert_select "[data-bank-pull-panel-group='row-#{secondary.id}'] input[type=radio][value=leftover][disabled]", 0
        assert_select "[data-bank-pull-panel-group='row-#{secondary.id}'] input[type=radio][value=leftover][checked]", 1
      end
    end
  end

  # The Direct Deposit Review dialog is a STATIC READ-ONLY readout —
  # no config form (gross / frequency / anchor / Save), one tab per member,
  # the header + max-direct-deposit-connections note server-rendered, and the
  # per-paycheck table shell (the rows fill client-side from the graph). The
  # family_paycheck_configs PATCH endpoint stays in place (unused by this UI).
  test "the DD review dialog is a static read-only readout, not a config form (spec 1)" do
    travel_to Date.new(2026, 11, 15) do
      secondary = create_income_series(account: @account, name: "Secondary Payroll", amount: 1400)
      secondary.update!(plan_owner_user_id: @user.id, plan_max_account_links: 4)

      get "/plan/flow"

      assert_response :success
      assert_select "dialog[data-node-id='paycheck-config']", 1 do
        # One tab per existing family member (the names render as
        # buttons; nowrap verified at a wide desktop viewport via the browser harness).
        assert_select "button[role=tab]", @family.users.count
        # The static readout: the header line + the max-DD-connections note
        # (the member's series' plan_max_account_links = 4).
        assert_includes response.body, I18n.t("plan_flows.paycheck_config_dialog.header", name: @user.display_name)
        assert_includes response.body, I18n.t("plan_flows.paycheck_config_dialog.max_dd_label")
        assert_includes response.body, "4"
        # The table shell (Account | Direct Deposit Amount) + the member's
        # tbody (the rows fill client-side from /plan/flow/graph).
        assert_includes response.body, I18n.t("plan_flows.paycheck_config_dialog.account_header")
        assert_includes response.body, I18n.t("plan_flows.paycheck_config_dialog.amount_header")
        assert_select "tbody[data-paycheck-dd-member='#{@user.id}']", 1
        # The config form is GONE: no gross/frequency/anchor inputs, no Save
        # action targeting the paycheck-config PATCH endpoint.
        assert_select "input[data-paycheck-gross-input]", 0
        assert_select "input[data-paycheck-frequency-input]", 0
        assert_select "input[data-paycheck-anchor-input]", 0
        assert_select "form[action='/plan/flow/paycheck-config/#{@user.id}']", 0
      end

      # The endpoint stays in place (unused by this UI) — a GET to the plan
      # page must not 404, and the route still resolves.
      assert_response :success
    end
  end

  # BUG- -1 regression ( fix-round): the paycheck-view required
  # display must divide by the AVERAGE occurrences per linked income (the
  # composite paycheck), not by the sum of occurrences across all required
  # edges. The pinned scenario (the SoFi Checking case): 2 required edges,
  # base 100.00/mo, 2 occurrences per income (funding sum 4) -> 50.00 per
  # paycheck, not the pre-fix 100.00/4 = 25.00. The percent round-trip the
  # dialog JS performs on that base (dollar / display * 100, the values
  # block) must land inside (0, 100]: dollar 30.00 -> 60.00 percent of
  # required (pre-fix 30.00/25.00 = 120.00 -> the 422 cascade behind the
  # Test cycle's 2f/2g/leg5 failures).
  test "required display: the per-paycheck base is the average, not the edge sum (BUG-R30-1)" do
    travel_to Date.new(2026, 11, 15) do
      primary = create_income_series(account: @account, name: "Primary Payroll", amount: 2700)
      secondary = create_income_series(account: @account, name: "Secondary Payroll", amount: 1400)
      IncomeAccountAllocation.create!(family: @family, income_series: primary,
        account: @account, mode: "required", value: 60.00)
      IncomeAccountAllocation.create!(family: @family, income_series: secondary,
        account: @account, mode: "required", value: 40.00)
      r30_required_base(10_000) # $100.00/mo -- the SoFi Checking base

      get "/plan/flow"

      assert_response :success
      # The exact scenario pin: set_bank_dialog_context yields
      # @bank_required_display == 50.00 (dollars view) -- 100.00 / ((2 + 2) / 2),
      # NOT 100.00 / 4 = 25.00 (the pre-fix branch divided by the 4-edge sum).
      display = controller.instance_variable_get(:@bank_required_display)[@account.id]
      assert_in_delta 50.00, display, 0.0001
      assert_includes response.body, %(data-bank-required-display="50.00")
      # The percent round-trip on the corrected base (the JS conversion
      # dollar / display * 100): a typed dollar 30.00 converts to 60.00
      # percent of required -- inside (0, 100], so the fixed-amount entry
      # no longer 422s (pre-fix: 30.00/25.00 * 100 = 120.00).
      assert_in_delta 60.00, BigDecimal("30.00") / display * 100, 0.0001
      # The readout direction of the same base: the stored 60/40 seeds
      # $30.00 / $20.00 of the displayed $50.00 (summing exactly to it).
      assert_includes response.body, "Primary Payroll: $30.00"
      assert_includes response.body, "Secondary Payroll: $20.00"
    end
  end

  # --- (Fun Money v2): the fun_money row's configuration ---
  # The sanitizer passes ownership / distribution / matching / percents
  # through for kind "fun_money" ONLY (non-fun_money rows get them dropped,
  # the byte-identical stop-rule), the input snapshot is pinned on
  # save, the graph payload echoes the config + the reconciliation, and
  # the red line renders for an un-allocated residual strictly above the
  # 100-cent tolerance (in the toggle-row hover icon's popup, no
  # longer in the chrome-top swap).
  test "Round 31A: create a fun_money row with config; graph echoes it and pins the C14 snapshot" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 500)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")

      post "/plan/flow/allocations", headers: { "Accept" => "application/json" }, params: {
        plan_allocation: { name: "Fun money", kind: "fun_money", mode: "leftover",
                           account_id: @account.id, ownership: @other.id.to_s,
                           distribution: "equal", matching: "equalize" }
      }

      assert_response :success
      row = @family.plan_allocations.find_by(name: "Fun money")
      assert row, "the fun_money row was not created"
      assert_equal @other.id.to_s, row.ownership
      assert_equal "equal", row.distribution
      assert_equal "equalize", row.matching

      # the input snapshot (per-income I/B/S cents) is pinned at save.
      snapshot = row.distribution_params["inputs_snapshot"]
      assert snapshot.is_a?(Hash), "the C14 snapshot was not pinned"
      assert snapshot.any? { |_income_id, entry| entry.is_a?(Hash) && entry.key?("i") }

      # The graph payload echoes the config and carries the additive keys.
      json = JSON.parse(response.body)
      fm = json["graph"]["allocations"].find { |a| a["name"] == "Fun money" }
      assert fm, "the fun_money row must be in the saved-state graph"
      assert_equal @other.id.to_s, fm["ownership"]
      assert_equal "equal", fm["distribution"]
      assert_equal "equalize", fm["matching"]
      assert fm.key?("per_member")
      assert fm.key?("inputs_stale")
      json["graph"]["incomes"].each do |income|
        assert income.key?("reconciliation"), "every income row carries reconciliation"
      end
      assert_equal [], json["graph"]["discrepancies"]
    end
  end

  test "Round 31A: a non-fun_money row drops the config values (byte-identical dialog)" do
    post "/plan/flow/allocations", params: {
      plan_allocation: { name: "Netflix", kind: "bill", mode: "specific", value: "15.99",
                         account_id: @account.id, ownership: "household",
                         distribution: "equal", matching: "per_income" }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    row = @family.plan_allocations.find_by(name: "Netflix")
    assert row
    assert_nil row.ownership
    assert_nil row.distribution
    assert_nil row.matching
  end

  test "Round 31A: editing a fun_money row back to another kind clears its config" do
    row = PlanAllocation.create!(family: @family, account: @account, name: "Fun money",
      kind: "fun_money", mode: "leftover", ownership: @other.id.to_s,
      distribution: "percent", distribution_params: { "percents" => { @user.id.to_s => "100.00" } })

    patch "/plan/flow/allocations/#{row.id}", params: {
      plan_allocation: { account_id: @account.id, name: "Groceries", kind: "bill",
                         mode: "specific", value: "40.00" }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal "bill", row.reload.kind
    assert_nil row.ownership
    assert_nil row.distribution
    assert_nil row.distribution_params
  end

  test "Round 31A: a cross-family ownership id 422s through the in-place JSON contract" do
    other_family = Family.where.not(id: @family.id).first
    outsider = other_family.users.create!(
      first_name: "Out", last_name: "Sid", email: "outsider@example.com",
      role: "member", password: "Password123!"
    )

    post "/plan/flow/allocations", headers: { "Accept" => "application/json" }, params: {
      plan_allocation: { name: "Fun money", kind: "fun_money", mode: "leftover",
                         account_id: @account.id, ownership: outsider.id.to_s,
                         distribution: "equal", matching: "equalize" }
    }

    assert_response :unprocessable_entity
    errors = JSON.parse(response.body)["errors"]
    assert errors["ownership"], "the ownership error must name the field"
    assert_nil @family.plan_allocations.find_by(name: "Fun money")
  end

  test "Round 31A: the red line names the income for an un-allocated residual (R35c: icon popup, not the chrome-top swap)" do
    travel_to Date.new(2026, 11, 15) do
      # 1000.00/mo in (2 x 500.00), 700.00/mo required bills -> 300.00
      # leftover; a 50% percent fun row takes 150.00 -> 150.00 un-allocated
      # (strictly above the 100-cent tolerance) -> the RED line. The
      # REQUIRED income edge is what charges the bills' base to the income
      # (B_k = the resolved required edge charges).
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 500)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "required")
      PlanAllocation.create!(family: @family, account: @account, name: "Bills",
        kind: "bill", mode: "required", value_cents: 70_000)
      PlanAllocation.create!(family: @family, account: @account, name: "Fun money",
        kind: "fun_money", mode: "percent", value_percent: 0.5,
        ownership: @user.id.to_s, matching: "per_income")

      get "/plan/flow"
      assert_response :success
      assert_match(/Bob Payroll \u2014 Un-Allocated/, response.body)
      # the unit-aware figure — the default
      # Per Paycheck view shows the per-paycheck share of the monthly
      # un-allocated residual (150.00 / 2 occurrences = 75.00).
      assert_match(/75\.00/, response.body)

      # The red line groups no longer ship in the chrome.top in-place
      # swap (they moved to the toggle-row hover icon in show.html.erb, fed
      # from the same @discrepancy_lines local; the swap now carries only
      # the prompt when present).
      bills = @family.plan_allocations.find_by(name: "Bills")
      patch "/plan/flow/allocations/#{bills.id}",
        headers: { "Accept" => "application/json" }, params: {
          plan_allocation: { account_id: @account.id, name: "Bills", kind: "bill",
                             mode: "required", value: "700.00" }
        }
      assert_response :success
      chrome = JSON.parse(response.body)["chrome"]
      assert_no_match(/Un-Allocated/, chrome["top"])
    end
  end

  test "Round 36: the plan-issues icon re-renders in chrome.issues_icon on in-place saves (design doc section 5)" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "required")
      bill = PlanAllocation.create!(family: @family, account: @account, name: "Huge Bill",
        kind: "bill", mode: "required", value_cents: 250_000, cadence: "monthly")

      # Over-planned (2 x 900.00 in, 2500.00/mo required): the icon ships
      # in chrome.issues_icon with the unit-aware red line — the default
      # Per Paycheck view shows the per-paycheck share (700.00 / 2 = 350.00).
      patch "/plan/flow/allocations/#{bill.id}",
        headers: { "Accept" => "application/json" }, params: {
          plan_allocation: { account_id: @account.id, name: "Huge Bill", kind: "bill",
                             mode: "required", value: "2500.00" }
        }
      assert_response :success
      icon = JSON.parse(response.body)["chrome"]["issues_icon"]
      assert_match(/m21\.73 18-8-14/, icon) # the triangle-alert glyph
      assert_match(/Over-planned by \$350\.00 on Bob Payroll/, icon)

      # The bill is fixed (1800.00/mo = 900.00/paycheck, nothing over): the
      # icon DISAPPEARS without a reload — an empty fragment.
      patch "/plan/flow/allocations/#{bill.id}",
        headers: { "Accept" => "application/json" }, params: {
          plan_allocation: { account_id: @account.id, name: "Huge Bill", kind: "bill",
                             mode: "required", value: "1800.00" }
        }
      assert_response :success
      assert_equal "", JSON.parse(response.body)["chrome"]["issues_icon"]
    end
  end

  test "Round 31A: the fun_money dialog renders the four config fields with the owner labels" do
    PlanAllocation.create!(family: @family, account: @account, name: "Fun money",
      kind: "fun_money", mode: "leftover")

    get "/plan/flow"
    assert_response :success
    body = response.body
    # The distribution options (verbatim labels).
    assert_includes body, I18n.t("plan_flows.allocation_dialog.distribution_equal")
    assert_includes body, I18n.t("plan_flows.allocation_dialog.distribution_rational")
    assert_includes body, I18n.t("plan_flows.allocation_dialog.distribution_percent")
    assert_includes body, I18n.t("plan_flows.allocation_dialog.distribution_individual_leftover")
    # The mode labels (verbatim list).
    assert_includes body, I18n.t("plan_flows.allocation_dialog.fm_mode_leftover")
    assert_includes body, I18n.t("plan_flows.allocation_dialog.fm_mode_percent")
    assert_includes body, I18n.t("plan_flows.allocation_dialog.fm_mode_specific")
    assert_includes body, I18n.t("plan_flows.allocation_dialog.fm_mode_required")
    # The label keys render for the fun_money kind only.
    assert_includes body, I18n.t("plan_flows.allocation_dialog.ownership_label")
    assert_includes body, I18n.t("plan_flows.allocation_dialog.distribution_label")
    assert_includes body, I18n.t("plan_flows.allocation_dialog.matching_label")
  end

  # (Direct Deposit): PATCH /plan/flow/paycheck-config/:user_id —
  # the member's paycheck config, in-place (Accept: application/json).
  # Same shape as create_income_series but with an explicit plan_owner (the
  # labeled-series lookup keys on plan_owner_user_id, no account-holder
  # fallback).
  def create_member_income_series(member:, name:, amount:)
    series = @family.recurring_transactions.create!(
      name: name, account: @account, amount: amount, currency: "USD",
      expected_day_of_month: 6, last_occurrence_date: Date.new(2026, 9, 6),
      next_expected_date: Date.new(2026, 12, 20), status: "active",
      bill_type: "income", manual: true, plan_owner: member
    )
    series.recurring_occurrences.destroy_all
    [ Date.new(2026, 11, 6), Date.new(2026, 11, 20) ].each do |date|
      series.recurring_occurrences.create!(family: @family, due_on: date,
        original_due_on: date, currency: "USD", expected_amount: amount,
        status: "scheduled")
    end
    series
  end

  test "Round 31B: the in-place paycheck-config save returns 200, writes ONLY the config row, and ships the re-rendered dialog" do
    travel_to Date.new(2026, 11, 15) do
      series = create_member_income_series(member: @other, name: "Jakob Paycheck", amount: 1200)
      @family.income_account_allocations.create!(
        income_series: series, account: @account, mode: "percent", value: 1.0)
      allocation = @family.plan_allocations.create!(
        account: @account, name: "Rent", cadence: "monthly",
        kind: "bill", mode: "specific", value_cents: 50_000)

      patch "/plan/flow/paycheck-config/#{@other.id}",
            headers: { "Accept" => "application/json" },
            params: { paycheck_config: { gross: "2000.00",
                                         frequency: "semi_monthly",
                                         anchor_date: "2026-11-02" } }

      assert_response :success
      body = JSON.parse(response.body)

      # the graph reflects the overlay (dates + gross replaced) while
      # the allocation's wanted stays put.
      income = body.dig("graph", "incomes").find { |row| row["id"] == series.id }
      assert_equal [ "2026-11-15", "2026-11-30" ],
                   income["occurrences"].map { |o| o["date"] }
      assert income["occurrences"].all? { |o| o["amount"] == "2000.00" }
      assert_equal [ "2026-11-15", "2026-11-30" ], body.dig("graph", "paycheck_dates")
      bank = body.dig("graph", "banks").find { |row| row["id"] == @account.id }
      assert_equal "4000.00", bank["inflow_month"] # 2000 x 2 pay dates
      row = body.dig("graph", "allocations").find { |a| a["id"] == allocation.id }
      assert_equal "1000.00", row["wanted_month"] # 500 x 2 paychecks (unchanged)

      # Exactly one row written: the member's config. The series' stored
      # occurrences and the allocation are untouched (read-only overlay).
      config = @family.family_paycheck_configs.find_by(user: @other)
      assert_equal 200_000, config.gross_per_paycheck_cents
      assert_equal "semi_monthly", config.frequency
      assert_equal Date.new(2026, 11, 2), config.anchor_date
      assert_equal series.id, config.recurring_transaction_id
      assert_equal 2, series.recurring_occurrences.count
      assert_equal 50_000, allocation.reload.value_cents

      # The re-rendered dialog ships through the bank_dialogs chrome slot
      # (the #syncDialog node-swap path).
      dialogs = body.dig("chrome", "bank_dialogs") || []
      assert_includes dialogs.map { |d| d["node_id"] }, "paycheck-config"
    end
  end

  test "Round 31B: a $0.00 gross 422s with the field error and writes nothing" do
    travel_to Date.new(2026, 11, 15) do
      series = create_member_income_series(member: @other, name: "Jakob Paycheck", amount: 1200)

      patch "/plan/flow/paycheck-config/#{@other.id}",
            headers: { "Accept" => "application/json" },
            params: { paycheck_config: { gross: "0.00",
                                         frequency: "semi_monthly",
                                         anchor_date: "2026-11-02" } }

      assert_response :unprocessable_entity
      errors = JSON.parse(response.body).fetch("errors")
      assert errors.key?("gross_per_paycheck_cents"), errors.inspect
      assert_empty @family.family_paycheck_configs
      assert_equal 2, series.recurring_occurrences.count
    end
  end

  test "Round 31B: a missing anchor date 422s and writes nothing" do
    travel_to Date.new(2026, 11, 15) do
      create_member_income_series(member: @other, name: "Jakob Paycheck", amount: 1200)

      patch "/plan/flow/paycheck-config/#{@other.id}",
            headers: { "Accept" => "application/json" },
            params: { paycheck_config: { gross: "2000.00",
                                         frequency: "semi_monthly",
                                         anchor_date: "" } }

      assert_response :unprocessable_entity
      errors = JSON.parse(response.body).fetch("errors")
      assert errors.key?("anchor_date"), errors.inspect
      assert_empty @family.family_paycheck_configs
    end
  end

  test "Round 31B: a member with no labeled series 422s with the no-series error" do
    travel_to Date.new(2026, 11, 15) do
      # No series is labeled to @user (family_admin) — only @other has one.
      create_member_income_series(member: @other, name: "Jakob Paycheck", amount: 1200)

      patch "/plan/flow/paycheck-config/#{@user.id}",
            headers: { "Accept" => "application/json" },
            params: { paycheck_config: { gross: "2000.00",
                                         frequency: "semi_monthly",
                                         anchor_date: "2026-11-02" } }

      assert_response :unprocessable_entity
      errors = JSON.parse(response.body).fetch("errors")
      assert errors.key?("base"), errors.inspect
      assert_empty @family.family_paycheck_configs
    end
  end

  test "Round 31B: a user_id outside the family 404s" do
    travel_to Date.new(2026, 11, 15) do
      patch "/plan/flow/paycheck-config/#{users(:empty).id}",
            headers: { "Accept" => "application/json" },
            params: { paycheck_config: { gross: "2000.00",
                                         frequency: "semi_monthly",
                                         anchor_date: "2026-11-02" } }

      assert_response :not_found
      assert_equal [ "not found" ],
                   JSON.parse(response.body).dig("errors", "base")
    end
  end
end

# ---------------------------------------------------------------------------
# the scenario CRUD + reset API,
# the ?scenario= graph contract, and the scenario-scoped writes (the
# isolation invariant: every scenario-mode write touches ONLY the scenario
# row's snapshot — the live plan census is byte-for-byte unchanged).
# ---------------------------------------------------------------------------
class PlanFlowsScenarioControllerTest < ActionDispatch::IntegrationTest
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

  def json
    { "Accept" => "application/json" }
  end

  def create_income_series(account:, name:, amount:, owner: @user)
    series = @family.recurring_transactions.create!(
      name: name, account: account, amount: amount, currency: "USD",
      expected_day_of_month: 6, last_occurrence_date: Date.new(2026, 9, 6),
      next_expected_date: Date.new(2026, 12, 20), status: "active",
      bill_type: "income", manual: true, plan_owner: owner
    )
    series.recurring_occurrences.destroy_all
    [ Date.new(2026, 11, 6), Date.new(2026, 11, 20) ].each do |date|
      series.recurring_occurrences.create!(family: @family, due_on: date,
        original_due_on: date, currency: "USD", expected_amount: amount,
        status: "scheduled")
    end
    series
  end

  # The live plan the scenario snapshots: two incomes (Primary + Secondary),
  # leftover edges to the same bank, a $1000 rent bill.
  def seed_live_plan
    travel_to Date.new(2026, 11, 15) do
      @primary_series = create_income_series(account: @account, name: "Primary Paycheck", amount: 400)
      @secondary_series = create_income_series(account: @account, name: "Secondary Paycheck", amount: 900, owner: @other)
      IncomeAccountAllocation.create!(family: @family, income_series: @primary_series,
        account: @account, mode: "leftover")
      IncomeAccountAllocation.create!(family: @family, income_series: @secondary_series,
        account: @account, mode: "leftover")
      @rent = PlanAllocation.create!(family: @family, account: @account, name: "Rent",
        kind: "bill", mode: "specific", value_cents: 100_000, cadence: "monthly")
    end
  end

  def census
    {
      allocations: @family.plan_allocations.count,
      edges: @family.income_account_allocations.count,
      configs: @family.family_paycheck_configs.count,
      scenarios: @family.plan_scenarios.count
    }
  end

  def create_scenario(name: "Second income quits", source: "current", params: { name: name, source: source })
    post "/plan/flow/scenarios", headers: json, params: params
  end

  # The jsonb round-trip stringifies BigDecimals (ActiveSupport's
  # BigDecimal#as_json -> to_s), so a persisted snapshot differs from a
  # fresh PlanScenarioSnapshot build only in numeric encoding. Deep-compare
  # through the planner's row normalizer (symbol keys + BigDecimal
  # numerics on both sides) — the semantic equality the design means.
  def scenario_rows(snapshot, key)
    (snapshot[key] || []).map { |row| PaycheckFlowPlanner.scenario_row(row) }
  end

  # --- index (the design) ---

  test "index lists scenarios with the snapshot count and active id" do
    seed_live_plan
    create_scenario
    assert_response :created
    first = PlanScenario.order(:id).first

    get "/plan/flow/scenarios", headers: json
    assert_response :success
    body = response.parsed_body
    assert body["ok"]
    assert_equal 1, body["scenarios"].size
    row = body["scenarios"].first
    assert_equal "Second income quits", row["name"]
    assert_equal "reuse_current", row["source"]
    assert_equal 1, row["snapshot_count"]["allocations"]
    assert_equal 2, row["snapshot_count"]["edges"]
    assert_equal 0, row["snapshot_count"]["configs"], "no paycheck configs in the fixture"
    assert_nil body["active_id"], "no ?scenario= param -> no active id"

    get "/plan/flow/scenarios", headers: json, params: { scenario: first.id }
    assert_equal first.id, response.parsed_body["active_id"]
  end

  # --- create (snapshot identity) ---

  test "create re-uses the live plan: the snapshot deep-equals the fresh builder" do
    seed_live_plan
    create_scenario
    assert_response :created
    scenario = PlanScenario.last
    fresh = PlanScenarioSnapshot.reuse_current(@family)
    assert_equal scenario_rows(fresh, "plan_allocations"), scenario_rows(scenario.snapshot, "plan_allocations")
    assert_equal scenario_rows(fresh, "allocations"), scenario_rows(scenario.snapshot, "allocations")
    assert_equal fresh["incomes"], scenario.snapshot["incomes"]
    assert_equal 1, scenario.snapshot["v"]
    refute_nil scenario.snapshotted_at

    body = response.parsed_body
    assert body["ok"]
    assert_equal scenario.id, body["scenario"]["id"]
    assert_equal 2, body["graph"]["incomes"].size, "the create response ships the scenario graph"
  end

  test "create fresh: empty plan over the current incomes (owner decision)" do
    seed_live_plan
    create_scenario(source: "fresh")
    assert_response :created
    scenario = PlanScenario.last
    assert_equal "fresh", scenario.source
    assert_empty scenario.snapshot["plan_allocations"]
    assert_empty scenario.snapshot["allocations"]
    assert_empty scenario.snapshot["paycheck_configs"]
    assert_nil scenario.snapshotted_at
    # The income policy carries BOTH current series, all enabled.
    assert_equal [ @primary_series.id, @secondary_series.id ].sort,
                 scenario.snapshot["incomes"].map { |row| row["series_id"] }.sort
    assert scenario.snapshot["incomes"].all? { |row| row["enabled"] == true && row["zeroed"] == false }
  end

  test "create 422s: blank name, reserved default, case-insensitive collision, bad source" do
    seed_live_plan
    create_scenario(name: "   ")
    assert_response :unprocessable_entity
    assert_includes response.parsed_body["errors"]["name"].to_a, I18n.t("errors.messages.blank")

    create_scenario(name: "Default")
    assert_response :unprocessable_entity
    assert response.parsed_body["errors"]["name"].to_a.any? { |m| m.include?("reserved") }

    create_scenario # "Second income quits"
    assert_response :created
    create_scenario(name: "second income quits")
    assert_response :unprocessable_entity
    assert response.parsed_body["errors"]["name"].to_a.any? { |m| m.include?("taken") }

    create_scenario(source: "bogus")
    assert_response :unprocessable_entity
    assert response.parsed_body["errors"]["source"].to_a.any? { |m| m.include?("invalid") }

    assert_equal 1, PlanScenario.count
  end

  # --- rename (the design) ---

  test "rename updates the name; 404s on default/unknown; 422 on collision" do
    seed_live_plan
    create_scenario
    scenario = PlanScenario.last

    patch "/plan/flow/scenarios/#{scenario.id}", headers: json, params: { name: "Quits v2" }
    assert_response :success
    assert_equal "Quits v2", response.parsed_body["scenario"]["name"]

    patch "/plan/flow/scenarios/default", headers: json, params: { name: "X" }
    assert_response :not_found
    assert_equal "unknown scenario", response.parsed_body["error"]

    patch "/plan/flow/scenarios/00000000-0000-0000-0000-000000000000", headers: json, params: { name: "X" }
    assert_response :not_found

    create_scenario(name: "Other")
    patch "/plan/flow/scenarios/#{scenario.id}", headers: json, params: { name: "other" }
    assert_response :unprocessable_entity
    assert response.parsed_body["errors"]["name"].to_a.any? { |m| m.include?("taken") }
  end

  # --- delete (the design) ---

  test "delete removes the row; 404s on default/unknown; 422 while active" do
    seed_live_plan
    create_scenario
    scenario = PlanScenario.last

    # Active-context delete is the 422 backstop (the picker switches first).
    delete "/plan/flow/scenarios/#{scenario.id}", headers: json, params: { scenario: scenario.id }
    assert_response :unprocessable_entity
    assert response.parsed_body["errors"]["scenario"].any? { |m| m =~ /switch away/i }
    assert_equal 1, PlanScenario.count

    delete "/plan/flow/scenarios/#{scenario.id}", headers: json
    assert_response :success
    assert_equal scenario.id, response.parsed_body["deleted"]
    assert_equal 0, PlanScenario.count

    delete "/plan/flow/scenarios/default", headers: json
    assert_response :not_found
  end

  # --- reset (the design decision ) ---

  test "reset reuse_current re-snapshots the CURRENT live plan" do
    seed_live_plan
    create_scenario
    scenario = PlanScenario.last

    # A live edit AFTER the snapshot: a new allocation.
    PlanAllocation.create!(family: @family, account: @account, name: "Car Loan",
      kind: "bill", mode: "specific", value_cents: 30_000, cadence: "monthly")

    post "/plan/flow/scenarios/#{scenario.id}/reset", headers: json
    assert_response :success
    rebuilt = PlanScenarioSnapshot.reuse_current(@family)
    assert_equal scenario_rows(rebuilt, "plan_allocations"), scenario_rows(scenario.reload.snapshot, "plan_allocations"),
      "the reset snapshot must deep-equal a fresh reuse snapshot (the live edit is in)"
    assert_equal 2, scenario.snapshot["plan_allocations"].size
    refute_nil scenario.snapshotted_at
    assert response.parsed_body["ok"]
    assert_equal 2, response.parsed_body["graph"]["allocations"].size
  end

  test "reset fresh discards in-scenario edits and rebuilds the empty plan" do
    seed_live_plan
    create_scenario(name: "Fresh", source: "fresh")
    fresh = PlanScenario.last

    # An in-scenario edit (a new allocation row), then the reset:
    post "/plan/flow/allocations?scenario=#{fresh.id}", headers: json, params: {
      plan_allocation: { account_id: @account.id, name: "Scenario Bill", kind: "bill",
                         mode: "specific", value: "25.00", cadence: "monthly" }
    }
    assert_response :success
    assert_equal 1, fresh.reload.snapshot["plan_allocations"].size

    post "/plan/flow/scenarios/#{fresh.id}/reset", headers: json
    assert_response :success
    fresh.reload
    assert_empty fresh.snapshot["plan_allocations"], "the edit is discarded"
    assert_empty fresh.snapshot["allocations"]
    assert_equal 2, fresh.snapshot["incomes"].size, "the empty plan over the CURRENT incomes"
    assert_nil fresh.snapshotted_at
    assert_equal fresh.id, response.parsed_body["scenario"]["id"]
    assert_equal 0, response.parsed_body["graph"]["allocations"].size

    post "/plan/flow/scenarios/default/reset", headers: json
    assert_response :not_found
    post "/plan/flow/scenarios/00000000-0000-0000-0000-000000000000/reset", headers: json
    assert_response :not_found
  end

  # --- scenario bank-links save ( : the required-mode blank carrier) ---

  # The live plan behind the scenario: two incomes with required edges to
  # @account (nil value = the equal split) and a $500/month required base
  # on the bank. The dialog seeds the hidden links[id][value] carrier ""
  # for required mode (view seed + recalcPullFrom), so a save of the
  # dialog's exact carrier must accept the blank.
  def seed_bank_links_plan
    travel_to Date.new(2026, 11, 15) do
      @primary_series = create_income_series(account: @account, name: "Primary Paycheck", amount: 400)
      @secondary_series = create_income_series(account: @account, name: "Secondary Paycheck", amount: 900, owner: @other)
      IncomeAccountAllocation.create!(family: @family, income_series: @primary_series,
        account: @account, mode: "required")
      IncomeAccountAllocation.create!(family: @family, income_series: @secondary_series,
        account: @account, mode: "required")
      PlanAllocation.create!(family: @family, account: @account, name: "SoFi Savings",
        kind: "bill", mode: "required", value_cents: 50_000, cadence: "monthly")
    end
  end

  # The scenario-mode twin of patch_bank_links: the same in-place save with
  # the ?scenario= param (the scenario's snapshot takes the links write;
  # the live table is untouched).
  def patch_bank_links_scenario(scenario, links)
    patch "/plan/flow/accounts/#{@account.id}", headers: json, params: {
      account: { plan_ownership: "shared", plan_role: "", bank_logo_slug: "",
                 parent_account_id: "", auto_transfer_target_ids: [ "0" ] },
      links: links,
      scenario: scenario.id
    }
  end

  test "scenario bank-links: required + blank carrier saves (equal split), no 422 (Round 35d)" do
    seed_bank_links_plan
    create_scenario(name: "R35d repro", source: "current")
    scenario = PlanScenario.last

    # the exact shape: Primary checked + Required (the blank carrier),
    # Secondary unchecked. Pre-fix the blank carrier became 0 -> the model's
    # required range check 422'd with "must be greater than 0".
    patch_bank_links_scenario(scenario, {
      @primary_series.id.to_s => { "enabled" => "1", "mode" => "required", "value" => "" },
      @secondary_series.id.to_s => { "mode" => "required", "value" => "" }
    })
    assert_response :success, "the blank required carrier must not 422"
    assert response.parsed_body.key?("graph"),
      "the in-place save response ships the fresh graph (the 422 shape is {errors})"

    # The snapshot row: nil required_percent = the equal split (not 0).
    rows = scenario_rows(scenario.reload.snapshot, "allocations")
    primary_row = rows.find { |r| r[:income_id] == @primary_series.id && r[:account_id] == @account.id }
    assert primary_row, "the Primary edge row must be in the scenario snapshot"
    assert_equal "required", primary_row[:mode]
    assert_nil primary_row[:required_percent], "blank carrier -> nil (equal split), not 0"
    assert rows.none? { |r| r[:income_id] == @secondary_series.id },
      "the unchecked Secondary row leaves the snapshot edge set"

    # The live plan is untouched: the live edge still carries nil.
    assert_nil IncomeAccountAllocation.find_by(income_series_id: @primary_series.id,
      account_id: @account.id).value

    # The scenario graph settles the equal split: the single funder's 2
    # paychecks divide the $500/month base -> 250.00 per paycheck.
    get "/plan/flow/graph?scenario=#{scenario.id}", headers: json
    assert_response :success
    bank = response.parsed_body["banks"].find { |b| b["id"] == @account.id }
    primary_inflow = bank["inflow"].select { |row| row["income_id"] == @primary_series.id }
    assert_equal 2, primary_inflow.size
    assert primary_inflow.all? { |row| row["mode"] == "required" }
    assert_equal [ "250.00", "250.00" ], primary_inflow.map { |row| row["amount"] }
    assert_equal "500.00", bank["inflow_month"], "the bank's full required base lands"
  end

  test "scenario bank-links: required + a stored percent keeps the value (Round 35d)" do
    seed_bank_links_plan
    create_scenario(name: "R35d repro", source: "current")
    scenario = PlanScenario.last

    patch_bank_links_scenario(scenario, {
      @primary_series.id.to_s => { "enabled" => "1", "mode" => "required", "value" => "19.91" },
      @secondary_series.id.to_s => { "enabled" => "1", "mode" => "required", "value" => "" }
    })
    assert_response :success
    assert response.parsed_body.key?("graph"),
      "the in-place save response ships the fresh graph (the 422 shape is {errors})"

    # The snapshot row carries the stored 2-dp percent (the jsonb round-trip
    # stringifies it; scenario_rows normalizes it back to a BigDecimal).
    rows = scenario_rows(scenario.reload.snapshot, "allocations")
    primary_row = rows.find { |r| r[:income_id] == @primary_series.id && r[:account_id] == @account.id }
    assert_equal BigDecimal("19.91"), primary_row[:required_percent]

    # The scenario graph settles the stored split: 19.91% of the $500.00
    # base = 99.55 over Primary's two paychecks (49.78 + 49.77, last absorbs).
    get "/plan/flow/graph?scenario=#{scenario.id}", headers: json
    assert_response :success
    bank = response.parsed_body["banks"].find { |b| b["id"] == @account.id }
    primary_inflow = bank["inflow"].select { |row| row["income_id"] == @primary_series.id }
    assert_equal 2, primary_inflow.size
    assert_equal BigDecimal("99.55"), primary_inflow.map { |row| BigDecimal(row["amount"]) }.sum
  end

  # --- graph contract (the design) ---

  test "graph without a scenario carries NO scenario key and the live plan" do
    seed_live_plan
    get "/plan/flow/graph", headers: json
    assert_response :success
    body = response.parsed_body
    assert body.key?("incomes") || body.key?("banks") || body.key?("allocations") ||
           body.is_a?(Hash), "the graph JSON shape"
    refute body.key?("scenario"), "Default graph JSON must NOT carry the scenario key"
  end

  test "graph ?scenario= plans the snapshot and adds the additive key only" do
    seed_live_plan
    create_scenario
    scenario = PlanScenario.last

    # Secondary quits inside the scenario.
    snapshot = scenario.snapshot
    snapshot["incomes"] = snapshot["incomes"].map do |row|
      row["series_id"] == @secondary_series.id ? row.merge("enabled" => false) : row
    end
    scenario.update_column(:snapshot, snapshot)

    get "/plan/flow/graph", headers: json
    default_body = response.parsed_body
    default_incomes = default_body["incomes"]

    get "/plan/flow/graph?scenario=#{scenario.id}", headers: json
    assert_response :success
    body = response.parsed_body
    assert_equal({ "id" => scenario.id, "name" => scenario.name }, body["scenario"])
    scenario_incomes = body["incomes"]
    assert scenario_incomes.none? { |i| i["id"] == @secondary_series.id },
      "the disabled series must be absent from the scenario graph"
    assert default_incomes.any? { |i| i["id"] == @secondary_series.id },
      "and present in the Default graph (the live plan is untouched)"
    # Same keys otherwise (the additive-key invariant).
    assert_equal default_body.keys - [ "scenario" ], body.keys - [ "scenario" ]
  end

  test "graph ?scenario= unknown is a 404 JSON contract" do
    get "/plan/flow/graph?scenario=00000000-0000-0000-0000-000000000000", headers: json
    assert_response :not_found
    assert_equal "unknown scenario", response.parsed_body["error"]
  end

  # --- show (page shell) ---

  test "show default: no banner, sankey attr unscoped" do
    seed_live_plan
    get "/plan/flow"
    assert_response :success
    assert_includes response.body, "data-plan-flow-sankey-graph-url-value=\"/plan/flow/graph\""
    assert_not_includes response.body, "not your live plan"
  end

  test "show ?scenario=: banner + scoped sankey attr + snapshot-driven page" do
    seed_live_plan
    create_scenario
    scenario = PlanScenario.last

    get "/plan/flow?scenario=#{scenario.id}"
    assert_response :success
    assert_includes response.body, "data-plan-flow-sankey-graph-url-value=\"/plan/flow/graph?scenario=#{scenario.id}\""
    assert_includes response.body, "Second income quits"
    assert_includes response.body, "not your live plan"
    # The picker lists the scenario row with its rename/delete affordances.
    assert_includes response.body, "flow/scenarios/#{scenario.id}"
  end

  test "show ?scenario= unknown redirects to the live plan with the house alert" do
    seed_live_plan
    get "/plan/flow?scenario=00000000-0000-0000-0000-000000000000"
    assert_response :redirect
    assert_redirected_to "/plan/flow"
    follow_redirect!
    assert_match(/not found/, flash[:alert].to_s)
  end

  # --- scenario-scoped writes (the isolation invariant) ---

  test "scenario allocation create: snapshot row only, live census untouched" do
    seed_live_plan
    create_scenario
    scenario = PlanScenario.last
    before = census

    post "/plan/flow/allocations?scenario=#{scenario.id}", headers: json, params: {
      plan_allocation: { account_id: @account.id, name: "Scenario Bill", kind: "bill",
                         mode: "specific", value: "25.00", cadence: "monthly" }
    }
    # render_flow_json's contract: 200 + the re-planned graph (no top-level
    # ok key — a failure 422s with { errors: ... }).
    assert_response :success
    assert response.parsed_body.key?("graph")

    rows = scenario.reload.snapshot["plan_allocations"]
    assert_equal 2, rows.size, "the scenario's snapshot gained the row"
    row = rows.find { |r| r["name"] == "Scenario Bill" }
    refute_nil row
    refute_equal @rent.id, row["id"], "a new row gets a fresh uuid"
    assert_equal 2500, row["value_cents"].to_i
    refute row["id"].nil?

    assert_equal before, census, "the live plan census is byte-for-byte unchanged"
    assert_nil @family.plan_allocations.find_by(name: "Scenario Bill")
  end

  test "scenario allocation create: an invalid value 422s with the model errors" do
    seed_live_plan
    create_scenario
    scenario = PlanScenario.last

    post "/plan/flow/allocations?scenario=#{scenario.id}", headers: json, params: {
      plan_allocation: { account_id: @account.id, name: "Bad", kind: "bill", mode: "specific" }
    }
    assert_response :unprocessable_entity
    assert response.parsed_body["errors"].values.any?, "the 422 carries the model field errors"
    assert_equal 1, scenario.reload.snapshot["plan_allocations"].size, "the bad row is not persisted"
  end

  test "scenario allocation update + destroy: snapshot only" do
    seed_live_plan
    create_scenario
    scenario = PlanScenario.last
    before = census

    # Update the rent row inside the scenario (its live uuid is kept).
    patch "/plan/flow/allocations/#{@rent.id}?scenario=#{scenario.id}", headers: json, params: {
      plan_allocation: { account_id: @account.id, name: "Rent", kind: "bill",
                         mode: "specific", value: "1200.00" }
    }
    assert_response :success
    row = scenario.reload.snapshot["plan_allocations"].find { |r| r["id"] == @rent.id }
    assert_equal 120_000, row["value_cents"].to_i
    assert_equal 100_000, @rent.reload.value_cents.to_i, "the live row is untouched"

    # Unknown id in the scenario: 404.
    patch "/plan/flow/allocations/00000000-0000-0000-0000-000000000000?scenario=#{scenario.id}",
      headers: json, params: { plan_allocation: { account_id: @account.id, name: "X" } }
    assert_response :not_found

    # Destroy the rent row inside the scenario.
    delete "/plan/flow/allocations/#{@rent.id}?scenario=#{scenario.id}", headers: json
    assert_response :success
    assert scenario.reload.snapshot["plan_allocations"].none? { |r| r["id"] == @rent.id }
    assert @family.plan_allocations.exists?(@rent.id), "the live row survives"

    assert_equal before, census
  end

  test "scenario bank links: the snapshot edge set updates, live IAA untouched" do
    seed_live_plan
    create_scenario
    scenario = PlanScenario.last
    before = census

    # Primary's leftover moves to a percent split inside the scenario.
    patch "/plan/flow/accounts/#{@account.id}?scenario=#{scenario.id}", headers: json, params: {
      account: { plan_ownership: "shared", plan_role: "", bank_logo_slug: "",
                 parent_account_id: "", auto_transfer_target_ids: [ "0" ] },
      links: {
        @primary_series.id => { enabled: "1", mode: "percent", value: "50" },
        @secondary_series.id => { enabled: "1", mode: "leftover", value: "" }
      }
    }
    assert_response :success

    rows = scenario.reload.snapshot["allocations"]
    primary = rows.find { |r| r["income_id"] == @primary_series.id }
    assert_equal "percent", primary["mode"]
    assert_equal 0.5, primary["value_percent"].to_f
    secondary = rows.find { |r| r["income_id"] == @secondary_series.id }
    assert_equal "leftover", secondary["mode"]
    assert_equal before, census
    assert_equal "leftover", @family.income_account_allocations
      .find_by(income_series_id: @primary_series.id, account_id: @account.id).mode,
      "the live edge is untouched"
  end

  test "scenario income policy write: snapshot incomes only, live series untouched" do
    seed_live_plan
    create_scenario
    scenario = PlanScenario.last
    before = census

    # The scenario income dialog posts the flat income_policy params
    # (enabled / zeroed / gross) — the controller's scenario branch reads
    # params[:income_policy].
    patch "/plan/flow/incomes/#{@secondary_series.id}?scenario=#{scenario.id}", headers: json, params: {
      income_policy: { enabled: "0" }
    }
    assert_response :success
    row = scenario.reload.snapshot["incomes"].find { |r| r["series_id"] == @secondary_series.id }
    assert_equal false, row["enabled"]
    assert_equal before, census
    assert @secondary_series.reload.status == "active", "the live series is untouched"

    # Zeroed + gross levers.
    patch "/plan/flow/incomes/#{@secondary_series.id}?scenario=#{scenario.id}", headers: json, params: {
      income_policy: { enabled: "1", zeroed: "1" }
    }
    assert_response :success
    row = scenario.reload.snapshot["incomes"].find { |r| r["series_id"] == @secondary_series.id }
    assert_equal true, row["zeroed"]

    patch "/plan/flow/incomes/#{@secondary_series.id}?scenario=#{scenario.id}", headers: json, params: {
      income_policy: { enabled: "1", zeroed: "0", gross: "750.00" }
    }
    assert_response :success
    row = scenario.reload.snapshot["incomes"].find { |r| r["series_id"] == @secondary_series.id }
    assert_equal false, row["zeroed"]
    assert_equal 75_000, row["gross_per_paycheck_cents"].to_i

    # The REAL form shape: the house hidden-false + checked-true checkbox
    # submits BOTH values when checked (Rack parses the duplicate key as an
    # array) and only the hidden "false" when unchecked. The array form
    # must read ENABLED (the original .to_s bug read "false" for a checked
    # box) and the hidden-only form must read DISABLED.
    patch "/plan/flow/incomes/#{@secondary_series.id}?scenario=#{scenario.id}", headers: json, params: {
      income_policy: { enabled: [ "false", "true" ] }
    }
    assert_response :success
    row = scenario.reload.snapshot["incomes"].find { |r| r["series_id"] == @secondary_series.id }
    assert_equal true, row["enabled"], "checked box (array form) = enabled"

    patch "/plan/flow/incomes/#{@secondary_series.id}?scenario=#{scenario.id}", headers: json, params: {
      income_policy: { enabled: "false" }
    }
    assert_response :success
    row = scenario.reload.snapshot["incomes"].find { |r| r["series_id"] == @secondary_series.id }
    assert_equal false, row["enabled"], "unchecked box (hidden-only form) = disabled"
  end

  test "scenario paycheck config: snapshot config only, live configs untouched" do
    seed_live_plan
    create_scenario
    scenario = PlanScenario.last
    before = census

    patch "/plan/flow/paycheck-config/#{@user.id}?scenario=#{scenario.id}", headers: json, params: {
      paycheck_config: { gross: "1000.00", frequency: "biweekly", anchor_date: "2026-11-02" }
    }
    assert_response :success
    row = scenario.reload.snapshot["paycheck_configs"].find { |c| c["user_id"] == @user.id }
    refute_nil row
    assert_equal 100_000, row["gross_per_paycheck_cents"].to_i
    assert_equal "biweekly", row["frequency"]
    assert_equal "2026-11-02", row["anchor_date"]
    assert_equal before, census
    assert_equal 0, @family.family_paycheck_configs.count, "no live config row"
  end
end
