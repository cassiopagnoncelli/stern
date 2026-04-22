# frozen_string_literal: true

module Stress
  module Scenarios
    class Base
      attr_reader :opts

      def initialize(opts)
        @opts = opts
      end

      def setup; end
      def teardown; end

      def run_once(_iter_idx, _thread_idx)
        raise NotImplementedError
      end
    end
  end
end
