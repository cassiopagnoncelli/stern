require "irb/ext/tracer"

IRB.conf[:PROMPT_MODE] = :SIMPLE
IRB.conf[:PROMPT][:SIMPLE][:RETURN] = "%s (in %.3f seconds)\n"

# IRB::Irb.class_eval do
#   def output_value
#     super
#     elapsed_time = format("%.3f", Time.now - @context.started_at)
#     @context.io.prompt[:RETURN].sub(/%N/, elapsed_time)
#   end
# end
