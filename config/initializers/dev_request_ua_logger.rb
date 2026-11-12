# F-1 (Round 31B, owner Rec): the development request log line carries the
# client User-Agent. The stock Rails::Rack::Logger 'Started %s "%s" for %s
# at %s' line omits the UA (round-28 forensic find: sessions.user_agent is
# AES-GCM encrypted, so the request log was the only usable UA trail), and
# the 127.0.0.1 bind alternative was REJECTED by the owner (it would cut
# LAN access to the app).
#
# DEV-ONLY: gated to Rails.env.development?. The production and test stacks
# keep the stock Rails::Rack::Logger untouched — their log paths are
# byte-identical.
#
# Implementation notes:
# - Inline anonymous subclass (NOT an app/middleware constant): Rails 8.1
#   sets up the Zeitwerk autoloader in the finisher, after config/initializers
#   run, so an app/ constant is not resolvable here. Rails::Rack::Logger is
#   a gem constant and resolves fine.
# - The swap targets the default stack's Rails::Rack::Logger. The user
#   config stack is a proxy whose operations are replayed onto the default
#   stack once it is built (engine.rb:518), so the target is present by the
#   time the swap executes. An inline class avoids a named app/ constant.
#   `swap` re-inserts the class without the original args; development sets
#   no config.log_tags (only production does: [:request_id]), so the dev
#   log line is unchanged apart from the appended UA.
if Rails.env.development?
  # BRACE block on purpose: a do...end here would bind to the outer
  # `swap` call (do-blocks bind to the outermost method in the
  # statement), not to Class.new — the class would be born without the
  # override and the swap would log a plain line.
  Rails.application.config.middleware.swap Rails::Rack::Logger,
    Class.new(Rails::Rack::Logger) {
      private
        # The stock 'Started GET "/path" for 1.2.3.4 at ...' line with
        # the UA appended. request.user_agent is the raw HTTP_USER_AGENT
        # header (nil -> the empty string, so a UA-less client logs
        # UA: "").
        def started_request_message(request)
          super + format(' UA: "%s"', request.user_agent.to_s)
        end
    }
end
