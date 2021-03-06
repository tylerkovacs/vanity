module Vanity
  module Experiment

    # These methods are available from experiment definitions (files located in
    # the experiments directory, automatically loaded by Vanity).  Use these
    # methods to define you experiments, for example:
    #   ab_test "New Banner" do
    #     alternatives :red, :green, :blue
    #     metrics :signup
    #   end
    module Definition

      attr_reader :playground

      # Defines a new experiment, given the experiment's name, type and
      # definition block.
      def define(name, type, options = nil, &block)
        fail "Experiment #{@experiment_id} already defined in playground" if playground.experiments[@experiment_id]
        klass = Experiment.const_get(type.to_s.gsub(/\/(.?)/) { "::#{$1.upcase}" }.gsub(/(?:^|_)(.)/) { $1.upcase })
        experiment = klass.new(playground, @experiment_id, name, options)
        experiment.instance_eval &block
        experiment.save
        playground.experiments[@experiment_id] = experiment
      end

      def new_binding(playground, id)
        @playground, @experiment_id = playground, id
        binding
      end

    end

    # Base class that all experiment types are derived from.
    class Base

      class << self
        
        # Returns the type of this class as a symbol (e.g. AbTest becomes
        # ab_test).
        def type
          name.split("::").last.gsub(/([a-z])([A-Z])/) { "#{$1}_#{$2}" }.gsub(/([A-Z])([A-Z][a-z])/) { "#{$1}_#{$2}" }.downcase
        end

        # Playground uses this to load experiment definitions.
        def load(playground, stack, file)
          fail "Circular dependency detected: #{stack.join('=>')}=>#{file}" if stack.include?(file)
          source = File.read(file)
          stack.push file
          id = File.basename(file, ".rb").downcase.gsub(/\W/, "_").to_sym
          context = Object.new
          context.instance_eval do
            extend Definition
            experiment = eval(source, context.new_binding(playground, id), file)
            fail NameError.new("Expected #{file} to define experiment #{id}", id) unless playground.experiments[id]
            experiment
          end
        rescue
          error = NameError.exception($!.message, id)
          error.set_backtrace $!.backtrace
          raise error
        ensure
          stack.pop
        end

      end

      def initialize(playground, id, name, options = nil)
        @playground = playground
        @id, @name = id.to_sym, name
        @options = options || {}
        @namespace = "#{@playground.namespace}:#{@id}"
        @identify_block = method(:default_identify)
      end

      # Human readable experiment name (first argument you pass when creating a
      # new experiment).
      attr_reader :name
      alias :to_s :name

      # Unique identifier, derived from name experiment name, e.g. "Green
      # Button" becomes :green_button.
      attr_reader :id

      # Time stamp when experiment was created.
      attr_reader :created_at

      # Time stamp when experiment was completed.
      attr_reader :completed_at

      # Returns the type of this experiment as a symbol (e.g. :ab_test).
      def type
        self.class.type
      end
     
      # Defines how we obtain an identity for the current experiment.  Usually
      # Vanity gets the identity form a session object (see use_vanity), but
      # there are cases where you want a particular experiment to use a
      # different identity.
      #
      # For example, if all your experiments use current_user and you need one
      # experiment to use the current project:
      #   ab_test "Project widget" do
      #     alternatives :small, :medium, :large
      #     identify do |controller|
      #       controller.project.id
      #     end
      #   end
      def identify(&block)
        fail "Missing block" unless block
        @identify_block = block
      end


      # -- Reporting --

      # Sets or returns description. For example
      #   ab_test "Simple" do
      #     description "A simple A/B experiment"
      #   end
      #
      #   puts "Just defined: " + experiment(:simple).description
      def description(text = nil)
        @description = text if text
        @description
      end


      # -- Experiment completion --

      # Define experiment completion condition.  For example:
      #   complete_if do
      #     !score(95).chosen.nil?
      #   end
      def complete_if(&block)
        raise ArgumentError, "Missing block" unless block
        raise "complete_if already called on this experiment" if @complete_block
        @complete_block = block
      end

      # Force experiment to complete.
      def complete!
        if redis.client.connected?
          redis.setnx key(:completed_at), Time.now.to_i
          @completed_at = redis[key(:completed_at)]
          @playground.logger.info "vanity: completed experiment #{id}"
        else
          @playground.logger.info "vanity: failed to complete experiment #{id} - not connected to redis"
        end
      end

      # Time stamp when experiment was completed.
      def completed_at
        if redis.client.connected?
          @completed_at ||= redis[key(:completed_at)]
          @completed_at && Time.at(@completed_at.to_i)
        else
          nil
        end
      end
      
      # Returns true if experiment active, false if completed.
      def active?
        if redis.client.connected?
          !redis.exists(key(:completed_at))
        else
          false
        end
      end

      # -- Store/validate --

      # Get rid of all experiment data.
      def destroy
        if redis.client.connected?
          redis.del key(:created_at)
          redis.del key(:completed_at)
          @created_at = @completed_at = nil
        else
          @playground.logger.info "vanity: failed to destroy - not connected to redis"
        end
      end

      # Called by Playground to save the experiment definition.
      def save
        if redis.client.connected?
          redis.setnx key(:created_at), Time.now.to_i
          @created_at = Time.at(redis[key(:created_at)].to_i)
        else
          @playground.logger.info "vanity: failed to save - not connected to redis"
          false
        end
      end

    protected

      def identity
        @identify_block.call(Vanity.context)
      end

      def default_identify(context)
        raise "No Vanity.context" unless context
        raise "Vanity.context does not respond to vanity_identity" unless context.respond_to?(:vanity_identity)
        context.vanity_identity or raise "Vanity.context.vanity_identity - no identity"
      end

      # Derived classes call this after state changes that may lead to
      # experiment completing.
      def check_completion!
        if @complete_block
          begin
            complete! if @complete_block.call
          rescue
            # TODO: logging
          end
        end
      end
      
      # Returns key for this experiment, or with an argument, return a key
      # using the experiment as the namespace.  Examples:
      #   key => "vanity:experiments:green_button"
      #   key("participants") => "vanity:experiments:green_button:participants"
      def key(name = nil)
        name ? "#{@namespace}:#{name}" : @namespace
      end

      # Shortcut for Vanity.playground.redis
      def redis
        @playground.redis
      end
      
    end
  end
end

