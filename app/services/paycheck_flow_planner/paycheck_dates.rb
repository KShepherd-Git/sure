# Round 31B (Direct Deposit): paycheck-date derivation. REUSES the house
# RecurringTransaction::Schedule + RecurrenceRule engine — no new math:
#
#   semi_monthly (default, B5) = two monthly rules: the 15th + the last
#     calendar day (RecurrenceRule::LAST) — 24x/yr.
#   biweekly = a weekly rule interval 2 on the anchor's weekday, anchored
#     at the anchor date — 26 dates/yr, exact 14-day stride, clipped to
#     the requested calendar window (the Schedule's weekly_occurrences
#     math: base = anchor, step = 14, first_step = ceil((start-base)/14)).
#
# weekend_adjust "none" — no weekend drift. A schedule is built from
# synthesized Rule datas; no DB rows are read or written here.
#
# Nested class (NOT a module reopening): PaycheckFlowPlanner is itself a
# class (app/services/paycheck_flow_planner.rb), the house
# RecurringTransaction::Schedule pattern.
class PaycheckFlowPlanner
  class PaycheckDates
    SEMI_MONTHLY_DAY = 15
    BIWEEKLY_STRIDE_DAYS = 14

    # [{ date: Date, amount_cents: Integer }] for every derived pay date in
    # [start_date, end_date] inclusive (the planner's month window).
    def self.occurrences(config, start_date, end_date)
      schedule(config).occurrences_between(start_date, end_date).map do |date|
        { date: date, amount_cents: config.gross_per_paycheck_cents }
      end
    end

    # [Date] — the same window, dates only.
    def self.dates(config, start_date, end_date)
      occurrences(config, start_date, end_date).map { |occurrence| occurrence[:date] }
    end

    # The member's next `count` pay dates on/after today (future-only
    # readout). An anchor in the past is normal — the window clipping
    # handles it.
    def self.upcoming(config, count: 4)
      occurrences(config, Date.current, Date.current + 4.months)
        .first(count)
        .map { |occurrence| occurrence[:date] }
    end

    # Dated-per-year for the readout: 24 (semi_monthly) / 26 (biweekly).
    def self.per_year(config)
      config.frequency == FamilyPaycheckConfig::FREQUENCY_BIWEEKLY ? 26 : 24
    end

    # A Schedule for the config (expected_day_of_month nil is fine:
    # non-empty rules skip the implicit-monthly fallback, and every rule
    # either has interval 1 or an anchor — the Schedule's own anchor
    # requirement is satisfied by config.anchor_date).
    def self.schedule(config)
      RecurringTransaction::Schedule.new(
        expected_day_of_month: nil,
        rules: rules_for(config),
        anchor_date: config.anchor_date,
        weekend_adjust: "none"
      )
    end

    # The synthesized rules — same shapes as FrequencyPreset's biweekly /
    # semimonthly writes (frequency_preset.rb L183-188).
    def self.rules_for(config)
      case config.frequency
      when FamilyPaycheckConfig::FREQUENCY_BIWEEKLY
        [
          build_rule(frequency: "weekly", interval: 2,
                     weekday: config.anchor_date.wday)
        ]
      else
        [
          build_rule(frequency: "monthly", day_of_month: SEMI_MONTHLY_DAY),
          build_rule(frequency: "monthly", day_of_month: RecurrenceRule::LAST)
        ]
      end
    end

    def self.build_rule(frequency:, interval: 1, day_of_month: nil, weekday: nil)
      RecurringTransaction::Schedule::Rule.new(
        frequency: frequency,
        interval: interval,
        day_of_month: day_of_month,
        weekday: weekday,
        weekday_ordinal: nil,
        month_of_year: nil
      )
    end
  end
end
