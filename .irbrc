require "irb/ext/tracer"

# Auto-include Stern module for standalone app console
begin
  require_relative "lib/stern"
  include Stern
  
  puts "Stern module included - you can use methods directly without Stern:: prefix"
rescue LoadError
  # Stern not available or in engine mode
end

IRB.conf[:PROMPT_MODE] = :SIMPLE
IRB.conf[:PROMPT][:SIMPLE][:RETURN] = "%s (in %.3f seconds)\n"

# IRB::Irb.class_eval do
#   def output_value
#     super
#     elapsed_time = format("%.3f", Time.now - @context.started_at)
#     @context.io.prompt[:RETURN].sub(/%N/, elapsed_time)
#   end
# end
