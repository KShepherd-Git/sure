# Paycheck Flow page view helpers.
module PlanFlowsHelper
  # An account is "on the map" when it is ordered (plan_order), carries an
  # allocation edge, or shows obligations/goals in the right column.
  def in_flow?(account)
    account.plan_order.present? ||
      @allocations.any? { |edge| edge.account_id == account.id } ||
      (@bills_by_account[account.id] || []).any? ||
      (@debt_service_by_account[account.id] || []).any? ||
      (@goals_by_account[account.id] || []).any? ||
      @leftover_account_ids.include?(account.id)
  end

  # Edge editor value input: major units for specific, 0-100 for percent
  # (the model stores 0..1), blank for required/leftover.
  def edge_display_value(allocation)
    return "" unless allocation

    case allocation.mode
    when "specific" then allocation.value.to_s
    when "percent" then (allocation.value * 100).to_s
    else ""
    end
  end

  # The solver's report money strings are in the family currency.
  def flow_money(value)
    format_money(Money.new(value.to_f, Current.family.currency))
  end

  def flow_percent(value)
    format("%.1f", value.to_f * 100) + "%"
  end

  def flow_account_name(account_id)
    @flow_accounts.find { |account| account.id == account_id.to_s }&.name || account_id
  end

  def flow_user_name(user_id)
    @family_users.find { |user| user.id == user_id.to_s }&.display_name || user_id
  end

  def flow_income_name(series_id)
    @income_series&.find { |series| series.id == series_id.to_s }&.display_name || series_id
  end
end
