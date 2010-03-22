# = Expect object
# Copyright (C) 2010  Infonium Inc.
#
# This file is part of ScripTTY.
#
# ScripTTY is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# ScripTTY is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with ScripTTY.  If not, see <http://www.gnu.org/licenses/>.

require 'scriptty/net/event_loop'
require 'scriptty/term'
require 'scriptty/screen_pattern'
require 'set'

module ScripTTY
  class Expect

    # Methods to export to Evaluator
    EXPORTED_METHODS = Set.new [:init_term, :term, :connect, :screen, :expect, :on, :wait, :send, :push_patterns, :pop_patterns, :exit, :eval_script_file, :eval_script_inline, :sleep ]

    attr_reader :term   # The terminal emulation object

    def initialize
      @net = ScripTTY::Net::EventLoop.new
      @suspended = false
      @effective_patterns = nil
      @term_name = nil
      @effective_patterns = []    # Array of PatternHandle objects
      @pattern_stack = []
      @wait_finished = false
      @evaluator = Evaluator.new(self)
      @match_buffer = ""
    end

    # Load and evaluate a script from a file.
    def eval_script_file(path)
      eval_script_inline(File.read(path), path)
    end

    # Evaluate a script specified as a string.
    def eval_script_inline(str, filename=nil, lineno=nil)
      @evaluator.instance_eval(str, filename || "(inline)", lineno || 1)
    end

    # Initialize a terminal emulator.
    #
    # If a name is specified, use that terminal type.  Otherwise, use the
    # previous terminal type.
    def init_term(name=nil)
      name ||= @term_name
      @term_name = name
      raise ArgumentError.new("No previous terminal specified") unless name
      @term = ScripTTY::Term.new(name)
      @term.on_unknown_sequence :ignore     # XXX - Is this what we want?
    end

    # Connect to the specified address.  Return true if the connection was
    # successful.  Otherwise, raise an exception.
    def connect(remote_address)
      connected = false
      connect_error = nil
      @conn = @net.connect(remote_address) do |c|
        c.on_connect { connected = true; handle_connect; @net.suspend }
        c.on_connect_error { |e| handle_connect_error(e) }
        c.on_receive_bytes { |bytes| handle_receive_bytes(bytes) }
        c.on_close { @conn = nil; handle_connection_close }
      end
      dispatch until connected or connect_error or @net.done?
      raise connect_error if !connected or connect_error or @net.done?  # XXX - this is sloppy
      connected
    end

    # Add the specified pattern to the effective pattern list.
    #
    # Return the PatternHandle for the pattern.
    #
    # Options:
    # [:continue]
    #   If true, matching this pattern will not cause the wait method to
    #   return.
    def on(pattern, opts={}, &block)
      case pattern
      when String
        ph = PatternHandle.new(/#{Regexp.escape(pattern)}/n, block, opts[:background])
      when Regexp
        if pattern.kcode == "none"
          ph = PatternHandle.new(pattern, block, opts[:background])
        else
          ph = PatternHandle.new(/#{pattern}/n, block, opts[:background])
        end
      when ScreenPattern
        ph = PatternHandle(pattern, block, opts[:background])
      else
        raise TypeError.new("Unsupported pattern type: #{pattern.class.inspect}")
      end
      @effective_patterns << ph
      ph
    end

    # Sleep for the specified number of seconds
    def sleep(seconds)
      sleep_done = false
      @net.timer(seconds) { sleep_done = true ; @net.suspend }
      dispatch until sleep_done
      nil
    end

    # Return the named ScreenPattern
    # XXX TODO
    def screen(name)
      
    end

    # Convenience function.
    #
    # == Examples
    #  # Wait for a single pattern to match.
    #  expect("login: ")
    #
    #  # Wait for one of several patterns to match.
    #  expect {
    #    on("login successful") { ... }
    #    on("login incorrect") { ... }
    #  }
    def expect(pattern=nil)
      raise ArgumentError.new("no pattern and no block given") if !pattern and !block_given?
      push_patterns
      begin
        on(pattern) if pattern
        yield if block_given?
        wait
      ensure
        pop_patterns
      end
    end

    # Push a copy of the effective pattern list to an internal stack.
    def push_patterns
      @pattern_stack << @effective_patterns.dup
    end

    # Pop the effective pattern list from the stack.
    def pop_patterns
      raise ArgumentError.new("pattern stack empty") if @pattern_stack.empty?
      @effective_patterns = @pattern_stack.pop
    end

    # Wait for an effective pattern to match.
    #
    # Clears the character-match buffer on return.
    def wait
      dispatch until @wait_finished
      @wait_finished = false
      @match_buffer = ""
      nil
    end

    # Send bytes to the remote application.
    #
    # NOTE: This method returns immediately, even if not all the bytes are
    # finished being sent.  Remaining bytes will be sent during an expect,
    # wait, or sleep call.
    def send(bytes)
      @conn.write(bytes)
      true
    end

    # Close the connection and exit.
    def exit
      @net.exit
      dispatch until @net.done?
    end

    private

      # Re-enter the dispatch loop
      def dispatch
        if @suspended
          @suspended = @net.resume
        else
          @suspended = @net.main
        end
      end

      def handle_connection_close   # XXX - we should raise an error when disconnected prematurely
        self.exit
      end

      def handle_connect
        init_term
      end

      def handle_receive_bytes(bytes)
        @match_buffer << bytes
        @term.feed_bytes(bytes)
        check_expect_match
      end

      # Check for a match.
      #
      # If there is a (non-background) match, set @wait_finished and return true.  Otherwise, return false.
      def check_expect_match
        found = true
        while found
          found = false
          @effective_patterns.each { |ph|
            case ph.pattern
            when Regexp
              m = ph.pattern.match(@match_buffer)
              @match_buffer = @match_buffer[m.end(0)..-1] if m    # truncate match buffer
            when ScreenPattern
              m = ph.pattern.match_term(@term)
            else
              raise "BUG: pattern is #{ph.pattern.inspect}"
            end

            next unless m

            # Matched - Invoke the callback
            ph.callback.call(m) if ph.callback

            # Make the next wait() call return
            unless ph.background?
              @wait_finished = true
              @net.suspend
              return true
            else
              found = true
            end
          }
        end
        false
      end

    class Evaluator
      def initialize(expect_object)
        @_expect_object = expect_object
      end

      # Define proxy methods
      EXPORTED_METHODS.each do |m|
        # We would use define_method, but JRuby 1.4 doesn't support defining
        # a block that takes a block. http://jira.codehaus.org/browse/JRUBY-4180
        class_eval("def #{m}(*args, &block) @_expect_object.__send__(#{m.inspect}, *args, &block); end")
      end
    end

    class PatternHandle
      attr_reader :pattern
      attr_reader :callback

      def initialize(pattern, callback, background)
        @pattern = pattern
        @callback = callback
        @background = background
      end

      def background?
        @background
      end
    end

    class Match
      attr_reader :pattern_handle
      attr_reader :result

      def initialize(pattern_handle, result)
        @pattern_handle = pattern_handle
        @result = result
      end
    end

  end
end