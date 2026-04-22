# frozen_string_literal: true

# ANSI-color helpers for the `.pp` debug methods on ledger models.
# Pure formatting + a thin `puts` wrapper — no AR dependency.
module Stern
  module AnsiPrint
    ANSI_RESET = "\e[0m"
    ANSI_COLORS = {
      red: 31, green: 32, yellow: 33, blue: 34,
      magenta: 35, cyan: 36, white: 37,
      dark_green: "38;5;22", orange: "38;5;208",
      purple: "38;5;93", lime: "38;5;154"
    }.freeze

    module_function

    # Builds a single space-separated ANSI-colored line from an array of
    # `[text, color, bold]` triples. `color` must be a key in ANSI_COLORS.
    # Returns the formatted string; does not print.
    def colorize(parts)
      parts.map do |text, color, bold|
        code = ANSI_COLORS.fetch(color)
        prefix = bold ? "1;#{code}" : code
        "\e[#{prefix}m#{text}#{ANSI_RESET}"
      end.join(" ")
    end

    # Formats and prints. Side-effecting wrapper around `colorize`.
    def puts_colorized(parts)
      puts colorize(parts)
    end
  end
end
